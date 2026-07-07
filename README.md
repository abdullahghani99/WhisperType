# WhisperType

**Free, private, self-hosted voice dictation for macOS — and the only one that works over Screen Sharing.**

Hold a key (or click a mouse button), speak, and your words appear — transcribed by [Whisper](https://github.com/openai/whisper) and cleaned up by a local LLM, inserted into whatever app you're in. Everything runs on **your own Apple-Silicon Mac**. No cloud, no subscription, no API keys, nothing leaves your network.

> An open-source alternative to commercial dictation apps. Not affiliated with any of them.

---

## Why it exists

Commercial voice-dictation apps are excellent but they (a) cost a monthly fee per user, (b) send your audio to their cloud, and (c) insert text by **pasting the clipboard** — which silently breaks when the window you're typing into is a **Screen Sharing / VNC session** to another Mac.

WhisperType fixes all three:

- 🔒 **100% local & private** — Whisper + an open LLM run on your Mac via Apple's [MLX](https://github.com/ml-explore/mlx). Audio never leaves your machine.
- 💸 **Free forever** — no accounts, no subscriptions. Run it for yourself or your whole team off one server Mac.
- 🖥️ **Works over Screen Sharing / VNC** — it inserts text as **real keystrokes**, not a clipboard paste. It even runs a tiny agent on the remote Mac so capitals & punctuation come through perfectly (see [Architecture](#architecture)). *This is the headline feature — nothing else does it.*
- ⚡ **~1 second** end-to-end, model kept warm in memory.
- 🧠 **Learns your vocabulary** — teach it names/jargon and it spells them right (biased at the Whisper level, not patched after).

---

## Features

- **Push-to-talk** (hold Right-Option) **or toggle** (click a configurable mouse button — e.g. a Logitech side button — to start/stop).
- Menu-bar app with a floating waveform pill while listening.
- **Custom dictionary & terms** you manage in-app; corrections apply instantly.
- **Faithful polish** — fixes punctuation/caps and removes filler, but never rewrites your meaning or answers your questions.
- **History** of everything you've dictated (menu dropdown + `/history` API).
- **Shift-Enter aware** — newlines don't accidentally submit chat messages.
- Always-warm server via `launchd`; auto-downloads models on first run.

---

## Architecture

```
┌─────────────────────────────┐        ┌──────────────────────────────┐
│  CLIENT (menu-bar app)      │        │  SERVER (any Apple-Silicon Mac) │
│  • global hotkey / mouse    │──HTTP─▶│  • Whisper Large V3 (MLX)      │
│  • mic capture → WAV        │        │  • Qwen2.5-7B polish (MLX)     │
│  • keystroke insertion      │◀─text──│  • FastAPI, always-warm        │
└──────────────┬──────────────┘        │  • vocab + history (SQLite)    │
               │                        └──────────────────────────────┘
               │ if the front app is Screen Sharing:
               ▼
┌─────────────────────────────┐   The remote agent types LOCALLY on the
│  REMOTE AGENT (target Mac)  │   far Mac, so modifier keys (capitals, ?, !)
│  • types transcript locally │   work — synthetic modifiers can't cross the
└─────────────────────────────┘   VNC boundary, so we insert past it.
```

- **Solo:** run server + client on the same Mac.
- **Team:** one server Mac runs the models; everyone else installs the tiny client and points it at that server over [Tailscale](https://tailscale.com/) or LAN. Only the server needs the models.

---

## Requirements

- **Apple Silicon** Mac (M1/M2/M3…) for the server — MLX is Apple-only.
- **~16 GB RAM** minimum on the server (32 GB comfortable). Models total ~8 GB and are auto-downloaded.
- macOS 13+. Clients can be any Mac.

---

## Quick start

See **[docs/SETUP.md](docs/SETUP.md)** for the full walkthrough. In short:

**1. Server**
```bash
cd server
python3.12 -m venv .venv
.venv/bin/pip install -r requirements-lock.txt
.venv/bin/python -m uvicorn server:app --host 0.0.0.0 --port 8790
# first run downloads Whisper + Qwen (~8 GB), then stays warm
```

**2. Client**
```bash
cd client
./build_app.sh        # builds WhisperType.app
open WhisperType.app
```
Grant **Microphone** and **Accessibility** when prompted (Accessibility needs a relaunch). Point it at your server:
```bash
VF_SERVER_URL=http://<server-ip>:8790 open WhisperType.app
```
Then **hold Right-Option and speak** — or set a mouse-button toggle from the menu.

**3. (Optional) Remote agent for Screen Sharing** — see [docs/SETUP.md](docs/SETUP.md#remote-agent).

---

## Models & licenses

| Component | Model | License |
|---|---|---|
| Speech-to-text | `whisper-large-v3` (MLX) | MIT |
| Text polish | `Qwen2.5-7B-Instruct` (MLX) | Apache-2.0 |

Both are fully open and swappable via `VF_WHISPER_MODEL` / `VF_POLISH_MODEL`. You can substitute any MLX-community model (e.g. a Llama model — note Meta's Llama Community License applies if you do).

---

## Configuration (env vars)

| Var | Where | Default | Purpose |
|---|---|---|---|
| `VF_SERVER_URL` | client | `http://127.0.0.1:8790` | server address |
| `VF_REMOTE_AGENT_URL` | client | `http://127.0.0.1:8791` | remote-insert agent (VNC) |
| `VF_POLISH_MODEL` | server | `mlx-community/Qwen2.5-7B-Instruct-4bit` | polish LLM |
| `VF_WHISPER_MODEL` | server | `mlx-community/whisper-large-v3-mlx` | ASR model |
| `VF_PORT` | server | `8790` | server port |
| `VF_API_KEY` | both | — | optional bearer auth |

---

## Privacy

Audio is transcribed on your own hardware and never sent anywhere. The only network traffic is between your client and *your* server. History and vocabulary are stored in local SQLite/JSON on the server.

---

## License

[MIT](LICENSE). See [NOTICE](NOTICE) for third-party attributions.

*"Whisper" is OpenAI's speech model; "Qwen" is Alibaba's model. WhisperType is an independent open-source project not affiliated with or endorsed by OpenAI, Alibaba, Apple, or any commercial dictation product.*
