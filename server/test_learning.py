"""Regression tests for the learning loop (correct → derive → suggest →
promote/dismiss) and the deterministic history scan.

Runs WITHOUT the MLX model: it stubs mlx_lm and drives the real FastAPI routes
with a temp DB/vocab, so it's safe to run anywhere.

    python3 -m venv /tmp/vf_test && /tmp/vf_test/bin/pip install \
        fastapi httpx requests python-multipart
    /tmp/vf_test/bin/python server/test_learning.py
"""
import sys
import os
import types
import tempfile
import importlib.util


def _load_server():
    mlx_lm = types.ModuleType("mlx_lm")
    mlx_lm.load = lambda *a, **k: (object(), object())
    mlx_lm.generate = lambda *a, **k: "polished"
    sys.modules["mlx_lm"] = mlx_lm

    db = tempfile.mktemp(suffix=".sqlite")
    vocab = tempfile.mktemp(suffix=".json")
    open(vocab, "w").write('{"replacements":{},"terms":[],"snippets":{}}')
    os.environ["VF_DB_PATH"] = db
    os.environ["VF_VOCAB_PATH"] = vocab

    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location(
        "vfsrv", os.path.join(here, "server.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    m._load_vocab()
    m._init_db()
    return m, db, vocab


def main():
    m, db, vocab = _load_server()
    from fastapi.testclient import TestClient
    c = TestClient(m.app)

    # Seed a dictation, then teach a name fix.
    hid = m._capture("i called aleks about the erp42 issue",
                     "I called Aleks about the ERP42 issue.",
                     "I called Aleks about the ERP42 issue.", 100, 50, 1000)
    r = c.post("/correct", json={"id": hid, "edited": "I called Alex about the ERP42 issue."})
    assert r.status_code == 200, r.text
    assert ["aleks", "Alex"] in r.json()["derived"]["replacements"]

    # Candidate surfaces, then promotes into vocab.
    sug = c.get("/suggestions").json()["items"]
    rep = next(s for s in sug if s["frm"] == "aleks" and s["to_val"] == "Alex")
    assert c.post("/suggestions/promote", json={"id": rep["id"]}).json()[
        "vocab"]["replacements"].get("aleks") == "Alex"
    assert not any(s["id"] == rep["id"] for s in c.get("/suggestions").json()["items"])

    # Bad ids 404.
    assert c.post("/suggestions/dismiss", json={"id": 999999}).status_code == 404
    assert c.post("/correct", json={"id": 999999, "edited": "x"}).status_code == 404

    # History scan: repeated MID-sentence proper noun surfaces; a sentence-initial
    # common word must NOT.
    for _ in range(3):
        m._capture("meeting with kavya", "Meeting with Kavya.", "Meeting with Kavya.", 10, 10, 100)
    terms = [s["to_val"] for s in c.get("/suggestions").json()["items"] if s["kind"] == "term"]
    assert "Kavya" in terms, terms
    assert "Meeting" not in terms, terms

    # Noise exclusions on real-world-ish text: pure numbers and contractions.
    assert not m._is_termish("10") and not m._is_termish("45"), "pure numbers are not terms"
    assert not m._is_termish("I'm") and not m._is_termish("it's"), "contractions are not terms"
    assert m._is_termish("ERP42") and m._is_termish("ExampleProject"), "letter+digit codes ARE terms"
    for _ in range(5):
        m._capture("i think 10 is fine", "I think 10 is fine.", "I think 10 is fine.", 1, 1, 1)
        m._capture("i'm on it", "I'm on it.", "I'm on it.", 1, 1, 1)
    terms = [s["to_val"] for s in c.get("/suggestions").json()["items"] if s["kind"] == "term"]
    assert "10" not in terms and "I'm" not in terms, terms

    # Polish safety net: a failed polish (regurgitation / fabrication /
    # summarization / replying to the speaker) must be detected so the user's
    # words are kept instead.
    bad = m._polish_failed
    assert bad("I think it's only showing the latest one.",
               "I think we need to check the database to see if it's been updated "
               "recently. Then we can verify the issue."), "fabrication (expansion)"
    assert bad("I think it's only showing the latest one.",
               "First of all, thank you so much for the help today. It really made "
               "a big difference."), "regurgitated example"
    assert bad("Give me the template with placeholders.",
               "1. {{first step}}\n2. {{second step}}\n3. {{third step}}"), "list hallucination"
    # The id=475 failure: first-person request answered in second person.
    assert bad("so basically i am thinking of updating my home mac and i have "
               "already ordered one but i worry i would lose my things",
               "So you're looking to update your home Mac. You've already ordered "
               "one, but you're worried you'll lose your data."), "replied to speaker (I->you)"
    assert not bad("Make sure this complies with the German laws and our German entities.",
                   "Make sure this complies with the German laws and our German entities."), "faithful"
    assert bad("also make a message draft a message for the doctor to submit it to her",
                   "Draft a message for the doctor to submit to her."), "ambiguous phrasing deletion conservatively retains original"
    # Ambiguous filler edits retain the original; an unchanged question still passes.
    assert bad("can you like send me the the report when you get a chance you know",
                   "Can you send me the report when you get a chance?"), "ambiguous like deletion conservatively retains original"
    assert not bad("Can you send me the report?", "Can you send me the report?")
    assert not bad("hey", "Hey."), "too short to judge"

    # Prompt mode: guard returns 503 when the model isn't loaded (as in this test).
    assert m._model is None
    r = c.post("/engineer", files={"file": ("a.wav", b"RIFF0000WAVE")})
    assert r.status_code == 503, (r.status_code, r.text)

    # _engineer plumbing: builds the request and strips the <<<REQUEST>>> markers
    # the model may echo. Stub the LLM so this runs without mlx.
    class _TokStub:
        def apply_chat_template(self, msgs, add_generation_prompt=True):
            return "PROMPT"
    m._model = object()
    m._tok = _TokStub()
    m.generate = lambda *a, **k: "<<<REQUEST>>>\nBuild a login page.\n<<<END>>>"
    assert m._engineer("build me a login page", "concise") == "Build a login page.", "marker stripping"

    os.unlink(db)
    os.unlink(vocab)
    print("ALL LEARNING TESTS PASSED")


if __name__ == "__main__":
    main()
