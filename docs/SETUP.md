# WhisperType — Setup

## 0. Prerequisites
- An **Apple-Silicon Mac** to act as the server (M1/M2/M3…), macOS 13+, ~16 GB RAM+.
- Python 3.12 and Swift (Xcode command-line tools) on the machines you build on.
- Optional: [Tailscale](https://tailscale.com/) so clients can reach the server from anywhere.

## 1. Server (runs the models)
```bash
cd server
python3.12 -m venv .venv
.venv/bin/pip install -r requirements-lock.txt
.venv/bin/python -m uvicorn server:app --host 0.0.0.0 --port 8790
```
- First run downloads Whisper Large V3 + Qwen2.5-7B (~8 GB) and warms them in memory.
- Check it: `curl http://localhost:8790/health`

### Keep it always-warm (launchd)
Create `~/Library/LaunchAgents/app.whispertype.server.plist` pointing at
`.venv/bin/python -m uvicorn server:app --host 0.0.0.0 --port 8790` with
`RunAtLoad` + `KeepAlive` true, then `launchctl load` it. (A template is easy to
adapt from Apple's launchd docs.)

## 2. Client (menu-bar app)
```bash
cd client
./build_app.sh          # builds WhisperType.app (ad-hoc signed by default)
open WhisperType.app
```
- Grant **Microphone** (prompted) and **Accessibility** (System Settings ▸
  Privacy & Security ▸ Accessibility), then **relaunch** — Accessibility only
  takes effect on relaunch.
- Point it at your server if it's not local:
  ```bash
  VF_SERVER_URL=http://<server-tailscale-ip>:8790 open WhisperType.app
  ```
- **Dictate:** hold **Right-Option** and speak, or set a **mouse-button toggle**
  from the menu (click to start, click to stop).

> Tip: ad-hoc signing means macOS may ask you to re-grant Accessibility after a
> rebuild. To make it stick, sign `WhisperType.app` with an Apple Development
> certificate (build_app.sh auto-detects one) or a self-signed cert.

## 3. Remote agent (optional — for Screen Sharing / VNC)  {#remote-agent}
Synthetic modifier keys can't cross the Screen Sharing boundary, so to dictate
into a Mac you're screen-sharing *into*, run the tiny agent **on that Mac**:
```bash
# on the target Mac
cd remote-agent
swift build -c release
# wrap .build/release/vfinsert in a .app bundle + LaunchAgent, grant it
# Accessibility, and it will listen on :8791
```
Then on the client set:
```bash
VF_REMOTE_AGENT_URL=http://<target-mac-ip>:8791
```
The client auto-detects when Screen Sharing is frontmost and routes the
transcript to the agent, which types it locally on the far Mac (modifiers work).

## 4. Teaching it your vocabulary
Open the app's **Settings ▸ Dictionary**:
- **Corrections**: `heard → correct` (e.g. a name Whisper mishears).
- **Terms**: names/jargon it should spell right (biased into Whisper itself).
Changes apply instantly — no restart.
