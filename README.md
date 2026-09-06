# WhisperType

Self-hosted voice dictation, prompt drafting and meeting notes for macOS.

Hold Right Option in an editable field to dictate, or open Capture to save a result in Inbox. A compact pill above the Dock expands into recording controls. Your configured server runs speech recognition and language models on your own hardware. An optional paired agent supports insertion on another Mac through Screen Sharing.

## Features

- Hold-to-talk and configurable mouse recording triggers, with explicit microphone selection.
- Dictation polishing with safeguards for the original words, numbers and intent; generated results still need review when accuracy matters.
- Prompt mode with three editable variants and saved drafts.
- Inbox recovery for processing failures, changed destinations and uncertain insertion.
- Live meeting capture and imported audio/video, with optional speaker separation, English translation and notes.
- Searchable history, meeting retrieval, dictionary corrections, terms, snippets and reversible learning actions.
- Prepared application/window/field checks and durable insertion receipts. A changed destination retains the result for review.

## Setup

The model server requires Apple Silicon and Python 3.13. Build the macOS 13+ client and optional agent with the Xcode command-line tools. Memory requirements depend on enabled models; allow space for transcription, polish and prompt models to run together.

Start a server in a fresh environment:

```sh
cd server
python3.13 -m venv .venv
.venv/bin/python -m pip install -r requirements-lock.txt
.venv/bin/python -m pip check
.venv/bin/python -m uvicorn server:app --host 127.0.0.1 --port 8790
```

The first run downloads the configured models. Choose a reachable private bind address for clients on another Mac. Configure `VF_API_KEY` on both server and client to protect data routes; an unset server key leaves access open within its network boundary.

Build and open the client:

```sh
cd client
./build_app.sh
open WhisperType.app
```

Use `./install.sh --environment /path/to/client-environment.json` for persistent server settings and login startup. The private JSON file contains string-valued `VF_SERVER_URL` and, if configured, `VF_API_KEY`. Existing settings survive upgrades. Grant Microphone and Accessibility, then return to the app. System audio additionally requires Screen Recording access. A stable signing identity helps preserve permission grants across builds.

See [Setup](docs/SETUP.md) for pairing the remote agent, and [Operations](docs/OPERATIONS.md) for configuration, recovery, retention and staged releases.

## Architecture and data

The client sends recordings to the configured server. Whisper handles transcription; MLX language models handle polish, prompts and notes. Accepted meetings are spooled to disk before processing and resume after server restart. A bounded model queue keeps API requests responsive while preserving native model-call ownership. Long running model stages can still delay new work.

For Screen Sharing, the client prepares an editable destination through the paired agent before capture. The agent checks that destination again before posting keys, stores a receipt, and verifies resulting text where the destination exposes it. Uncertain acceptance keeps the recording in Inbox; inspect the field before explicitly inserting again.

Recordings, transcripts, learned vocabulary and voiceprints have separate retention controls. Configured backups may create additional copies, including copies in cloud-synced storage. Deleting a current item does not remove earlier backups. There is no claim that data remains on one machine when you configure a remote server or backup destination.

## Models and validation

Default model choices include Whisper Large V3, Qwen2.5-7B for polish and Qwen2.5-14B for prompt generation. Models are configurable and have their own licenses; see [NOTICE](NOTICE). Speaker processing uses a separate locked environment and may require model-license acceptance before its initial download.

The repository includes Swift state/recovery checks, server reliability and learning tests, actual client transport checks, agent protocol/HTTP checks and a native preview harness. Real microphone signal, Bluetooth transitions, system audio, VoiceOver and destination-app acceptance require an active console and the relevant permissions. Synthetic model fixtures and screenshots do not establish those results. Release scripts stage by default; activation is explicit.

## License

[MIT](LICENSE). See [NOTICE](NOTICE) for third-party attributions. WhisperType is independent and is not affiliated with OpenAI, Alibaba, Apple or commercial dictation products.
