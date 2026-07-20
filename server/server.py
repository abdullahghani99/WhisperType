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


def _transcribe_local(audio: bytes, language: str | None) -> str:
    """Transcribe WAV bytes with local mlx-whisper. Feeds a decoded float32
    array (not a file path) so ASR never shells out to ffmpeg."""
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
    return mlx_whisper.transcribe(audio_arr, **kwargs)["text"].strip()


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
    # Use the STRONGER prompt model (14B) for polish — it follows the formatting
    # rules (paragraphs + lists) reliably, whereas the fast 8B duplicated and
    # summarized lists. Falls back to the 8B if the 14B isn't loaded. (The
    # distillation model will later give this quality at 8B speed.)
    model = _prompt_model if _prompt_model is not None else _model
    tok = _prompt_tok if _prompt_model is not None else _tok
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


def _check_auth(authorization: str | None):
    if API_KEY and authorization != f"Bearer {API_KEY}":
        raise HTTPException(status_code=401, detail="invalid or missing API key")


@app.on_event("startup")
async def _startup():
    global _model, _tok
    _load_vocab()
    _init_db()
    if POLISH_ENABLED:
        t0 = time.time()
        log.info("loading polish model %s ...", POLISH_MODEL)
        _model, _tok = load(POLISH_MODEL)
        _polish("warming up the model now")  # force graph compile so first real call is fast
        log.info("polish model warm in %.1fs", time.time() - t0)
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
    raw = ""
    if _WHISPER_LOCAL:
        try:
            raw = await asyncio.to_thread(_transcribe_local, audio, language)
        except Exception as e:  # noqa: BLE001
            log.warning("local ASR failed (%s); falling back to remote", e)
            raw = ""
    if not raw:
        try:
            raw = _transcribe_remote(audio, filename or "audio.wav", language)
        except Exception as e:  # noqa: BLE001
            log.error("ASR failed: %s", e)
            raise HTTPException(status_code=502, detail=f"ASR backend error: {e}")
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
    raw = await asyncio.to_thread(_transcribe_local, row[0], None)
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
