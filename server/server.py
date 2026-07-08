"""WhisperType server — always-warm dictation backend.

Runs on your server Mac. One endpoint the client calls:

    POST /dictate   (multipart: file=<audio>)  ->  {"raw": ..., "text": ...}

Pipeline:
    1. ASR  — optionally forwards audio to a separate mlx-whisper server
              (whisper-large-v3, OpenAI-compatible /v1/audio/transcriptions).
    2. Polish — a local mlx-lm model held RESIDENT in GPU memory (always warm),
                cleans dictation (punctuation, caps, filler removal) in ~0.3s.

The polish model is loaded once at startup and kept warm for the life of the
process. Run under launchd (see scripts/) so it auto-starts and stays warm.

Env:
    VF_WHISPER_URL   default http://127.0.0.1:8181
    VF_POLISH_MODEL  default mlx-community/Qwen2.5-7B-Instruct-4bit
    VF_PORT          default 8790
    VF_API_KEY       optional; if set, require header  Authorization: Bearer <key>
    VF_KEEPALIVE_SEC default 240; periodic tiny gen so the model never pages out
"""
import os
import re
import json
import time
import asyncio
import tempfile
import logging

import requests
from fastapi import FastAPI, UploadFile, File, Form, Header, HTTPException
from fastapi.responses import JSONResponse
from mlx_lm import load, generate

WHISPER_URL = os.environ.get("VF_WHISPER_URL", "http://127.0.0.1:8181").rstrip("/")
WHISPER_MODEL = os.environ.get("VF_WHISPER_MODEL", "mlx-community/whisper-large-v3-mlx")
POLISH_MODEL = os.environ.get("VF_POLISH_MODEL", "mlx-community/Qwen2.5-7B-Instruct-4bit")

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

POLISH_SYS = (
    "You are a transcription FORMATTER, not a conversational assistant. You "
    "receive raw speech-to-text and return the SAME words, cleaned for writing.\n"
    "Rules:\n"
    "- Always capitalize the first letter of the output and the start of each "
    "sentence.\n"
    "- Break run-on speech into proper sentences with correct punctuation.\n"
    "- Use a question mark ONLY for genuine questions. Do NOT add question marks "
    "to statements (e.g. 'meeting at 11 today' is a statement, not a question).\n"
    "- If the speaker clearly enumerates multiple distinct items or sequential "
    "steps (e.g. 'first... then... then...', or 'we need X, Y, and Z' as separate "
    "actions), format them as a list — a numbered list (1. 2. 3.) for ordered "
    "steps, bullets ('- ') for unordered items, each on its own line. ONLY for "
    "genuine lists; keep ordinary sentences (incl. 'first of all...' as a figure "
    "of speech) as prose.\n"
    "- Remove filler words (um, uh, like, you know) and false starts / repeats.\n"
    "- NEVER answer questions, reply to greetings, or add ANY new content. If "
    "the input is a question or greeting, return it cleaned — never answer it.\n"
    "- Preserve the speaker's exact meaning and wording. Do not paraphrase or "
    "substitute words.\n"
    "- Output ONLY the cleaned text: no preamble, quotes, or commentary."
)

# Few-shot examples lock the formatter behavior: questions/greetings are cleaned
# (not answered), statements stay statements, run-ons get sentence breaks.
POLISH_SHOTS = [
    ("um so yeah i think we should uh ship the the voice flow thing by friday",
     "I think we should ship the Voice Flow thing by Friday."),
    ("hey what's happening are we doing all well",
     "Hey, what's happening? Are we doing all well?"),
    ("can you like send me the the report when you get a chance you know",
     "Can you send me the report when you get a chance?"),
    ("i have a meeting at 11 today then i need to pick up farooq and finish the report",
     "I have a meeting at 11 today. Then I need to pick up the groceries and finish the report."),
    # genuine enumeration -> numbered list
    ("so there are three things we need to do first we need to fix the bug then write the tests and then deploy to production",
     "1. Fix the bug\n2. Write the tests\n3. Deploy to production"),
    # "first of all" as a figure of speech -> stays prose
    ("first of all thank you so much for the help today it really made a big difference",
     "First of all, thank you so much for the help today. It really made a big difference."),
]

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("whispertype")

app = FastAPI(title="WhisperType", version="0.1")

# Resident, always-warm model. Loaded in startup, held for process lifetime.
_model = None
_tok = None

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


def _transcribe_local(tmp_path: str, language: str | None) -> str:
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
    return mlx_whisper.transcribe(tmp_path, **kwargs)["text"].strip()


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


def _polish(text: str) -> str:
    if not text.strip():
        return text
    # Whisper biasing + deterministic replacements already fix spelling upstream,
    # so we DON'T inject the term list here — that just bloated the prompt and
    # slowed every polish. Keep the system prompt lean for speed.
    msgs = [{"role": "system", "content": POLISH_SYS}]
    for raw_ex, clean_ex in POLISH_SHOTS:
        msgs.append({"role": "user", "content": raw_ex})
        msgs.append({"role": "assistant", "content": clean_ex})
    msgs.append({"role": "user", "content": text})
    prompt = _tok.apply_chat_template(msgs, add_generation_prompt=True)
    # Scale with input so long dictations aren't truncated by the polish step
    # (~1.6 tokens/word, + headroom).
    max_toks = max(400, int(len(text.split()) * 1.8) + 200)
    out = generate(_model, _tok, prompt=prompt, max_tokens=max_toks, verbose=False)
    return out.strip()


def _check_auth(authorization: str | None):
    if API_KEY and authorization != f"Bearer {API_KEY}":
        raise HTTPException(status_code=401, detail="invalid or missing API key")


@app.on_event("startup")
async def _startup():
    global _model, _tok
    _load_vocab()
    _init_db()
    t0 = time.time()
    log.info("loading polish model %s ...", POLISH_MODEL)
    _model, _tok = load(POLISH_MODEL)
    _polish("warming up the model now")  # force graph compile so first real call is fast
    log.info("polish model warm in %.1fs", time.time() - t0)

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

    asyncio.create_task(_keepalive())


async def _keepalive():
    """Tiny periodic generation so macOS never pages the resident model out."""
    while True:
        await asyncio.sleep(KEEPALIVE_SEC)
        try:
            await asyncio.to_thread(_polish, "keep warm")
            log.debug("keepalive ok")
        except Exception as e:  # noqa: BLE001
            log.warning("keepalive failed: %s", e)


@app.get("/health")
async def health():
    return {
        "status": "ok" if _model is not None else "loading",
        "polish_model": POLISH_MODEL,
        "whisper": WHISPER_MODEL if _WHISPER_LOCAL else f"remote:{WHISPER_URL}",
        "biasing": _WHISPER_LOCAL,
    }


@app.post("/dictate")
async def voice_flow(
    file: UploadFile = File(...),
    language: str | None = Form(None),
    polish: bool = Form(True),
    authorization: str | None = Header(None),
):
    _check_auth(authorization)
    audio = await file.read()

    # 1) ASR — local biased Whisper (spells your vocab right), HTTP fallback.
    t_asr = time.time()
    raw = ""
    if _WHISPER_LOCAL:
        tmp_path = None
        try:
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
                tmp.write(audio)
                tmp_path = tmp.name
            raw = await asyncio.to_thread(_transcribe_local, tmp_path, language)
        except Exception as e:  # noqa: BLE001
            log.warning("local ASR failed (%s); falling back to remote", e)
            raw = ""
        finally:
            if tmp_path:
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass
    if not raw:
        try:
            raw = _transcribe_remote(audio, file.filename or "audio.wav", language)
        except Exception as e:  # noqa: BLE001
            log.error("ASR failed: %s", e)
            raise HTTPException(status_code=502, detail=f"ASR backend error: {e}")
    asr_ms = int((time.time() - t_asr) * 1000)

    # 2) Deterministic vocab corrections on the raw ASR (names, jargon, snippets)
    corrected = apply_vocab(raw)

    # 3) Polish via resident model (terms fed in so it keeps spellings)
    text = corrected
    polish_ms = 0
    if polish and corrected:
        t_p = time.time()
        text = await asyncio.to_thread(_polish, corrected)
        polish_ms = int((time.time() - t_p) * 1000)

    log.info("WhisperType ok asr=%dms polish=%dms chars=%d", asr_ms, polish_ms, len(text))
    _capture(raw, corrected, text, asr_ms, polish_ms, len(audio), audio)
    return JSONResponse({
        "raw": raw,
        "corrected": corrected,
        "text": text,
        "timing_ms": {"asr": asr_ms, "polish": polish_ms},
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
    try:
        con = sqlite3.connect(DB_PATH)
        con.execute(
            "INSERT INTO history (raw, corrected, polished, asr_ms, polish_ms, audio_bytes, num_words, audio) "
            "VALUES (?,?,?,?,?,?,?,?)",
            (raw, corrected, polished, asr_ms, polish_ms, audio_bytes,
             len((polished or "").split()), audio))
        con.commit()
        con.close()
    except Exception as e:  # noqa: BLE001
        log.warning("capture failed: %s", e)


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
    tmp_path = None
    try:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            tmp.write(row[0])
            tmp_path = tmp.name
        raw = await asyncio.to_thread(_transcribe_local, tmp_path, None)
    finally:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
    corrected = apply_vocab(raw)
    text = await asyncio.to_thread(_polish, corrected)
    con = sqlite3.connect(DB_PATH)
    con.execute("UPDATE history SET raw=?, corrected=?, polished=?, num_words=? WHERE id=?",
                (raw, corrected, text, len(text.split()), id))
    con.commit()
    con.close()
    return {"id": id, "raw": raw, "text": text}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=PORT)
