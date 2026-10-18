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
import math

MODEL = "pyannote/speaker-diarization-3.1"


def usable_embedding(vector):
    return bool(len(vector)) and all(math.isfinite(float(v)) for v in vector) and sum(float(v)*float(v) for v in vector) > 1e-8


def unpack(output):
    if isinstance(output, tuple) and len(output) == 2:
        return output
    return getattr(output, "speaker_diarization", output), getattr(output, "speaker_embeddings", None)


def needs_short_recovery(output, seconds):
    # A zero centroid is not a second voice. On short calls, reassigning every
    # small cluster to the dominant cluster can produce exactly this result.
    diar, matrix = unpack(output)
    if seconds > 300 or matrix is None or len(diar.labels()) < 2:
        return False
    return any(not usable_embedding(v) for v in matrix)


def recovery_is_distinct(output):
    diar, matrix = unpack(output)
    if matrix is None or not 2 <= len(diar.labels()) <= 4 or len(matrix) != len(diar.labels()):
        return False
    if not all(usable_embedding(v) for v in matrix):
        return False
    for i,a in enumerate(matrix):
        for b in matrix[i+1:]:
            cosine=sum(float(x)*float(y) for x,y in zip(a,b))/(sum(float(x)**2 for x in a)*sum(float(x)**2 for x in b))**.5
            if cosine >= 0.5: return False
    return all(diar.label_timeline(label).duration() >= 1.0 for label in diar.labels())


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"turns": [], "error": "no wav path"})); return
    wav = sys.argv[1]
    try:
        import os
        import torch
        torch.set_num_threads(4)
        torch.set_num_interop_threads(2)
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

        recovered = False
        if needs_short_recovery(out, len(arr) / sr):
            try:
                params = pipe.parameters(instantiated=True)
                params["clustering"].update(method="average", min_cluster_size=3)
                pipe.instantiate(params)
                candidate = pipe({"waveform": wf, "sample_rate": sr})
                if recovery_is_distinct(candidate):
                    out = candidate
                    recovered = True
            except Exception as error:
                # Recovery must not discard a usable baseline transcript.
                print("short speaker recovery failed: " + str(error), file=sys.stderr)

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
                        if usable_embedding(vec):
                            embeddings[spk] = [float(v) for v in vec]
            except Exception as e:  # noqa: BLE001
                print(json.dumps({"turns": turns, "embeddings": {},
                                  "warn": f"embeddings unavailable: {e}"}))
                return

        print(json.dumps({"turns": turns, "embeddings": embeddings, "short_cluster_recovery": recovered}))
    except Exception as e:  # noqa: BLE001
        print(json.dumps({"turns": [], "error": str(e)}))


if __name__ == "__main__":
    main()
