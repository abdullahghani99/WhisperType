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
            # mode-600 sidecar next to this script (off-git), then the HF cache.
            for p in (os.path.join(os.path.dirname(__file__), ".hf_token"),
                      os.path.expanduser("~/.cache/huggingface/token")):
                if os.path.exists(p):
                    token = open(p).read().strip()
                    if token:
                        break
        pipe = Pipeline.from_pretrained(MODEL, token=token)
        if pipe is None:
            raise RuntimeError("pipeline is None (model access not granted for the HF token?)")
        # Apple Silicon: prefer MPS, else CPU.
        try:
            if torch.backends.mps.is_available():
                pipe.to(torch.device("mps"))
        except Exception:  # noqa: BLE001
            pass
        # Decode the WAV ourselves and pass a waveform tensor — avoids pyannote
        # 4.x's torchcodec/ffmpeg dependency (ms2 is deliberately ffmpeg-free).
        import io, wave
        import numpy as np
        with wave.open(wav, "rb") as w:
            sr, ch, sw = w.getframerate(), w.getnchannels(), w.getsampwidth()
            frames = w.readframes(w.getnframes())
        arr = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
        if ch > 1:
            arr = arr.reshape(-1, ch).mean(axis=1)
        wf = torch.from_numpy(arr).unsqueeze(0)  # (channel=1, time)
        # Ask for embeddings so the caller can recognise known voices across
        # meetings. Not every pyannote build supports this, so fall back to a
        # plain diarization rather than failing the whole meeting.
        embeddings = {}
        try:
            out = pipe({"waveform": wf, "sample_rate": sr}, return_embeddings=True)
        except TypeError:
            out = pipe({"waveform": wf, "sample_rate": sr})

        emb_matrix = None
        if isinstance(out, tuple) and len(out) == 2:
            diar, emb_matrix = out                       # pyannote 3.x
        else:
            diar = getattr(out, "speaker_diarization", out)
            emb_matrix = getattr(out, "speaker_embeddings", None)   # pyannote 4.x

        turns = [{"start": round(seg.start, 2), "end": round(seg.end, 2), "speaker": spk}
                 for seg, _, spk in diar.itertracks(yield_label=True)]

        if emb_matrix is not None:
            try:
                labels = list(diar.labels())
                for i, spk in enumerate(labels):
                    if i < len(emb_matrix):
                        vec = emb_matrix[i]
                        vec = vec.tolist() if hasattr(vec, "tolist") else list(vec)
                        # Drop non-finite vectors; a NaN embedding would poison matching.
                        if all(v == v for v in vec):
                            embeddings[spk] = [float(v) for v in vec]
            except Exception as e:  # noqa: BLE001
                print(json.dumps({"turns": turns, "embeddings": {},
                                  "warn": f"embeddings unavailable: {e}"}))
                return

        print(json.dumps({"turns": turns, "embeddings": embeddings}))
    except Exception as e:  # noqa: BLE001
        print(json.dumps({"turns": [], "error": str(e)}))


if __name__ == "__main__":
    main()
