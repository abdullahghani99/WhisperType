"""Voiceprint matching tests. Run:
    python3 server/test_speakers.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ.setdefault("VF_POLISH_ENABLED", "0")
os.environ.setdefault("VF_PROMPT_ENABLED", "0")

import server as m  # noqa: E402


def test_cosine():
    assert abs(m._cosine([1, 0, 0], [1, 0, 0]) - 1.0) < 1e-6
    assert abs(m._cosine([1, 0, 0], [0, 1, 0])) < 1e-6
    assert abs(m._cosine([1, 0], [2, 0]) - 1.0) < 1e-6, "magnitude must not matter"
    assert m._cosine([], [1]) == 0.0, "mismatched/empty vectors are 0, never an error"


def test_merge_oversplit_collapses_the_same_voice():
    # Speakers 0 and 2 are the same person; 1 is someone else.
    embeddings = {
        "SPEAKER_00": [1.0, 0.0, 0.0],
        "SPEAKER_01": [0.0, 1.0, 0.0],
        "SPEAKER_02": [0.99, 0.01, 0.0],
    }
    turns = [{"start": 0, "end": 1, "speaker": "SPEAKER_00"},
             {"start": 1, "end": 2, "speaker": "SPEAKER_01"},
             {"start": 2, "end": 3, "speaker": "SPEAKER_02"}]
    mapping = m._merge_oversplit(turns, embeddings, threshold=0.75)
    assert mapping["SPEAKER_02"] == "SPEAKER_00", mapping
    assert mapping["SPEAKER_01"] == "SPEAKER_01", mapping


def test_merge_is_noop_without_embeddings():
    turns = [{"start": 0, "end": 1, "speaker": "SPEAKER_00"}]
    assert m._merge_oversplit(turns, {}, threshold=0.75) == {"SPEAKER_00": "SPEAKER_00"}


def test_merge_keeps_the_dominant_speakers_own_embedding():
    # SPEAKER_02 is a fragment of SPEAKER_00. The SURVIVING label must keep its
    # OWN vector; rebuilding the dict by rewriting keys let the discarded
    # fragment overwrite the dominant speaker's voice.
    embeddings = {
        "SPEAKER_00": [1.0, 0.0, 0.0],
        "SPEAKER_01": [0.0, 1.0, 0.0],
        "SPEAKER_02": [0.99, 0.01, 0.0],
    }
    turns = [{"start": 0, "end": 1, "speaker": "SPEAKER_00"},
             {"start": 1, "end": 2, "speaker": "SPEAKER_01"},
             {"start": 2, "end": 3, "speaker": "SPEAKER_02"}]
    merge = m._merge_oversplit(turns, embeddings, threshold=0.75)
    kept = {c: embeddings[c] for c in dict.fromkeys(merge.values()) if c in embeddings}
    assert kept["SPEAKER_00"] == [1.0, 0.0, 0.0], kept
    assert "SPEAKER_02" not in kept, kept


def test_displayed_label_owns_the_voiceprint(tmp_db):
    """The bug this guards: 'Speaker N' used to be enumerated three separate
    times over three collections that disagree, so renaming a speaker stored a
    DIFFERENT person's 256-d vector into the durable voiceprints table."""
    # SPEAKER_00 speaks late and is never captured by a Whisper segment, so it is
    # ABSENT from what the human sees. The turns list and the embeddings dict
    # both put it first, which is exactly how the wrong vector got picked.
    turns = [{"start": 5.0, "end": 6.0, "speaker": "SPEAKER_00"},
             {"start": 0.0, "end": 1.0, "speaker": "SPEAKER_01"},
             {"start": 1.0, "end": 2.0, "speaker": "SPEAKER_02"}]
    # 4-d on purpose: _cosine scores mismatched lengths 0.0, so these vectors
    # cannot collide with the 3-d ones the other tests put in the same store.
    embeddings = {
        "SPEAKER_00": [1.0, 0.0, 0.0, 0.0],   # never displayed
        "SPEAKER_01": [0.0, 1.0, 0.0, 0.0],   # displayed as "Speaker 1"
        "SPEAKER_02": [0.0, 0.0, 1.0, 0.0],   # displayed as "Speaker 2"
    }
    segments = [(0.0, 1.0, "morning all"), (1.0, 2.0, "morning")]
    labeled, order = m._label_transcript(segments, turns)

    assert order == {"SPEAKER_01": "Speaker 1", "SPEAKER_02": "Speaker 2"}, order
    assert "SPEAKER_00" not in order, "a label with no visible line must not be numbered"
    assert labeled.startswith("**Speaker 1:**"), labeled

    disp = m._display_embeddings(order, embeddings)
    assert disp["Speaker 1"] == [0.0, 1.0, 0.0, 0.0], disp
    assert disp["Speaker 2"] == [0.0, 0.0, 1.0, 0.0], disp
    assert [1.0, 0.0, 0.0, 0.0] not in disp.values(), "an unseen voice must never be stored"

    # End to end: renaming what the human sees as "Speaker 1" must persist
    # SPEAKER_01's voice, and that voice alone must match next time.
    m._store_voiceprint("Alex", disp.get("Speaker 1"))
    assert m._match_voiceprints({"X": [0.01, 0.99, 0.0, 0.0]}).get("X") == "Alex"
    assert m._match_voiceprints({"X": [1.0, 0.0, 0.0, 0.0]}) == {}, \
        "the undisplayed speaker's voice must NOT have been stored as Alex"


def test_label_transcript_is_empty_without_segments():
    assert m._label_transcript([], [{"start": 0, "end": 1, "speaker": "SPEAKER_00"}]) == ("", {})


def test_notes_rename_is_word_anchored():
    # The exact durable-data corruption: "Al" -> "Alex" must not touch "Alan".
    assert m._rename_in_notes("- Al: ship it\n- Alan: review", "Al", "Alex") == \
        "- Alex: ship it\n- Alan: review"
    # Punctuation and line ends are word boundaries, so real mentions still move.
    assert m._rename_in_notes("Ask Al. (Al), Al", "Al", "Alex") == "Ask Alex. (Alex), Alex"
    assert m._rename_in_notes("", "Al", "Alex") == ""


def test_meeting_embeddings_survive_a_restart(tmp_db):
    # RAM-only meant renaming a speaker on an older meeting silently stored
    # NOTHING while the dialog promised the voice would be remembered.
    m._save_meeting_embeddings(4242, {"Speaker 1": [0.0, 1.0, 0.0]})
    m._meeting_embeddings.clear()               # simulate a server restart
    assert m._load_meeting_embeddings(4242) == {"Speaker 1": [0.0, 1.0, 0.0]}
    # Deleting a meeting must not leave biometric vectors behind.
    m._forget_meeting_embeddings(4242)
    assert m._load_meeting_embeddings(4242) == {}


def test_store_then_match_roundtrip(tmp_db):
    m._store_voiceprint("Alex", [0.0, 1.0, 0.0])
    matched = m._match_voiceprints({"SPEAKER_00": [0.01, 0.99, 0.0]})
    assert matched.get("SPEAKER_00") == "Alex", matched
    # A clearly different voice must not be claimed.
    assert m._match_voiceprints({"SPEAKER_00": [1.0, 0.0, 0.0]}) == {}


def test_merge_threshold_is_stricter_than_cross_meeting_identity():
    # Same recording, same mic → must clear a higher bar than a match months
    # apart on a different device. A false merge is silent and irreversible.
    assert m.MERGE_THRESHOLD > m.VOICEPRINT_THRESHOLD


if __name__ == "__main__":
    import tempfile
    m.DB_PATH = os.path.join(tempfile.mkdtemp(), "test.sqlite")
    m._init_db()
    test_cosine()
    test_merge_oversplit_collapses_the_same_voice()
    test_merge_is_noop_without_embeddings()
    test_merge_keeps_the_dominant_speakers_own_embedding()
    test_label_transcript_is_empty_without_segments()
    test_notes_rename_is_word_anchored()
    test_merge_threshold_is_stricter_than_cross_meeting_identity()
    test_meeting_embeddings_survive_a_restart(None)
    test_displayed_label_owns_the_voiceprint(None)
    test_store_then_match_roundtrip(None)
    print("all speaker tests passed")
