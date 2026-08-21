"""WhisperType server — always-warm dictation backend.

Runs on your server Mac. One endpoint the client calls:

    POST /dictate   (multipart: file=<audio>)  ->  {"raw": ..., "text": ...}

Pipeline:
    1. ASR — local mlx-whisper (whisper-large-v3, biased by your vocabulary),
             with an HTTP mlx-whisper server as fallback. Whisper's output is
             already clean and well-punctuated.
    2. Vocab — deterministic name/jargon/snippet corrections on the transcript
               (the faithful, near-verbatim text).
    3. Polish (ON by default, NARROW) — an mlx-lm model that ONLY removes filler
               and resolves self-corrections ("I did this, no I did not" -> "I
               did not"), never paraphrasing or replying. A safety net in
               _polish() falls back to the verbatim text whenever the model
               drifts (paraphrases, replies, fabricates, or drops content). Set
               VF_POLISH=0 for pure near-verbatim (model not loaded at all).

Run under launchd (see scripts/) so it auto-starts.

Env:
    VF_WHISPER_URL   default http://127.0.0.1:8181
    VF_POLISH        default 1 (on, narrow). Set 0 for pure near-verbatim.
    VF_POLISH_MODEL  default mlx-community/Qwen2.5-7B-Instruct-4bit (fast)
    VF_PROMPT        default 1 (prompt mode on). Set 0 to disable.
    VF_PROMPT_MODEL  default mlx-community/Qwen2.5-14B-Instruct-4bit (stronger;
                     background-loaded; falls back to VF_POLISH_MODEL on failure)
    VF_PORT          default 8790
    VF_API_KEY       optional; if set, require header  Authorization: Bearer <key>
    VF_KEEPALIVE_SEC default 240; periodic tiny gen so the model never pages out
"""
import os
import re
import io
import wave
import json
import time
import asyncio
import logging

import numpy as np
import requests
from fastapi import FastAPI, UploadFile, File, Form, Header, HTTPException
from fastapi.responses import JSONResponse
from mlx_lm import load, generate

WHISPER_URL = os.environ.get("VF_WHISPER_URL", "http://127.0.0.1:8181").rstrip("/")
WHISPER_MODEL = os.environ.get("VF_WHISPER_MODEL", "mlx-community/whisper-large-v3-mlx")
# Fast model for the high-frequency dictation-polish path.
POLISH_MODEL = os.environ.get("VF_POLISH_MODEL", "mlx-community/Qwen2.5-7B-Instruct-4bit")
# Stronger model for the deliberate prompt-engineering path (quality > speed).
# Falls back to POLISH_MODEL if it can't be loaded.
PROMPT_MODEL = os.environ.get("VF_PROMPT_MODEL", "mlx-community/Qwen2.5-14B-Instruct-4bit")
# Distilled LoRA adapter for the fast polish model — teaches the 8B the strong
# model's "format-only, never answer/paraphrase" discipline. If present, polish
# runs on the fast 8B+adapter (14B quality at 8B speed) instead of the 14B.
POLISH_ADAPTER = os.environ.get("VF_POLISH_ADAPTER",
                                os.path.join(os.path.dirname(__file__), "lora-polish"))
# Speaker diarization runs in an ISOLATED venv (heavy torch deps kept away from
# the live server). Set both to enable "who said what" in meeting mode; if the
# venv/script is missing, /meeting gracefully falls back to an unlabeled transcript.
DIARIZE_PY = os.environ.get("VF_DIARIZE_PY", os.path.expanduser("~/pyannote-venv/bin/python"))
DIARIZE_SCRIPT = os.environ.get("VF_DIARIZE_SCRIPT", os.path.join(os.path.dirname(__file__), "diarize.py"))

# Local (biasable) Whisper. If import/model load fails we fall back to the
# shared HTTP whisper server, so ASR never goes down.
try:
    import mlx_whisper  # noqa: F401
    _WHISPER_LOCAL = True
except Exception:  # noqa: BLE001
    _WHISPER_LOCAL = False
PORT = int(os.environ.get("VF_PORT", "8790"))
API_KEY = os.environ.get("VF_API_KEY", "")
KEEPALIVE_SEC = int(os.environ.get("VF_KEEPALIVE_SEC", "240"))
VOCAB_PATH = os.environ.get("VF_VOCAB_PATH", os.path.join(os.path.dirname(__file__), "vocab.json"))
# Polish is ON by default but scoped NARROWLY (filler + self-correction only, see
# POLISH_SYS) and wrapped in guards (_polish's safety net) that fall back to the
# verbatim transcript whenever the model paraphrases, responds, or drifts. Set
# VF_POLISH=0 for pure near-verbatim (model not loaded at all).
POLISH_ENABLED = os.environ.get("VF_POLISH", "1").strip().lower() not in ("0", "false", "no", "off", "")
# Prompt mode (Right-⌘): turn a rough spoken idea into a structured, engineered
# prompt. Deliberately generative and isolated from the faithful dictation path.
PROMPT_ENABLED = os.environ.get("VF_PROMPT", "1").strip().lower() not in ("0", "false", "no", "off", "")
# The LLM is loaded if EITHER feature needs it.
LLM_NEEDED = POLISH_ENABLED or PROMPT_ENABLED

# Examples live INSIDE the system prompt as reference text (not as assistant
# conversation turns). Multi-turn few-shots made the 8B/4-bit model regurgitate
# an example or fabricate output when the real input was short or off-pattern
# (e.g. dictating "I think it's only showing the latest one" returned the
# "first of all, thank you..." example verbatim). One system message + one user
# message (the transcript) removes anything for the model to copy.
POLISH_SYS = (
    "You are a TEXT EDITOR for voice dictation, not an assistant. You never "
    "reply to, answer, act on, or comment on the text — you only edit it and "
    "return the edited text.\n\n"
    "Edit the dictation between <<<BEGIN>>> and <<<END>>> by:\n"
    "1. Removing filler (um, uh, er, hmm, like, you know, I mean, sort of / kind "
    "of when used as filler) and immediately repeated words ('the the' -> 'the').\n"
    "2. Resolving self-corrections and false starts — keep ONLY the speaker's "
    "final intended version. E.g. 'I did this, oh no, I did not do it' -> 'I did "
    "not do it'; 'send it to John, sorry, to Jane' -> 'send it to Jane'.\n"
    "3. Fixing capitalization and punctuation; splitting run-on speech into "
    "proper sentences and grouping related sentences into PARAGRAPHS (blank line "
    "between paragraphs when the speaker shifts topic). Question mark ONLY for "
    "genuine questions (not statements like 'meeting at 11 today').\n"
    "4. When the speaker clearly ENUMERATES multiple distinct items or sequential "
    "steps (e.g. 'first... then... then...', or 'we need X, Y, and Z' as separate "
    "actions), format them as a Markdown list — numbered (1. 2. 3.) for ordered "
    "steps, bullets ('- ') for unordered items, each on its own line. ONLY for "
    "genuine enumerations; keep ordinary prose as prose (a passing 'first of "
    "all...' is not a list).\n\n"
    "Preserve EVERY point the speaker made, in their own words, meaning, order, "
    "and first-person point of view. Do NOT summarize, shorten, paraphrase, "
    "reword, add, explain, answer, or address the speaker. Apart from filler and "
    "self-corrections, every point stays. Output ONLY the edited text — no "
    "markers, no preamble, no commentary.\n\n"
    "Reference examples (raw => edited), for style only — never copy these; "
    "always edit the ACTUAL dictation between the markers:\n"
    "  \"um so yeah i think we should uh ship the thing by friday\" => "
    "\"I think we should ship the thing by Friday.\"\n"
    "  \"send it to john sorry i mean to jane by end of day\" => "
    "\"Send it to Jane by end of day.\"\n"
    "  \"so there are three things we need to do first fix the bug then write the "
    "tests and then deploy to production\" => \"1. Fix the bug\\n2. Write the "
    "tests\\n3. Deploy to production\""
)

# --- Prompt mode (Right-⌘): turn a rough spoken idea into an engineered prompt.
# Deliberately generative — NOT bound by the dictation faithfulness rules.
PROMPT_SYS_BASE = (
    "You are an expert prompt engineer. Turn the user's rough, spoken request "
    "(between the markers) into a clear, well-structured prompt they can paste "
    "into an AI assistant or coding agent. Write it as a direct instruction TO "
    "that assistant. Capture the speaker's intent faithfully; you may make it "
    "explicit and well-organized, but do NOT invent requirements, facts, tech "
    "choices, or scope they did not state or clearly imply. Output ONLY the "
    "prompt text — no preamble, no explanation, no surrounding quotes or markers.\n\n"
    "Example of the transformation (rough request -> a good CONCISE prompt):\n"
    "  rough: \"i need a python script that reads a csv and emails me a summary "
    "every morning\"\n"
    "  prompt: \"Write a Python script that reads a CSV file, computes a short "
    "summary of its contents, and emails that summary to me. It should be "
    "runnable on a daily morning schedule (e.g. via cron). Make the CSV path, "
    "recipient address, and SMTP settings configurable.\""
)
PROMPT_LEVEL = {
    "concise": "\n\nProduce a CONCISE prompt: a single tight paragraph stating "
               "the goal and any key constraints. No headings, no bullet lists.",
    "detailed": "\n\nProduce a DETAILED prompt using these markdown sections, "
                "including ONLY the ones that apply: '**Goal**', '**Context**', "
                "'**Requirements**', '**Steps**'. Be specific and actionable, but "
                "do not fabricate details the speaker didn't imply.",
    "coding": "\n\nProduce a prompt for an AI CODING AGENT, using these markdown "
              "sections (include only those that apply): '**Task**' (one-sentence "
              "goal), '**Requirements**' (bulleted, specific behaviors), "
              "'**Acceptance criteria**' (how to know it's done), '**Notes**' "
              "(constraints, edge cases). Be precise and testable. Do not specify "
              "files, languages, or frameworks the speaker didn't mention.",
}

# --- Meeting mode: turn a meeting/call transcript into structured notes.
# Grounded-generative — organizes what was said; must not invent facts.
MEETING_SYS = (
    "You write meeting notes for one busy person who was in the room. Write the "
    "way a sharp colleague would brief them afterwards: specific, concrete, and "
    "short.\n\n"
    "Produce Markdown with ONLY the sections that apply:\n"
    "**Summary** - at most 3 sentences. Lead with what happened and what it "
    "means. Carry the actual numbers, names and outcomes.\n"
    "**Decisions** - bulleted, only explicit decisions.\n"
    "**Action items** - bulleted, owner first (e.g. '- Alex: send the "
    "reconciliation sheet'). Include a due date ONLY if one was stated.\n"
    "**Open questions** - bulleted, genuinely unresolved items.\n\n"
    "Never begin with 'The meeting discussed', 'The primary concern was', 'It "
    "was agreed that', 'This meeting', or 'Additionally'. Never use the words "
    "'delve' or 'leverage'. Do not restate the agenda. Do not pad.\n"
    "Base everything ONLY on the transcript. Do NOT invent decisions, owners, "
    "dates, numbers, or facts that aren't there. Omit any section with nothing "
    "to put in it. Output ONLY the Markdown notes - no preamble."
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("whispertype")

app = FastAPI(title="WhisperType", version="0.1")

# Resident, always-warm models. Loaded in startup, held for process lifetime.
# _model/_tok = fast dictation-polish model (8B). _prompt_model/_prompt_tok =
# stronger prompt-engineering model (14B), loaded in the background so a big
# first-time download doesn't block startup; falls back to _model.
_model = None
_tok = None
_prompt_model = None
_prompt_tok = None
_polish_distilled = False   # True when the polish model carries the distilled LoRA adapter

# Personal vocabulary/dictionary (learning layer). Shape:
#   {"replacements": {"helo": "hello"}, "terms": ["Kubernetes", "PostgreSQL"],
#    "snippets": {"omw": "on my way"}}
# replacements: word-boundary, case-insensitive fixes applied to the raw ASR.
# terms:        proper nouns fed to the polish model so it keeps them spelled right.
# snippets:     literal expansions.
_vocab = {"replacements": {}, "terms": [], "snippets": {}}


def _load_vocab():
    global _vocab
    try:
        with open(VOCAB_PATH) as f:
            data = json.load(f)
        _vocab = {
            "replacements": data.get("replacements", {}) or {},
            "terms": data.get("terms", []) or [],
            "snippets": data.get("snippets", {}) or {},
        }
        log.info("vocab loaded: %d replacements, %d terms, %d snippets",
                 len(_vocab["replacements"]), len(_vocab["terms"]), len(_vocab["snippets"]))
    except FileNotFoundError:
        log.info("no vocab file at %s (starting empty)", VOCAB_PATH)
    except Exception as e:  # noqa: BLE001
        log.warning("failed to load vocab: %s", e)


def _save_vocab():
    with open(VOCAB_PATH, "w") as f:
        json.dump(_vocab, f, indent=2, ensure_ascii=False)


def _whisper_prompt() -> str | None:
    """Bias Whisper toward the user's vocabulary (names/jargon spelled right)."""
    terms = list(_vocab.get("terms", []))
    terms += list({v for v in _vocab.get("replacements", {}).values()})
    terms = [t for t in dict.fromkeys(terms) if t]
    if not terms:
        return None
    joined = ", ".join(terms)
    return f"Vocabulary and names: {joined[:600]}."


def _wav_to_array(audio: bytes) -> np.ndarray:
    """Decode WAV bytes to a float32 mono array at [-1, 1] using stdlib `wave`
    (no ffmpeg dependency). The client always sends 16 kHz mono int16 PCM."""
    with wave.open(io.BytesIO(audio), "rb") as w:
        sr, ch, sw = w.getframerate(), w.getnchannels(), w.getsampwidth()
        frames = w.readframes(w.getnframes())
    if sw != 2:
        raise ValueError(f"unsupported WAV sample width {sw} (expected 16-bit)")
    arr = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
    if ch > 1:
        arr = arr.reshape(-1, ch).mean(axis=1)
    if sr != 16000:
        log.warning("unexpected WAV sample rate %d (expected 16000)", sr)
    return arr


def _transcribe_local(audio: bytes, language: str | None) -> tuple[str, float]:
    """Transcribe WAV bytes with local mlx-whisper. Feeds a decoded float32
    array (not a file path) so ASR never shells out to ffmpeg. Returns
    (text, no_speech_prob) — the max no-speech probability across segments, so
    callers can tell a real utterance from a silence hallucination."""
    audio_arr = _wav_to_array(audio)
    kwargs = {
        "path_or_hf_repo": WHISPER_MODEL,
        # CRITICAL: a temperature-fallback tuple + NOT conditioning on previous
        # text prevents the repetition/hallucination loop Whisper falls into on
        # long audio (forcing temperature=0.0 disabled that safety and caused a
        # 2-min dictation to loop on its first sentence). compression_ratio +
        # no_speech thresholds let it detect & re-decode a bad segment.
        "temperature": (0.0, 0.2, 0.4, 0.6, 0.8, 1.0),
        "condition_on_previous_text": False,
        "compression_ratio_threshold": 2.4,
        "no_speech_threshold": 0.6,
    }
    prompt = _whisper_prompt()
    if prompt:
        kwargs["initial_prompt"] = prompt
    if language:
        kwargs["language"] = language
    res = mlx_whisper.transcribe(audio_arr, **kwargs)
    text = (res.get("text") or "").strip()
    nsp = max((float(s.get("no_speech_prob", 0.0)) for s in res.get("segments", [])),
              default=0.0)
    return text, nsp


def _transcribe_local_segments(audio: bytes, language: str | None, translate: bool = False):
    """Like _transcribe_local but returns Whisper's timestamped segments
    [(start, end, text), ...] — needed to merge speaker labels for diarization.
    translate=True uses Whisper's translate task → English, regardless of the
    spoken language (used by meeting mode so Chinese/other-language meetings come
    out in English)."""
    audio_arr = _wav_to_array(audio)
    kwargs = {
        "path_or_hf_repo": WHISPER_MODEL,
        "temperature": (0.0, 0.2, 0.4, 0.6, 0.8, 1.0),
        "condition_on_previous_text": False,
        "compression_ratio_threshold": 2.4,
        "no_speech_threshold": 0.6,
    }
    if translate:
        kwargs["task"] = "translate"
    else:
        prompt = _whisper_prompt()
        if prompt:
            kwargs["initial_prompt"] = prompt
        if language:
            kwargs["language"] = language
    res = mlx_whisper.transcribe(audio_arr, **kwargs)
    segs = [(s.get("start", 0.0), s.get("end", 0.0), (s.get("text") or "").strip())
            for s in res.get("segments", [])]
    return res.get("text", "").strip(), segs


def _label_transcript(segments, turns) -> tuple[str, dict]:
    """Merge Whisper segments with pyannote speaker turns → a speaker-labeled
    transcript. Each segment gets the speaker whose turn overlaps it most.
    Consecutive segments from the same speaker are grouped under one label.

    Returns (transcript, order) where `order` maps each raw diarization label to
    the "Speaker N" the human actually SEES. This mapping is the single source of
    truth for speaker identity: numbering the speakers anywhere else (over turns,
    or over the embeddings dict) produces a DIFFERENT numbering, and renaming a
    speaker would then persist the wrong person's voiceprint."""
    if not segments:
        return "", {}

    def speaker_for(start, end):
        best, best_ov = None, 0.0
        for t in turns:
            ov = max(0.0, min(end, t["end"]) - max(start, t["start"]))
            if ov > best_ov:
                best_ov, best = ov, t["speaker"]
        return best

    # Stable, friendly names: SPEAKER_00 -> "Speaker 1" in first-appearance order.
    lines, order, cur_spk, buf = [], {}, None, []
    for (s, e, text) in segments:
        if not text:
            continue
        spk = speaker_for(s, e) or cur_spk or "SPEAKER_00"
        if spk not in order:
            order[spk] = f"Speaker {len(order) + 1}"
        if spk != cur_spk and buf:
            lines.append(f"**{order[cur_spk]}:** " + " ".join(buf))
            buf = []
        cur_spk = spk
        buf.append(text)
    if buf and cur_spk is not None:
        lines.append(f"**{order[cur_spk]}:** " + " ".join(buf))
    return "\n\n".join(lines), order


def _transcribe_remote(audio: bytes, filename: str, language: str | None) -> str:
    files = {"file": (filename or "audio.wav", audio)}
    data = {"response_format": "json"}
    if language:
        data["language"] = language
    r = requests.post(f"{WHISPER_URL}/v1/audio/transcriptions",
                      files=files, data=data, timeout=60)
    r.raise_for_status()
    return r.json().get("text", "").strip()


def apply_vocab(text: str) -> str:
    """Deterministic corrections on the raw ASR: snippet expansion + word fixes."""
    for trig, exp in _vocab.get("snippets", {}).items():
        text = text.replace(trig, exp)
    for frm, to in _vocab.get("replacements", {}).items():
        text = re.sub(rf"\b{re.escape(frm)}\b", to, text, flags=re.IGNORECASE)
    # Spoken symbol: "foo underscore bar" -> "foo_bar" (technical identifiers like
    # ET_Service). Looped to handle chains (a underscore b underscore c). High
    # signal — two alphanumerics around "underscore" is almost always an identifier.
    for _ in range(6):
        new = re.sub(r"\b([A-Za-z0-9]+)\s+underscore\s+([A-Za-z0-9]+)\b",
                     r"\1_\2", text, count=1, flags=re.IGNORECASE)
        if new == text:
            break
        text = new
    return text


# Whisper, trained on masses of video audio, hallucinates these boilerplate
# phrases on silent / near-silent / clipped clips (nothing real to transcribe, so
# it emits the highest-frequency training filler). Two cases: the WHOLE output is
# filler (drop it → no speech), or filler is glued to the FRONT of real speech
# (a mic wake-up delay clips the lead-in) → strip just the leading filler.
# Video fillers that are NEVER legitimate dictation — always removed.
_HALLUCINATION_ALWAYS = frozenset([
    "thank you for watching", "thank you for watching this video",
    "thanks for watching", "thanks for watching everyone",
    "thanks for watching this video", "please subscribe",
])
# Phrases you MIGHT actually say. Dropped ONLY when the clip had no real speech
# energy (true silence → hallucination). If you said it, it's kept.
_HALLUCINATION_IF_SILENT = frozenset([
    "thank you", "thank you very much", "thank you so much",
    "thanks", "you", "bye", "okay", "so",
])
# Leading-strip: only the unambiguous video fillers, never bare "thank you"/"you".
_HALLUCINATION_LEAD = [
    "thank you for watching this video", "thanks for watching everyone",
    "thank you for watching", "thanks for watching", "please subscribe",
]

_SILENCE_RMS = 0.008      # normalized RMS below this ≈ no speech (secondary guard)
# Tuned from real logs: hallucinated "Thank you." shows nsp≈0.18–0.28 (Whisper is
# "confident" even when inventing it), while genuine speech logs at nsp≈0.03. A
# 0.15 cut cleanly separates them. Only ever drops a KNOWN filler phrase, so real
# dictation is untouched regardless.
_NO_SPEECH_PROB = 0.15    # Whisper no_speech_prob at/above this ≈ non-speech clip


def _audio_rms(wav_bytes: bytes) -> float:
    """Normalized RMS energy (0..1) of a 16-bit PCM WAV — how loud the clip was.
    Lets us tell true silence (the hallucination source) from a real, possibly
    quiet, utterance. Returns 1.0 (= 'has speech', never treated as silence) if it
    can't parse, so we FAIL SAFE toward keeping your words."""
    try:
        import io, wave
        import numpy as np
        with wave.open(io.BytesIO(wav_bytes)) as wf:
            frames = wf.readframes(wf.getnframes())
        arr = np.frombuffer(frames, dtype=np.int16).astype(np.float32)
        if arr.size == 0:
            return 0.0
        return float(np.sqrt(np.mean((arr / 32768.0) ** 2)))
    except Exception:  # noqa: BLE001
        return 1.0


def _strip_hallucinations(text: str, has_speech: bool) -> str:
    """Remove Whisper's silence-filler boilerplate. Never removes a phrase you
    actually spoke — `has_speech` gates the ambiguous ones (e.g. a real 'thank
    you' is kept; a hallucinated one on a silent clip is dropped)."""
    s = text.strip()
    if not s:
        return s
    norm = re.sub(r"\s+", " ", re.sub(r"[^\w\s]", "", s.lower())).strip()
    if norm in _HALLUCINATION_ALWAYS:
        log.info("dropped Whisper video-filler: %r", s)
        return ""
    if norm in _HALLUCINATION_IF_SILENT and not has_speech:
        log.info("dropped silence hallucination %r (no speech energy)", s)
        return ""
    for p in _HALLUCINATION_LEAD:
        m = re.match(rf"^{re.escape(p)}[\s.!?,:;\-]*", s, flags=re.IGNORECASE)
        if m:
            rest = s[m.end():].strip()
            if len(rest) >= 12:   # real content remains → keep it, drop the filler
                log.info("stripped leading Whisper filler %r", p)
                return rest
    return s


_TOKEN_RE = re.compile(r"[a-z0-9']+")

# Very common function words carry little content, so a fabrication that happens
# to share "I / the / think / one" with the input shouldn't count as overlap.
_STOPWORDS = frozenset(
    "a an the this that these those i i'm me my we our us you your he she it it's "
    "its they them their and or but so if then as of to in on at for with from by "
    "is are was were be been am do does did have has had will would can could "
    "should may might must not no yes what when where who how why which "
    "there here one ones only just also very really think need".split())


# Second-person words that signal the model started ADDRESSING the speaker
# (i.e. replying) rather than editing their (usually first-person) dictation.
_SECOND_PERSON = frozenset(
    "you your you're youre you've youve you'll youll you'd youd yourself".split())


def _polish_failed(src: str, out: str) -> bool:
    """True if polish clearly failed — regurgitated an example, fabricated,
    summarized, or started replying to the speaker. A safety net so a failed
    polish can never replace the user's words with something unrelated. Signals:

    1) EXPANSION: editing only removes filler, so the output should never be much
       longer than the input. Big growth = the model added/fabricated content.
    2) CONTENT DROP: the output should retain the input's content words (common
       function words excluded); low overlap = regurgitation or summarization.
    3) ADDRESSED THE SPEAKER: second-person words the input didn't have mean the
       model replied ('you're looking to...') instead of editing.
    """
    src_words = _TOKEN_RE.findall(src.lower())
    out_words = _TOKEN_RE.findall(out.lower())
    if len(src_words) < 4:
        return False                                  # too short to judge safely
    if len(out_words) > len(src_words) * 1.5 + 3:
        return True                                   # fabricated / added content
    content = [w for w in src_words if w not in _STOPWORDS]
    if len(content) >= 3:
        out_set = set(out_words)
        kept = sum(1 for w in content if w in out_set)
        if kept / len(content) < 0.5:
            return True                               # regurgitated / summarized
    src_set = set(src_words)
    added_you = sum(1 for w in out_words if w in _SECOND_PERSON and w not in src_set)
    if added_you >= 2:
        return True                                   # started replying to speaker
    return False


def _polish(text: str) -> str:
    if not text.strip():
        return text
    # Polish runs on the stronger prompt model (14B) when available: it reliably
    # applies the formatting the user actually wants (lists, paragraph breaks)
    # while still not answering/paraphrasing. The distilled 8B was faster but,
    # trained on ~87% no-change examples, it grew too conservative and left
    # messier real speech unformatted (its low eval loss reflected matching a
    # conservative teacher, not formatting behavior). Falls back to the local
    # polish model (8B+adapter, then base) if the 14B isn't loaded.
    if _prompt_model is not None:
        model, tok = _prompt_model, _prompt_tok
    else:
        model, tok = _model, _tok
    # System message (rules + reference examples) + one user message with the
    # transcript wrapped in markers, so the model treats it as DATA to edit, not
    # a message to reply to. NO assistant turns (those made it copy an example).
    msgs = [{"role": "system", "content": POLISH_SYS},
            {"role": "user", "content": f"<<<BEGIN>>>\n{text}\n<<<END>>>"}]
    prompt = tok.apply_chat_template(msgs, add_generation_prompt=True)
    # Scale with input so long dictations aren't truncated by the polish step
    # (~1.6 tokens/word, + headroom).
    max_toks = max(400, int(len(text.split()) * 1.8) + 200)
    out = generate(model, tok, prompt=prompt, max_tokens=max_toks, verbose=False).strip()
    # Strip any markers the model echoed back.
    out = out.replace("<<<BEGIN>>>", "").replace("<<<END>>>", "").strip()
    # Safety net: if polish paraphrased, replied, fabricated, or dropped content,
    # keep the (vocab-corrected) verbatim input rather than emit something wrong.
    if not out or _polish_failed(text, out):
        log.warning("polish rejected (kept verbatim): in=%r out=%r", text[:80], out[:80])
        return text
    return out


def _engineer(transcript: str, level: str) -> str:
    """Prompt mode: turn a rough spoken request into an engineered prompt at the
    given level ('concise' | 'detailed' | 'coding'). Uses the stronger prompt
    model. Deliberately generative — no faithfulness guard (structuring is the
    point)."""
    model = _prompt_model if _prompt_model is not None else _model
    tok = _prompt_tok if _prompt_model is not None else _tok
    sys_prompt = PROMPT_SYS_BASE + PROMPT_LEVEL.get(level, PROMPT_LEVEL["concise"])
    msgs = [{"role": "system", "content": sys_prompt},
            {"role": "user", "content": f"<<<REQUEST>>>\n{transcript}\n<<<END>>>"}]
    prompt = tok.apply_chat_template(msgs, add_generation_prompt=True)
    max_toks = 256 if level == "concise" else 800
    out = generate(model, tok, prompt=prompt, max_tokens=max_toks, verbose=False).strip()
    return out.replace("<<<REQUEST>>>", "").replace("<<<END>>>", "").strip()


def _meeting_notes(transcript: str) -> str:
    """Meeting mode: structured notes from a transcript. Uses the stronger model
    (prompt model) when available. Grounded — instructed not to invent facts."""
    model = _prompt_model if _prompt_model is not None else _model
    tok = _prompt_tok if _prompt_model is not None else _tok
    msgs = [{"role": "system", "content": MEETING_SYS},
            {"role": "user", "content": f"<<<TRANSCRIPT>>>\n{transcript}\n<<<END>>>"}]
    prompt = tok.apply_chat_template(msgs, add_generation_prompt=True)
    # Notes are a fraction of the transcript; cap generously but bounded.
    max_toks = min(1600, max(400, len(transcript.split())))
    out = generate(model, tok, prompt=prompt, max_tokens=max_toks, verbose=False).strip()
    return out.replace("<<<TRANSCRIPT>>>", "").replace("<<<END>>>", "").strip()


def _sentence_case(s: str) -> str:
    """Sentence case for titles: capitalise the first word, lower the rest, but
    leave acronyms and product codes (VAT, ISO, AE7) alone. Mirrors
    VF.sentenceCase on the client so both agree."""
    words = s.strip().split()
    out = []
    for i, w in enumerate(words):
        letters = [c for c in w if c.isalpha()]
        if letters and all(c.isupper() for c in letters):
            out.append(w)          # acronym
        elif any(c.isdigit() for c in w):
            out.append(w)          # product code
        elif i == 0:
            out.append(w[:1].upper() + w[1:].lower())
        else:
            out.append(w.lower())
    return " ".join(out)


def _meeting_title(text: str) -> str:
    """A short human title (3-6 words) naming what the meeting was about, so it's
    findable alongside its date. Returns '' on any failure (caller keeps the date
    title). Grounded — names the actual topic, never invents."""
    model = _prompt_model if _prompt_model is not None else _model
    tok = _prompt_tok if _prompt_model is not None else _tok
    if model is None or not text.strip():
        return ""
    sys = ("You write a very short title for a meeting. Reply with ONLY a 3 to 6 word "
           "title naming the main topic or purpose, in Title Case. No date, no "
           "quotes, no trailing punctuation, no preamble — just the title.")
    msgs = [{"role": "system", "content": sys},
            {"role": "user", "content": f"<<<TRANSCRIPT>>>\n{text[:6000]}\n<<<END>>>"}]
    prompt = tok.apply_chat_template(msgs, add_generation_prompt=True)
    try:
        out = generate(model, tok, prompt=prompt, max_tokens=24, verbose=False).strip()
    except Exception as e:  # noqa: BLE001
        log.warning("title generation failed: %s", e)
        return ""
    out = out.replace("<<<TRANSCRIPT>>>", "").replace("<<<END>>>", "").strip()
    if not out:
        return ""
    out = out.splitlines()[0].strip().strip('"').strip("'").rstrip(".").strip()
    return _sentence_case(out[:80])


def _name_speakers(labeled: str) -> tuple[str, dict]:
    """Map generic 'Speaker N' labels to real names ONLY where a speaker's name is
    clearly stated in the conversation (self-introduction, or being addressed by
    name). Leaves the rest as 'Speaker N'. Never invents a name. Returns
    (transcript, applied) — the transcript with confident labels replaced, and
    the {displayed_label: new_name} actually applied, so the caller can keep the
    per-speaker embeddings keyed by what the human now SEES."""
    model = _prompt_model if _prompt_model is not None else _model
    tok = _prompt_tok if _prompt_model is not None else _tok
    if model is None or not labeled.strip():
        return labeled, {}
    present = sorted(set(re.findall(r"Speaker \d+", labeled)))
    if not present:
        return labeled, {}
    sys = ("You map anonymous speaker labels to real names, but ONLY when a "
           "speaker's name is clearly stated in the conversation (they introduce "
           "themselves, or someone clearly addresses them by name). Output STRICT "
           "JSON: an object mapping the exact label to the name, e.g. "
           "{\"Speaker 1\": \"Alex\"}. Include a label ONLY if you are confident. "
           "If no names are determinable, output {}. Output JSON only, nothing else.")
    msgs = [{"role": "system", "content": sys},
            {"role": "user", "content": f"Labels present: {', '.join(present)}\n\n"
                                         f"<<<TRANSCRIPT>>>\n{labeled[:8000]}\n<<<END>>>"}]
    prompt = tok.apply_chat_template(msgs, add_generation_prompt=True)
    try:
        out = generate(model, tok, prompt=prompt, max_tokens=200, verbose=False).strip()
    except Exception as e:  # noqa: BLE001
        log.warning("speaker naming failed: %s", e)
        return labeled, {}
    m = re.search(r"\{.*\}", out, flags=re.DOTALL)
    if not m:
        return labeled, {}
    try:
        mapping = json.loads(m.group(0))
    except Exception:  # noqa: BLE001
        return labeled, {}
    result, applied = labeled, {}
    for label, name in (mapping or {}).items():
        if not isinstance(name, str) or not name.strip():
            continue
        lbl = str(label).strip()
        if not re.fullmatch(r"Speaker \d+", lbl):
            continue
        nm = name.strip()[:40]
        if f"**{lbl}:**" not in result:
            continue
        result = result.replace(f"**{lbl}:**", f"**{nm}:**")
        applied[lbl] = nm
    return result, applied


# Cosine similarity above this means "same voice" ACROSS meetings — different
# room, different microphone, months apart. Tuned from real meetings — start at
# 0.75 and adjust from the logged scores, the same way the ASR no_speech_prob
# threshold was corrected once real data disproved the guess.
# Fingerprint of the embedding space these vectors live in. Bump whenever the
# diarization model changes so old vectors are ignored rather than mis-matched.
EMBEDDING_MODEL = os.environ.get("VF_EMBEDDING_MODEL", "pyannote/speaker-diarization-3.1")
# Uploaded meeting audio is spooled here so a server restart cannot lose it.
SPOOL_DIR = os.environ.get("VF_SPOOL_DIR", os.path.join(os.path.dirname(__file__), "spool"))


def _spool_path(job_id: int) -> str:
    return os.path.join(SPOOL_DIR, f"meeting-{job_id}.wav")


VOICEPRINT_THRESHOLD = float(os.environ.get("VF_VOICEPRINT_THRESHOLD", "0.75"))
# A match must beat the runner-up by this much. Without a margin, two similar
# voices yield a confident-looking but essentially arbitrary winner.
VOICEPRINT_MARGIN = float(os.environ.get("VF_VOICEPRINT_MARGIN", "0.05"))

# Merging over-split labels is a DIFFERENT question: same recording, same mic,
# minutes apart, so two fragments of one voice should score far higher than a
# cross-meeting match. Reusing 0.75 here makes a false merge plausible, and a
# false merge silently attributes one person's words to another with no undo.
# Every comparison is logged with its score so this can be tuned from real data.
MERGE_THRESHOLD = float(os.environ.get("VF_MERGE_THRESHOLD", "0.85"))


def _cosine(a, b) -> float:
    """Cosine similarity of two embedding vectors. Returns 0.0 for empty or
    mismatched input rather than raising — a bad vector must never fail a
    meeting."""
    if not a or not b or len(a) != len(b):
        return 0.0
    dot = sum(x * y for x, y in zip(a, b))
    na = sum(x * x for x in a) ** 0.5
    nb = sum(y * y for y in b) ** 0.5
    if na == 0 or nb == 0:
        return 0.0
    return dot / (na * nb)


def _merge_oversplit(turns, embeddings, threshold: float = MERGE_THRESHOLD) -> dict:
    """Map each diarized label to a canonical label, collapsing labels that are
    really the same voice. Diarization over-splits badly on long calls (one real
    meeting produced 9 labels for ~4 people), which is what makes the speaker
    count untrustworthy. Returns {label: canonical_label} covering every label
    seen in `turns`."""
    labels = list(dict.fromkeys(t["speaker"] for t in turns))
    mapping = {l: l for l in labels}
    if not embeddings:
        return mapping
    canonical = []
    for label in labels:
        vec = embeddings.get(label)
        if not vec:
            canonical.append(label)
            continue
        # Score every canonical speaker and take the BEST, not the first one over
        # the line. A merge is destructive: it permanently attributes one
        # person's words to another and there is no UI to split them again — so
        # it must also clearly beat the runner-up, or stay split.
        scored = []
        for c in canonical:
            cvec = embeddings.get(c)
            if not cvec:
                continue
            score = _cosine(vec, cvec)
            # Log EVERY comparison, not just the matches — a threshold you can
            # only see hits for is a threshold you cannot tune.
            log.info("merge check %s vs %s score=%.3f threshold=%.2f",
                     label, c, score, threshold)
            scored.append((score, c))
        scored.sort(reverse=True)
        hit, hit_score = None, 0.0
        if scored:
            top, top_label = scored[0]
            second = scored[1][0] if len(scored) > 1 else 0.0
            if top >= threshold and (top - second) >= VOICEPRINT_MARGIN:
                hit, hit_score = top_label, top
            elif top >= threshold:
                log.info("merge %s -> %s REJECTED as ambiguous (top=%.3f second=%.3f)",
                         label, top_label, top, second)
        if hit:
            mapping[label] = hit
            log.info("merged %s into %s (same voice, score=%.3f)", label, hit, hit_score)
        else:
            canonical.append(label)
    return mapping


def _match_voiceprints(embeddings) -> dict:
    """Map diarized labels to known human names by voice. Only confident matches
    are returned; everything else stays an anonymous speaker."""
    if not embeddings:
        return {}
    con = sqlite3.connect(DB_PATH)
    con.row_factory = sqlite3.Row
    rows = con.execute("SELECT name, embedding, model, dims FROM voiceprints").fetchall()
    con.close()
    known = []
    for r in rows:
        try:
            vec_k = json.loads(r["embedding"])
            # Refuse to compare across embedding spaces or dimensions — the score
            # would be numerically fine and semantically garbage.
            row_model = (r["model"] if "model" in r.keys() else "") or ""
            if row_model and row_model != EMBEDDING_MODEL:
                log.info("voiceprint %s ignored (model %s != %s)",
                         r["name"], row_model, EMBEDDING_MODEL)
                continue
            known.append((r["name"], vec_k))
        except Exception:  # noqa: BLE001
            continue
    # Assign GLOBALLY and ONE-TO-ONE, strongest pair first. Matching each label
    # independently allowed two different people to both win the same name,
    # collapsing two humans into one identity in a durable transcript with no way
    # to separate them. A name is accepted only when it clearly beats the
    # runner-up: an ambiguous match is worse than an anonymous speaker, because
    # "Speaker 2" is visibly unknown while a confident wrong name is not.
    pairs = []
    for label, vec in embeddings.items():
        scored = sorted(((_cosine(vec, kvec), name) for name, kvec in known), reverse=True)
        if not scored:
            continue
        best_score, best_name = scored[0]
        runner_up = scored[1][0] if len(scored) > 1 else 0.0
        log.info("voiceprint %s best=%s score=%.3f runnerUp=%.3f",
                 label, best_name, best_score, runner_up)
        if best_score >= VOICEPRINT_THRESHOLD and (best_score - runner_up) >= VOICEPRINT_MARGIN:
            pairs.append((best_score, label, best_name))

    out = {}
    taken_names, taken_labels = set(), set()
    for score, label, name in sorted(pairs, reverse=True):
        if label in taken_labels or name in taken_names:
            log.info("voiceprint %s -> %s rejected (name already assigned)", label, name)
            continue
        out[label] = name
        taken_labels.add(label); taken_names.add(name)
    return out


def _store_voiceprint(name: str, vec) -> None:
    """Remember this voice under this name. A human-set name always wins: the
    stored vector is refreshed so the voiceprint tracks the person's current
    microphone."""
    if not name or not vec:
        return
    con = sqlite3.connect(DB_PATH)
    con.execute(
        "INSERT INTO voiceprints (name, embedding, model, dims) VALUES (?, ?, ?, ?) "
        "ON CONFLICT(name) DO UPDATE SET embedding=excluded.embedding, "
        "model=excluded.model, dims=excluded.dims, "
        "meetings_seen=meetings_seen+1, updated_at=CURRENT_TIMESTAMP",
        (name.strip()[:40], json.dumps([float(v) for v in vec]),
         EMBEDDING_MODEL, len(vec)))
    con.commit()
    con.close()


def _display_embeddings(display: dict, embeddings: dict) -> dict:
    """Re-key raw diarization vectors by the label the human SEES.

    `display` comes from _label_transcript's `order` (plus any names applied on
    top). Anything the human never saw is DROPPED: a vector with no visible label
    can only ever be attached to the wrong name, and a wrong voiceprint is
    written to durable storage and silently reused for every future meeting."""
    return {display[raw]: vec for raw, vec in embeddings.items()
            if raw in display and vec}


def _rename_in_notes(notes: str, old: str, new: str) -> str:
    """Word-anchored rename inside meeting notes. The transcript rewrite is
    anchored on '**name:**'; notes have no such anchor, so a bare substring
    replace over a durable row with no undo would turn "Alan" into "Alexan" when
    you rename "Al" to "Alex"."""
    if not notes or not old:
        return notes or ""
    return re.sub(rf"(?<!\w){re.escape(old)}(?!\w)", new, notes)


def _save_meeting_embeddings(job_id: int, disp: dict) -> None:
    """Persist this meeting's per-speaker vectors, keyed by the label the human
    SEES. In-memory only was a silent lie: after any server restart, renaming a
    speaker on an older meeting stored nothing while the dialog promised
    "WhisperType will remember this voice"."""
    if not disp:
        return
    try:
        con = sqlite3.connect(DB_PATH)
        con.execute(
            "INSERT INTO meeting_embeddings (meeting_id, data) VALUES (?, ?) "
            "ON CONFLICT(meeting_id) DO UPDATE SET data=excluded.data",
            (job_id, json.dumps({k: [float(v) for v in vec]
                                 for k, vec in disp.items() if vec})))
        con.commit()
        con.close()
    except Exception as e:  # noqa: BLE001
        log.warning("meeting %d embedding persist failed: %s", job_id, e)


def _load_meeting_embeddings(job_id: int) -> dict:
    """Displayed-label → vector for a meeting, from the durable table."""
    try:
        con = sqlite3.connect(DB_PATH)
        row = con.execute("SELECT data FROM meeting_embeddings WHERE meeting_id=?",
                          (job_id,)).fetchone()
        con.close()
        return json.loads(row[0]) if row and row[0] else {}
    except Exception as e:  # noqa: BLE001
        log.warning("meeting %d embedding load failed: %s", job_id, e)
        return {}


def _forget_meeting_embeddings(job_id: int) -> None:
    """Biometric vectors must not outlive the meeting the human deleted."""
    _meeting_embeddings.pop(job_id, None)
    try:
        con = sqlite3.connect(DB_PATH)
        con.execute("DELETE FROM meeting_embeddings WHERE meeting_id=?", (job_id,))
        con.commit()
        con.close()
    except Exception as e:  # noqa: BLE001
        log.warning("meeting %d embedding delete failed: %s", job_id, e)


def _diarize(wav_bytes: bytes):
    """Run speaker diarization in the isolated venv (subprocess). Returns
    (turns, embeddings) — turns is the list of speaker turns, embeddings maps
    each speaker label to its voice vector (empty on failure, or if
    unavailable — caller falls back to an unlabeled transcript). Audio stays
    local — written to a temp file only for the subprocess, then removed."""
    import subprocess, tempfile
    if not (os.path.exists(DIARIZE_PY) and os.path.exists(DIARIZE_SCRIPT)):
        return [], {}
    tmp = None
    try:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            f.write(wav_bytes); tmp = f.name
        proc = subprocess.run([DIARIZE_PY, DIARIZE_SCRIPT, tmp],
                              capture_output=True, text=True, timeout=1800)
        out = json.loads(proc.stdout.strip() or "{}")
        if out.get("error"):
            log.warning("diarization error: %s", out["error"])
        return out.get("turns", []), out.get("embeddings", {})
    except Exception as e:  # noqa: BLE001
        log.warning("diarization subprocess failed: %s", e)
        return [], {}
    finally:
        if tmp:
            try: os.unlink(tmp)
            except OSError: pass


def _check_auth(authorization: str | None):
    if API_KEY and authorization != f"Bearer {API_KEY}":
        raise HTTPException(status_code=401, detail="invalid or missing API key")


async def _resume_spooled_jobs():
    """Re-queue meetings whose audio survived a restart on disk. Without this the
    spool is just wasted bytes: the upload is safe but nothing ever picks it up."""
    con = sqlite3.connect(DB_PATH); con.row_factory = sqlite3.Row
    rows = con.execute("SELECT id, language, diarize, translate FROM meetings "
                       "WHERE status='processing'").fetchall()
    con.close()
    for r in rows:
        path = _spool_path(r["id"])
        if not os.path.exists(path):
            continue
        try:
            with open(path, "rb") as f:
                audio = f.read()
        except OSError as e:
            log.error("resume: cannot read spool for job %s: %s", r["id"], e)
            continue
        log.info("resuming meeting job %s from spool (%d bytes)", r["id"], len(audio))
        asyncio.create_task(_process_meeting(
            r["id"], audio, (r["language"] or None),
            bool(r["diarize"]), bool(r["translate"])))


@app.on_event("startup")
async def _startup():
    global _model, _tok, _polish_distilled
    _load_vocab()
    _init_db()
    asyncio.create_task(_resume_spooled_jobs())
    if POLISH_ENABLED:
        t0 = time.time()
        adapter = POLISH_ADAPTER if os.path.exists(os.path.join(POLISH_ADAPTER, "adapters.safetensors")) else None
        _polish_distilled = adapter is not None
        log.info("loading polish model %s (adapter=%s) ...", POLISH_MODEL, adapter or "none")
        try:
            _model, _tok = load(POLISH_MODEL, adapter_path=adapter) if adapter else load(POLISH_MODEL)
        except Exception as e:  # noqa: BLE001
            log.warning("adapter load failed (%s); loading base polish model", e)
            _model, _tok = load(POLISH_MODEL)
            _polish_distilled = False
        _polish("warming up the model now")  # force graph compile so first real call is fast
        log.info("polish model warm in %.1fs (distilled=%s)", time.time() - t0, _polish_distilled)
    if PROMPT_ENABLED:
        # Background — the 14B may need a one-time ~8GB download; don't block startup.
        asyncio.create_task(_load_prompt_model())
    if LLM_NEEDED:
        asyncio.create_task(_keepalive())
    else:
        log.info("LLM DISABLED (near-verbatim dictation, no prompt mode); models not loaded")


async def _load_prompt_model():
    """Load the stronger prompt-engineering model in the background. Falls back
    to the fast polish model if it can't be loaded, so prompt mode still works."""
    global _prompt_model, _prompt_tok
    t0 = time.time()
    log.info("loading prompt model %s (background) ...", PROMPT_MODEL)
    try:
        _prompt_model, _prompt_tok = await asyncio.to_thread(load, PROMPT_MODEL)
        await asyncio.to_thread(_engineer, "warm up", "concise")  # force graph compile
        log.info("prompt model (%s) warm in %.1fs", PROMPT_MODEL, time.time() - t0)
    except Exception as e:  # noqa: BLE001
        log.warning("prompt model load failed (%s); falling back to polish model", e)
        if _model is not None:
            _prompt_model, _prompt_tok = _model, _tok
        else:
            try:
                _prompt_model, _prompt_tok = await asyncio.to_thread(load, POLISH_MODEL)
                log.info("prompt fallback: loaded %s", POLISH_MODEL)
            except Exception as e2:  # noqa: BLE001
                log.error("prompt fallback load failed: %s", e2)

    if _WHISPER_LOCAL:
        try:
            import numpy as np
            tw = time.time()
            mlx_whisper.transcribe(np.zeros(16000, dtype=np.float32),
                                   path_or_hf_repo=WHISPER_MODEL)
            log.info("local whisper (%s) warm in %.1fs", WHISPER_MODEL, time.time() - tw)
        except Exception as e:  # noqa: BLE001
            log.warning("local whisper warmup failed (%s); will use remote HTTP whisper", e)
            globals()["_WHISPER_LOCAL"] = False
    else:
        log.info("local whisper unavailable; using remote HTTP whisper at %s", WHISPER_URL)


async def _keepalive():
    """Tiny periodic generation so macOS never pages the resident models out.
    Pings whichever models are loaded (polish 8B and/or the separate prompt 14B)."""
    while True:
        await asyncio.sleep(KEEPALIVE_SEC)
        try:
            if _model is not None:
                await asyncio.to_thread(_polish, "keep warm")
            if _prompt_model is not None and _prompt_model is not _model:
                await asyncio.to_thread(_engineer, "keep warm", "concise")
            log.debug("keepalive ok")
        except Exception as e:  # noqa: BLE001
            log.warning("keepalive failed: %s", e)


async def _run_asr(audio: bytes, filename: str | None, language: str | None):
    """Transcribe audio -> (raw_text, asr_ms). Local biased Whisper first, with
    the shared HTTP whisper server as fallback. Shared by /WhisperType and
    /engineer."""
    t_asr = time.time()
    raw, nsp = "", 0.0
    if _WHISPER_LOCAL:
        try:
            raw, nsp = await asyncio.to_thread(_transcribe_local, audio, language)
        except Exception as e:  # noqa: BLE001
            log.warning("local ASR failed (%s); falling back to remote", e)
            raw, nsp = "", 0.0
    if not raw:
        try:
            raw = _transcribe_remote(audio, filename or "audio.wav", language)
            nsp = 0.0   # remote gives no probability → treat as speech (keep)
        except Exception as e:  # noqa: BLE001
            log.error("ASR failed: %s", e)
            raise HTTPException(status_code=502, detail=f"ASR backend error: {e}")
    # Whisper's own no-speech probability is the reliable silence signal (a mic
    # noise-floor defeats a raw-energy threshold). RMS is a secondary guard.
    rms = _audio_rms(audio)
    silent = (nsp >= _NO_SPEECH_PROB) or (rms < _SILENCE_RMS)
    if len(raw) <= 30 or silent:
        log.info("asr signals nsp=%.2f rms=%.4f silent=%s raw=%r", nsp, rms, silent, raw[:40])
    raw = _strip_hallucinations(raw, has_speech=not silent)
    return raw, int((time.time() - t_asr) * 1000)


@app.get("/health")
async def health():
    if not PROMPT_ENABLED:
        prompt_state = "off"
    elif _prompt_model is None:
        prompt_state = "loading"
    elif _prompt_model is _model:
        prompt_state = "on (fallback: polish model)"
    else:
        prompt_state = "on"
    return {
        "status": "ok",
        "polish": "on" if (POLISH_ENABLED and _model is not None) else "off (near-verbatim)",
        "polish_distilled": _polish_distilled,
        "prompt_mode": prompt_state,
        "polish_model": POLISH_MODEL if _model is not None else None,
        "prompt_model": PROMPT_MODEL if (_prompt_model is not None and _prompt_model is not _model) else None,
        "whisper": WHISPER_MODEL if _WHISPER_LOCAL else f"remote:{WHISPER_URL}",
        "biasing": _WHISPER_LOCAL,
    }


@app.post("/dictate")
async def voice_flow(
    file: UploadFile = File(...),
    language: str | None = Form(None),
    polish: bool | None = Form(None),   # None → server default (VF_POLISH); off by default
    authorization: str | None = Header(None),
):
    _check_auth(authorization)
    audio = await file.read()

    # 1) ASR — local biased Whisper (spells your vocab right), HTTP fallback.
    raw, asr_ms = await _run_asr(audio, file.filename, language)

    # 2) Deterministic vocab corrections on the raw ASR (names, jargon, snippets).
    #    This is the near-verbatim output — faithful to what was said.
    corrected = apply_vocab(raw)

    # 3) Optional LLM polish (off by default; see POLISH_ENABLED). Only runs when
    #    explicitly requested AND the model is loaded.
    do_polish = (POLISH_ENABLED if polish is None else polish) and _model is not None
    text = corrected
    polish_ms = 0
    if do_polish and corrected:
        t_p = time.time()
        text = await asyncio.to_thread(_polish, corrected)
        polish_ms = int((time.time() - t_p) * 1000)

    log.info("WhisperType ok asr=%dms polish=%dms chars=%d", asr_ms, polish_ms, len(text))
    row_id = _capture(raw, corrected, text, asr_ms, polish_ms, len(audio), audio)
    return JSONResponse({
        "id": row_id,
        "raw": raw,
        "corrected": corrected,
        "text": text,
        "timing_ms": {"asr": asr_ms, "polish": polish_ms},
    })


@app.post("/engineer")
async def engineer(
    file: UploadFile = File(...),
    language: str | None = Form(None),
    authorization: str | None = Header(None),
):
    """Prompt mode: transcribe a rough spoken request, then engineer it into a
    CONCISE and a DETAILED prompt. Returns both so the client can flip instantly.
    Deliberately generative — isolated from the faithful dictation pipeline."""
    _check_auth(authorization)
    if not PROMPT_ENABLED:
        raise HTTPException(status_code=503, detail="prompt mode not enabled on server")
    if _prompt_model is None and _model is None:
        raise HTTPException(status_code=503, detail="prompt model still loading")
    audio = await file.read()
    raw, asr_ms = await _run_asr(audio, file.filename, language)
    transcript = apply_vocab(raw)   # so your names/jargon are spelled right in the prompt
    if not transcript.strip():
        raise HTTPException(status_code=422, detail="no speech detected")
    t_g = time.time()
    concise = await asyncio.to_thread(_engineer, transcript, "concise")
    detailed = await asyncio.to_thread(_engineer, transcript, "detailed")
    coding = await asyncio.to_thread(_engineer, transcript, "coding")
    gen_ms = int((time.time() - t_g) * 1000)
    log.info("engineer ok asr=%dms gen=%dms concise=%dch detailed=%dch coding=%dch",
             asr_ms, gen_ms, len(concise), len(detailed), len(coding))
    return JSONResponse({
        "raw": raw,
        "concise": concise,
        "detailed": detailed,
        "coding": coding,
        "timing_ms": {"asr": asr_ms, "gen": gen_ms},
    })


def _meeting_set(job_id, **cols):
    """Update a meeting job row."""
    if not cols:
        return
    con = sqlite3.connect(DB_PATH)
    try:
        sets = ", ".join(f"{k}=?" for k in cols)
        con.execute(f"UPDATE meetings SET {sets} WHERE id=?", (*cols.values(), job_id))
        con.commit()
    finally:
        con.close()


# Diarization embeddings for recently processed meetings, keyed by the label the
# human SEES, so renaming a speaker stores THAT person's voiceprint. This is only
# a hot cache in front of the durable `meeting_embeddings` table — a miss falls
# back to the table, so a server restart never silently drops a voice.
_meeting_embeddings: dict[int, dict] = {}


async def _process_meeting(job_id: int, audio: bytes, language: str | None,
                           diarize: bool, translate: bool):
    """Background worker: transcribe (optionally translate→English) → diarize →
    notes, writing results to the DURABLE meetings row. Runs detached from the
    HTTP request, so the result survives even if the client disconnects."""
    try:
        want_diar = diarize and _WHISPER_LOCAL and os.path.exists(DIARIZE_PY)
        t_asr = time.time()
        if want_diar:
            try:
                raw, segs = await asyncio.to_thread(_transcribe_local_segments, audio, language, translate)
            except Exception as e:  # noqa: BLE001
                log.warning("segment ASR failed (%s); plain ASR", e)
                (raw, _nsp), segs = await asyncio.to_thread(_transcribe_local, audio, language), []
        else:
            (raw, _nsp), segs = await asyncio.to_thread(_transcribe_local, audio, language), []
        asr_ms = int((time.time() - t_asr) * 1000)
        transcript = apply_vocab(raw)
        if not transcript.strip():
            _meeting_set(job_id, status="error", error="no speech detected", asr_ms=asr_ms)
            return

        speakers, diar_ms = 0, 0
        if want_diar and segs:
            t = time.time()
            turns, embeddings = await asyncio.to_thread(_diarize, audio)
            if turns:
                # Collapse over-split labels first, so the speaker count is real.
                merge = _merge_oversplit(turns, embeddings)
                turns = [{**t, "speaker": merge.get(t["speaker"], t["speaker"])} for t in turns]
                # Keep only the SURVIVING labels' own vectors. Rebuilding the dict
                # by rewriting keys let the discarded fragment win (dict order),
                # so the surviving speaker carried the wrong voice.
                embeddings = {c: embeddings[c] for c in dict.fromkeys(merge.values())
                              if c in embeddings}

                labeled, order = _label_transcript(
                    [(s, e, apply_vocab(txt)) for s, e, txt in segs], turns)
                if labeled:
                    # `order` (raw label -> the "Speaker N" actually shown) is the
                    # ONLY enumeration used from here on. `display` tracks what
                    # each raw speaker is currently called as names get applied.
                    display = dict(order)
                    # Known voices get their real names with no introduction needed.
                    known = {}
                    try:
                        known = _match_voiceprints(embeddings)
                    except Exception as e:  # noqa: BLE001
                        # A voiceprint lookup must never destroy a transcript that
                        # ASR already produced — the audio is not retained.
                        log.warning("voiceprint matching failed (%s); staying anonymous", e)
                    for raw_label, name in known.items():
                        generic = order.get(raw_label)
                        if generic:
                            labeled = labeled.replace(f"**{generic}:**", f"**{name}:**")
                            display[raw_label] = name
                    # Then let the LLM name anyone who introduced themselves.
                    transcript, applied = await asyncio.to_thread(_name_speakers, labeled)
                    for raw_label, shown in list(display.items()):
                        if shown in applied:
                            display[raw_label] = applied[shown]
                    speakers = len({t_["speaker"] for t_ in turns})
                    disp = _display_embeddings(display, embeddings)
                    _meeting_embeddings[job_id] = disp
                    _save_meeting_embeddings(job_id, disp)
            diar_ms = int((time.time() - t) * 1000)

        # Processing succeeded — the spooled upload is no longer needed.
        try:
            sp = _spool_path(job_id)
            if os.path.exists(sp):
                os.unlink(sp)
        except OSError:
            pass

        # COMMIT THE TRANSCRIPT FIRST. Notes and titles are conveniences; the
        # transcript is the irreplaceable artifact and the audio is not retained
        # server-side. Previously an exception in either optional step reached the
        # outer handler, which marked the whole job "error" and threw away ASR and
        # diarization work that had already succeeded — an hour of a real meeting
        # lost to a summarizer running out of context.
        _meeting_set(job_id, status="done", transcript=transcript, notes="",
                     speakers=speakers, asr_ms=asr_ms, diar_ms=diar_ms, notes_ms=0)

        notes_text, notes_ms = "", 0
        if _model is not None:
            t = time.time()
            try:
                notes_text = await asyncio.to_thread(_meeting_notes, transcript)
                notes_ms = int((time.time() - t) * 1000)
                _meeting_set(job_id, notes=notes_text, notes_ms=notes_ms)
            except Exception as e:  # noqa: BLE001
                log.error("meeting job %d: notes failed (transcript is safe): %s", job_id, e)

        # Name the meeting after what was discussed (the client only supplied a
        # date/time placeholder). Keep a manual title if one was actually typed.
        try:
            auto_title = await asyncio.to_thread(_meeting_title, transcript)
            if auto_title:
                _meeting_set(job_id, title=auto_title)
        except Exception as e:  # noqa: BLE001
            log.error("meeting job %d: title failed (transcript is safe): %s", job_id, e)
        log.info("meeting job %d done asr=%dms diar=%dms notes=%dms speakers=%d chars=%d",
                 job_id, asr_ms, diar_ms, notes_ms, speakers, len(transcript))
    except Exception as e:  # noqa: BLE001
        log.error("meeting job %d failed: %s", job_id, e)
        _meeting_set(job_id, status="error", error=str(e))


@app.post("/meeting")
async def meeting(
    file: UploadFile = File(...),
    language: str | None = Form(None),
    diarize: bool = Form(True),
    translate: bool = Form(True),   # meetings default to English output
    title: str = Form(""),
    authorization: str | None = Header(None),
):
    """Submit a meeting recording for ASYNC processing. Returns a job id
    immediately; the durable result is fetched via /meetings and /meeting/{id}.
    This decouples long (10+ min) transcription from the client connection, so a
    result is never lost if the app closes."""
    _check_auth(authorization)
    audio = await file.read()
    con = sqlite3.connect(DB_PATH)
    cur = con.execute("INSERT INTO meetings (title, status) VALUES (?, 'processing')", (title,))
    job_id = cur.lastrowid
    con.commit(); con.close()

    # SPOOL THE AUDIO TO DISK BEFORE RETURNING SUCCESS. Previously the only copy
    # of the upload lived inside an in-process asyncio task: a restart killed the
    # task, startup marked the row errored, and the recording was gone — despite
    # the endpoint having already told the client it was safely queued.
    try:
        os.makedirs(SPOOL_DIR, exist_ok=True)
        with open(_spool_path(job_id), "wb") as f:
            f.write(audio)
        _meeting_set(job_id, language=language or "", diarize=1 if diarize else 0,
                     translate=1 if translate else 0)
    except Exception as e:  # noqa: BLE001
        log.error("meeting job %d: could not spool audio (%s) — processing in memory only", job_id, e)

    asyncio.create_task(_process_meeting(job_id, audio, language, diarize, translate))
    log.info("meeting job %d queued (%d bytes, translate=%s)", job_id, len(audio), translate)
    return JSONResponse({"id": job_id, "status": "processing"})


@app.get("/meetings")
async def list_meetings(limit: int = 50):
    con = sqlite3.connect(DB_PATH); con.row_factory = sqlite3.Row
    rows = con.execute(
        "SELECT id, ts, title, status, speakers, error, length(transcript) AS chars "
        "FROM meetings ORDER BY id DESC LIMIT ?", (max(1, min(limit, 200)),)).fetchall()
    con.close()
    return {"items": [dict(r) for r in rows]}


@app.get("/meeting/{job_id}")
async def get_meeting(job_id: int):
    con = sqlite3.connect(DB_PATH); con.row_factory = sqlite3.Row
    row = con.execute("SELECT * FROM meetings WHERE id=?", (job_id,)).fetchone()
    con.close()
    if row is None:
        raise HTTPException(status_code=404, detail="no meeting with that id")
    return dict(row)


@app.post("/meeting/{job_id}/title")
async def rename_meeting(job_id: int, title: str = Form(...),
                         authorization: str | None = Header(None)):
    """Rename a meeting."""
    _check_auth(authorization)
    clean = title.strip()[:120]
    con = sqlite3.connect(DB_PATH)
    cur = con.execute("UPDATE meetings SET title=? WHERE id=?", (clean, job_id))
    con.commit(); n = cur.rowcount; con.close()
    if not n:
        raise HTTPException(status_code=404, detail="no meeting with that id")
    return {"id": job_id, "title": clean}


@app.post("/meeting/{job_id}/speaker")
async def rename_speaker(job_id: int, frm: str = Form(...), to: str = Form(...),
                         authorization: str | None = Header(None)):
    """Rename a speaker throughout a meeting, and remember that voice so the same
    person is recognised in future meetings without any introduction."""
    _check_auth(authorization)
    old, new = frm.strip(), to.strip()[:40]
    if not old or not new:
        raise HTTPException(status_code=400, detail="both names are required")
    con = sqlite3.connect(DB_PATH)
    con.row_factory = sqlite3.Row
    row = con.execute("SELECT transcript, notes FROM meetings WHERE id=?", (job_id,)).fetchone()
    if row is None:
        con.close()
        raise HTTPException(status_code=404, detail="no meeting with that id")
    transcript = (row["transcript"] or "").replace(f"**{old}:**", f"**{new}:**")
    notes = _rename_in_notes(row["notes"] or "", old, new)
    con.execute("UPDATE meetings SET transcript=?, notes=? WHERE id=?", (transcript, notes, job_id))
    con.commit(); con.close()

    # Teach the voice, so next time this person is named from the first line.
    # The embeddings are keyed by the DISPLAYED label — the same name the human
    # just clicked — so no second, disagreeing enumeration can pick the wrong
    # person's vector. Falls back to the durable table after a restart.
    emb = _meeting_embeddings.get(job_id) or _load_meeting_embeddings(job_id)
    vec = emb.get(old)
    if vec:
        _store_voiceprint(new, vec)
        # Keep the cache addressable under the new name, so renaming twice works.
        emb = {**emb, new: vec}
        emb.pop(old, None)
        _meeting_embeddings[job_id] = emb
        _save_meeting_embeddings(job_id, emb)
    else:
        log.info("meeting %d: no voiceprint stored for %r (no embedding)", job_id, old)
    return {"id": job_id, "from": old, "to": new}


@app.delete("/meeting/{job_id}")
async def delete_meeting(job_id: int, authorization: str | None = Header(None)):
    """Delete a meeting permanently."""
    _check_auth(authorization)
    con = sqlite3.connect(DB_PATH)
    cur = con.execute("DELETE FROM meetings WHERE id=?", (job_id,))
    con.commit(); n = cur.rowcount; con.close()
    if not n:
        raise HTTPException(status_code=404, detail="no meeting with that id")
    # Voice vectors are biometric data — they must not outlive the meeting.
    _forget_meeting_embeddings(job_id)
    return {"id": job_id, "deleted": True}


@app.get("/voiceprints")
async def list_voiceprints():
    """What voices this server has learned — biometric data should be inspectable."""
    con = sqlite3.connect(DB_PATH); con.row_factory = sqlite3.Row
    rows = con.execute("SELECT name, meetings_seen, model, dims, updated_at "
                       "FROM voiceprints ORDER BY name").fetchall()
    con.close()
    return {"items": [dict(r) for r in rows]}


@app.delete("/voiceprint/{name}")
async def forget_voiceprint(name: str, authorization: str | None = Header(None)):
    """Forget a learned voice. Biometric data with no delete path is not
    acceptable, even on a single-user server."""
    _check_auth(authorization)
    con = sqlite3.connect(DB_PATH)
    cur = con.execute("DELETE FROM voiceprints WHERE name=?", (name,))
    con.commit(); n = cur.rowcount; con.close()
    if not n:
        raise HTTPException(status_code=404, detail="no voiceprint with that name")
    log.info("voiceprint forgotten: %s", name)
    return {"name": name, "forgotten": True}


@app.post("/meetings/retitle")
async def retitle_meetings(authorization: str | None = Header(None)):
    """Backfill content titles for existing meetings still on the default
    'Meeting <date>' placeholder — so old recordings become findable too."""
    _check_auth(authorization)
    con = sqlite3.connect(DB_PATH); con.row_factory = sqlite3.Row
    rows = con.execute("SELECT id, title, transcript FROM meetings "
                       "WHERE status='done'").fetchall()
    con.close()
    retitled = []
    for r in rows:
        if r["transcript"] and re.match(r"^Meeting \d{4}-\d\d-\d\d", r["title"] or ""):
            auto = await asyncio.to_thread(_meeting_title, r["transcript"])
            if auto:
                _meeting_set(r["id"], title=auto)
                retitled.append({"id": r["id"], "title": auto})
    return {"retitled": retitled}


# ---------------------------------------------------------------------------
# Vocabulary endpoints (live learning) — add corrections/terms/snippets without
# a redeploy. The client (or you) can POST fixes as you notice them.
# ---------------------------------------------------------------------------
@app.get("/vocab")
async def get_vocab():
    return _vocab


@app.post("/vocab")
async def update_vocab(payload: dict, authorization: str | None = Header(None)):
    _check_auth(authorization)
    # Merge: {"replacements": {...}, "terms": [...], "snippets": {...}}
    if "replacements" in payload:
        _vocab["replacements"].update(payload["replacements"])
    if "snippets" in payload:
        _vocab["snippets"].update(payload["snippets"])
    if "terms" in payload:
        for t in payload["terms"]:
            if t not in _vocab["terms"]:
                _vocab["terms"].append(t)
    _save_vocab()
    log.info("vocab updated: %d replacements, %d terms, %d snippets",
             len(_vocab["replacements"]), len(_vocab["terms"]), len(_vocab["snippets"]))
    return _vocab


# ---------------------------------------------------------------------------
# Capture store — persist every dictation so the tool can learn over time
# (raw ASR -> corrected -> polished, timings). This is the substrate for the
# style/correction learning loops. Edit-capture (what you change afterwards)
# comes next.
# ---------------------------------------------------------------------------
import sqlite3  # noqa: E402
import difflib  # noqa: E402

DB_PATH = os.environ.get("VF_DB_PATH", os.path.join(os.path.dirname(__file__), "history.sqlite"))


def _init_db():
    try:
        con = sqlite3.connect(DB_PATH)
        con.execute("""CREATE TABLE IF NOT EXISTS history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts TEXT DEFAULT CURRENT_TIMESTAMP,
            raw TEXT, corrected TEXT, polished TEXT, edited TEXT,
            asr_ms INTEGER, polish_ms INTEGER, audio_bytes INTEGER,
            num_words INTEGER)""")
        # Retain the audio (WAV bytes) so a dictation is NEVER unrecoverable — a
        # bad transcription can be re-run, and it builds a personal training set.
        try:
            con.execute("ALTER TABLE history ADD COLUMN audio BLOB")
        except sqlite3.OperationalError:
            pass  # column already exists
        # Learning candidates: fixes derived from your corrections (POST /correct)
        # or a deterministic history scan. Never auto-applied — you approve each
        # one, which promotes it into the live vocab. UNIQUE so re-seeing a fix
        # bumps its count instead of duplicating; dismissed ones stay dismissed.
        con.execute("""CREATE TABLE IF NOT EXISTS suggestions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            kind TEXT NOT NULL,                 -- 'replacement' | 'term'
            frm TEXT NOT NULL DEFAULT '',       -- replacement source (heard); '' for terms
            to_ TEXT NOT NULL,                  -- replacement target, or the term itself
            count INTEGER NOT NULL DEFAULT 1,
            status TEXT NOT NULL DEFAULT 'pending',  -- pending | promoted | dismissed
            source TEXT NOT NULL DEFAULT 'edit',     -- edit | scan
            ts TEXT DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(kind, frm, to_))""")
        # Meeting jobs — async & DURABLE so a long transcription's result is never
        # lost if the client disconnects/quits (the whole reason meeting output
        # vanished before). status: processing | done | error.
        con.execute("""CREATE TABLE IF NOT EXISTS meetings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts TEXT DEFAULT CURRENT_TIMESTAMP,
            title TEXT DEFAULT '',
            status TEXT NOT NULL DEFAULT 'processing',
            transcript TEXT DEFAULT '',
            notes TEXT DEFAULT '',
            speakers INTEGER DEFAULT 0,
            error TEXT DEFAULT '',
            asr_ms INTEGER DEFAULT 0, diar_ms INTEGER DEFAULT 0, notes_ms INTEGER DEFAULT 0,
            language TEXT DEFAULT '', diarize INTEGER DEFAULT 1, translate INTEGER DEFAULT 1)""")
        # CREATE TABLE IF NOT EXISTS does NOT add columns to a table that already
        # exists, so new columns must be migrated in explicitly. ADD COLUMN is the
        # one genuinely additive ALTER: it cannot drop or rewrite existing data.
        def _ensure_column(table: str, column: str, decl: str):
            info = con.execute(f"PRAGMA table_info({table})").fetchall()
            if not info:
                return   # table not created yet — it will be built with this column
            have = {r[1] for r in info}
            if column not in have:
                con.execute(f"ALTER TABLE {table} ADD COLUMN {column} {decl}")
                log.info("db migration: added %s.%s", table, column)

        _ensure_column("meetings", "language", "TEXT DEFAULT ''")
        _ensure_column("meetings", "diarize", "INTEGER DEFAULT 1")
        _ensure_column("meetings", "translate", "INTEGER DEFAULT 1")
        _ensure_column("voiceprints", "model", "TEXT DEFAULT ''")
        _ensure_column("voiceprints", "dims", "INTEGER DEFAULT 0")

        # A restart orphans any in-flight job. Jobs whose upload was spooled to
        # disk are RESUMABLE and must not be marked failed — _resume_spooled_jobs()
        # re-queues them at startup. Only jobs with no surviving audio are errored,
        # because for those there is genuinely nothing left to process.
        orphans = con.execute("SELECT id FROM meetings WHERE status='processing'").fetchall()
        for (oid,) in orphans:
            if not os.path.exists(_spool_path(oid)):
                con.execute("UPDATE meetings SET status='error', "
                            "error='interrupted by server restart' WHERE id=?", (oid,))
        # Per-meeting speaker vectors, keyed by the DISPLAYED label, so renaming a
        # speaker still teaches the right voice after a server restart. Additive
        # table (never an ALTER on `meetings`) so an existing store is untouched.
        con.execute("""CREATE TABLE IF NOT EXISTS meeting_embeddings (
            meeting_id INTEGER PRIMARY KEY,
            data TEXT NOT NULL DEFAULT '{}')""")
        con.execute("""CREATE TABLE IF NOT EXISTS voiceprints (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            embedding TEXT NOT NULL,
            -- Which embedding model produced this vector, and how many dims.
            -- Cosine similarity between two DIFFERENT embedding spaces is
            -- meaningless but looks like a normal score, so a pyannote upgrade
            -- would silently start matching the wrong people. Stored so stale
            -- vectors can be ignored rather than trusted.
            model TEXT DEFAULT '',
            dims INTEGER DEFAULT 0,
            meetings_seen INTEGER DEFAULT 1,
            updated_at TEXT DEFAULT CURRENT_TIMESTAMP)""")
        con.commit()
        con.close()
        log.info("capture store ready at %s", DB_PATH)
    except Exception as e:  # noqa: BLE001
        log.warning("capture store init failed: %s", e)


@app.get("/history")
async def get_history(limit: int = 25):
    try:
        con = sqlite3.connect(DB_PATH)
        con.row_factory = sqlite3.Row
        rows = con.execute(
            "SELECT id, ts, raw, corrected, polished, asr_ms, polish_ms, num_words "
            "FROM history ORDER BY id DESC LIMIT ?", (max(1, min(limit, 500)),)).fetchall()
        con.close()
        total = _history_count()
        return {"total": total, "items": [dict(r) for r in rows]}
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=str(e))


def _history_count():
    try:
        con = sqlite3.connect(DB_PATH)
        n = con.execute("SELECT COUNT(*) FROM history").fetchone()[0]
        con.close()
        return n
    except Exception:  # noqa: BLE001
        return 0


def _capture(raw, corrected, polished, asr_ms, polish_ms, audio_bytes, audio=None):
    """Persist a dictation; returns its row id (so the client can correct it)."""
    try:
        con = sqlite3.connect(DB_PATH)
        cur = con.execute(
            "INSERT INTO history (raw, corrected, polished, asr_ms, polish_ms, audio_bytes, num_words, audio) "
            "VALUES (?,?,?,?,?,?,?,?)",
            (raw, corrected, polished, asr_ms, polish_ms, audio_bytes,
             len((polished or "").split()), audio))
        row_id = cur.lastrowid
        con.commit()
        con.close()
        return row_id
    except Exception as e:  # noqa: BLE001
        log.warning("capture failed: %s", e)
        return None


@app.post("/retranscribe")
async def retranscribe(id: int):
    """Re-run ASR (+polish) on a stored dictation's retained audio — recovers a
    bad take now that the repetition-loop bug is fixed."""
    if not _WHISPER_LOCAL:
        raise HTTPException(status_code=400, detail="local whisper not available")
    con = sqlite3.connect(DB_PATH)
    row = con.execute("SELECT audio FROM history WHERE id=?", (id,)).fetchone()
    con.close()
    if not row or row[0] is None:
        raise HTTPException(status_code=404, detail="no stored audio for that id")
    raw, _nsp = await asyncio.to_thread(_transcribe_local, row[0], None)
    corrected = apply_vocab(raw)
    text = corrected
    if POLISH_ENABLED and _model is not None:
        text = await asyncio.to_thread(_polish, corrected)
    con = sqlite3.connect(DB_PATH)
    con.execute("UPDATE history SET raw=?, corrected=?, polished=?, num_words=? WHERE id=?",
                (raw, corrected, text, len(text.split()), id))
    con.commit()
    con.close()
    return {"id": id, "raw": raw, "text": text}


# ---------------------------------------------------------------------------
# Learning loop — close the raw→polished→EDITED circle. When you fix a dictation
# we store your version, diff it against what we produced, and derive candidate
# vocab fixes. Nothing is auto-applied: candidates surface as suggestions you
# approve (promote into live vocab) or dismiss. A deterministic history scan
# adds candidates for names you keep using that aren't in your vocab yet.
# ---------------------------------------------------------------------------
_WORD_RE = re.compile(r"[A-Za-z0-9']+")


def _is_termish(tok: str) -> bool:
    """A proper-noun-ish token worth learning as a term (a name, a product code,
    an acronym)."""
    if len(tok) < 2:
        return False
    if "'" in tok:
        return False                             # contractions ("I'm", "it's")
    if not any(c.isalpha() for c in tok):
        return False                             # pure numbers ("10", "45")
    return tok[0].isupper() or any(c.isdigit() for c in tok) or not tok.islower()


def _derive_candidates(produced: str, edited: str):
    """Diff what we produced vs the user's fix. Returns (replacements, terms).

    replacements: [(heard_lower, want)] — single-word substitutions, high signal
    for a mis-heard name/word (e.g. a name Whisper spelled wrong). Applied
    case-insensitively to the raw ASR, so we key on the lowercased 'heard' form.
    terms: [want] — proper-noun-ish tokens present in the fix but not the output,
    fed to Whisper so it spells them right next time.
    """
    prod_tokens = _WORD_RE.findall(produced or "")
    edit_tokens = _WORD_RE.findall(edited or "")
    reps, terms = [], []
    sm = difflib.SequenceMatcher(a=prod_tokens, b=edit_tokens, autojunk=False)
    for op, i1, i2, j1, j2 in sm.get_opcodes():
        if op == "replace":
            # 1-for-1 word swap → a correction (mishearing). Multi-word swaps are
            # too noisy to auto-derive; skip them (still captured in `edited`).
            if i2 - i1 == 1 and j2 - j1 == 1:
                heard, want = prod_tokens[i1], edit_tokens[j1]
                # Pure case changes ("we"->"We") are the polisher's job, not a
                # learned fix — skip both paths so common words don't pollute
                # suggestions. Real mis-hearings (a mis-spelled name) still flow
                # through, and the history scan backstops names we lowercased.
                if heard.lower() != want.lower() and len(want) >= 2:
                    reps.append((heard.lower(), want))
                    if _is_termish(want):
                        terms.append(want)
        elif op == "insert":
            for tok in edit_tokens[j1:j2]:
                if _is_termish(tok):
                    terms.append(tok)
    # de-dupe, drop terms already implied by a replacement target
    rep_targets = {w for _, w in reps}
    terms = [t for t in dict.fromkeys(terms) if t not in rep_targets]
    return reps, terms


def _add_candidate(kind, frm, to, source="edit", inc=True):
    """Upsert a learning candidate. edit-derived bumps the count each time it
    recurs; scan-derived seeds once (INSERT OR IGNORE) so counts stay meaningful.
    Never resurrects a dismissed candidate."""
    con = sqlite3.connect(DB_PATH)
    try:
        if inc:
            con.execute(
                "INSERT INTO suggestions (kind, frm, to_, count, source) VALUES (?,?,?,1,?) "
                "ON CONFLICT(kind, frm, to_) DO UPDATE SET count = count + 1 "
                "WHERE suggestions.status != 'dismissed'",
                (kind, frm, to, source))
        else:
            con.execute(
                "INSERT OR IGNORE INTO suggestions (kind, frm, to_, count, source) VALUES (?,?,?,1,?)",
                (kind, frm, to, source))
        con.commit()
    finally:
        con.close()


_SENT_START = set(".!?:;\n")


def _strong_term(tok: str) -> bool:
    """Unambiguously a name/identifier regardless of position: has a digit,
    or a non-titlecase shape (an ALLCAPS acronym, CamelCase, iPhone). Plain
    Titlecase words ('Meeting', a person's name) are ambiguous — handled by
    position."""
    if any(c.isdigit() for c in tok):
        return True
    return not (tok[0].isupper() and tok[1:].islower())


def _scan_history_for_terms(min_count=3, limit_rows=500):
    """Deterministic: proper-noun-ish tokens used repeatedly across dictations
    that aren't in vocab yet → term candidates. No model, no network.

    To avoid proposing common words that are merely capitalized at the start of
    a sentence ('Meeting', 'Then'), a plain Titlecase word only counts when it
    appears MID-sentence — where capitalization signals a proper noun. Tokens
    with digits or unusual case (product codes, acronyms, CamelCase) always
    count."""
    known = {t.lower() for t in _vocab.get("terms", [])}
    known |= {v.lower() for v in _vocab.get("replacements", {}).values()}
    counts = {}
    con = sqlite3.connect(DB_PATH)
    try:
        # Scan candidates are fully regenerable, so clear the pending ones first:
        # the list always reflects the current heuristics (stale noise clears),
        # while dismissed/promoted rows survive and won't resurface.
        con.execute("DELETE FROM suggestions WHERE source='scan' AND status='pending'")
        rows = con.execute(
            "SELECT COALESCE(edited, polished, corrected, raw) FROM history "
            "ORDER BY id DESC LIMIT ?", (limit_rows,)).fetchall()
        for (text,) in rows:
            if not text:
                continue
            for mt in _WORD_RE.finditer(text):
                tok = mt.group(0)
                if not _is_termish(tok) or tok.lower() in known:
                    continue
                if not _strong_term(tok):
                    # Plain Titlecase: skip sentence-initial occurrences.
                    j = mt.start() - 1
                    while j >= 0 and text[j] == " ":
                        j -= 1
                    if j < 0 or text[j] in _SENT_START:
                        continue
                counts[tok] = counts.get(tok, 0) + 1
        for tok, n in counts.items():
            if n < min_count:
                continue
            # Seed once (don't resurface a dismissed one); refresh the observed
            # frequency for still-pending scan candidates.
            con.execute(
                "INSERT OR IGNORE INTO suggestions (kind, frm, to_, count, source) "
                "VALUES ('term','',?,?, 'scan')", (tok, n))
            con.execute(
                "UPDATE suggestions SET count=? WHERE kind='term' AND frm='' AND to_=? "
                "AND source='scan' AND status='pending'", (n, tok))
        con.commit()
    finally:
        con.close()


@app.post("/correct")
async def correct(payload: dict, authorization: str | None = Header(None)):
    """Record the user's fix for a dictation and derive learning candidates.
    Body: {"id": <history id>, "edited": "<corrected text>"}."""
    _check_auth(authorization)
    hid = payload.get("id")
    edited = (payload.get("edited") or "").strip()
    if not edited:
        raise HTTPException(status_code=400, detail="empty 'edited' text")
    con = sqlite3.connect(DB_PATH)
    con.row_factory = sqlite3.Row
    row = con.execute("SELECT polished, corrected, raw FROM history WHERE id=?",
                      (hid,)).fetchone() if hid is not None else None
    if row is None:
        con.close()
        raise HTTPException(status_code=404, detail="no dictation with that id")
    con.execute("UPDATE history SET edited=? WHERE id=?", (edited, hid))
    con.commit()
    con.close()
    produced = row["polished"] or row["corrected"] or row["raw"] or ""
    reps, terms = _derive_candidates(produced, edited)
    for heard, want in reps:
        _add_candidate("replacement", heard, want, source="edit")
    for term in terms:
        _add_candidate("term", "", term, source="edit")
    log.info("correct id=%s: +%d replacement, +%d term candidates", hid, len(reps), len(terms))
    return {"id": hid, "derived": {"replacements": reps, "terms": terms}}


@app.get("/suggestions")
async def get_suggestions(limit: int = 50, scan: bool = True):
    """Pending learning candidates, most-corrected first. `scan` also refreshes
    deterministic term candidates from history (cheap; idempotent)."""
    if scan:
        try:
            _scan_history_for_terms()
        except Exception as e:  # noqa: BLE001
            log.warning("history scan failed: %s", e)
    con = sqlite3.connect(DB_PATH)
    con.row_factory = sqlite3.Row
    rows = con.execute(
        "SELECT id, kind, frm, to_ AS to_val, count, source, ts FROM suggestions "
        "WHERE status='pending' ORDER BY count DESC, id DESC LIMIT ?",
        (max(1, min(limit, 200)),)).fetchall()
    con.close()
    return {"items": [dict(r) for r in rows]}


@app.post("/suggestions/promote")
async def promote_suggestion(payload: dict, authorization: str | None = Header(None)):
    """Approve a candidate → merge into live vocab and mark it promoted."""
    _check_auth(authorization)
    sid = payload.get("id")
    con = sqlite3.connect(DB_PATH)
    con.row_factory = sqlite3.Row
    row = con.execute("SELECT * FROM suggestions WHERE id=?", (sid,)).fetchone()
    if row is None:
        con.close()
        raise HTTPException(status_code=404, detail="no suggestion with that id")
    if row["kind"] == "replacement":
        _vocab["replacements"][row["frm"]] = row["to_"]
    elif row["kind"] == "term":
        if row["to_"] not in _vocab["terms"]:
            _vocab["terms"].append(row["to_"])
    _save_vocab()
    con.execute("UPDATE suggestions SET status='promoted' WHERE id=?", (sid,))
    con.commit()
    con.close()
    log.info("promoted suggestion %s (%s)", sid, row["kind"])
    return {"id": sid, "vocab": _vocab}


@app.post("/suggestions/dismiss")
async def dismiss_suggestion(payload: dict, authorization: str | None = Header(None)):
    """Reject a candidate so it never resurfaces."""
    _check_auth(authorization)
    sid = payload.get("id")
    con = sqlite3.connect(DB_PATH)
    cur = con.execute("UPDATE suggestions SET status='dismissed' WHERE id=?", (sid,))
    con.commit()
    changed = cur.rowcount
    con.close()
    if not changed:
        raise HTTPException(status_code=404, detail="no suggestion with that id")
    return {"id": sid, "status": "dismissed"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=PORT)
