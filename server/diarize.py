#!/usr/bin/env python3
"""Speaker diarization helper — runs in an ISOLATED venv (~/pyannote-venv) so its
heavy torch deps never touch the live server's environment. The /meeting endpoint
calls this as a subprocess.

Input:  a 16 kHz mono WAV path (argv[1]).
Output: JSON to stdout: {"turns": [{"start": s, "end": s, "speaker": "SPEAKER_00"}, ...]}
        On any failure, prints {"turns": [], "error": "..."} and exits 0 so the
        caller can gracefully fall back to an unlabeled transcript.

Everything runs locally on ms2; audio never leaves the machine. The pyannote
pipeline model is gated but free — downloaded once with the existing HF token,
then cached offline.
"""
import sys
import json

MODEL = "pyannote/speaker-diarization-3.1"


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"turns": [], "error": "no wav path"})); return
    wav = sys.argv[1]
    try:
        import os
        import torch
        from pyannote.audio import Pipeline
        # pyannote 4.x wants the HF token passed explicitly. Read it from env or
        # the standard cached location. This is the local open pipeline — NOT the
        # paid pyannoteAI cloud SDK; audio never leaves the machine.
        token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_TOKEN")
        if not token:
            tok_path = os.path.expanduser("~/.cache/huggingface/token")
            if os.path.exists(tok_path):
                token = open(tok_path).read().strip()
        pipe = Pipeline.from_pretrained(MODEL, token=token)
        if pipe is None:
            raise RuntimeError("pipeline is None (model access not granted for the HF token?)")
        # Apple Silicon: prefer MPS, else CPU.
        try:
            if torch.backends.mps.is_available():
                pipe.to(torch.device("mps"))
        except Exception:  # noqa: BLE001
            pass
        diar = pipe(wav)
        turns = [{"start": round(seg.start, 2), "end": round(seg.end, 2), "speaker": spk}
                 for seg, _, spk in diar.itertracks(yield_label=True)]
        print(json.dumps({"turns": turns}))
    except Exception as e:  # noqa: BLE001
        print(json.dumps({"turns": [], "error": str(e)}))


if __name__ == "__main__":
    main()
