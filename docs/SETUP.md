# WhisperType setup

Use an Apple Silicon Mac for the model server, Python 3.13, and macOS 13 or later. Build the client and optional insertion agent with the Xcode command-line tools. Model memory needs depend on which transcription, prompt and polishing models you enable; allow room for all models that run together.

## Server

Create a fresh environment on the model Mac:

```sh
cd server
python3.13 -m venv .venv
.venv/bin/python -m pip install -r requirements-lock.txt
.venv/bin/python -m pip check
.venv/bin/python -m uvicorn server:app --host 127.0.0.1 --port 8790
```

The first run needs access to download the configured models. The client must use a reachable address if the server runs on a different Mac; choose the bind address and private network deliberately. Configure `VF_API_KEY` to require authentication on all data routes. An unset key keeps the server open within its network boundary. `/health` reports model readiness.

For speaker separation, create a second environment from `requirements-diarize-lock.txt`. Set `VF_DIARIZE_PY` to its Python executable and `VF_DIARIZE_SCRIPT` to `server/diarize.py`. The pyannote model may require accepting its model license and supplying your Hugging Face token for the initial download. Audio processing then runs on your server. Keep tokens out of source control.

For a persistent service, `scripts/deploy_server.py --host user@server` stages the full source and both locked environments. It preserves existing configuration. `--activate` is an explicit service change; staging alone does not replace a running server. See [Operations](OPERATIONS.md) for rollback and environment overrides.

## Client

```sh
cd client
./build_app.sh
open WhisperType.app
```

For installation and login startup, use `./install.sh`. To configure another server without exposing a key in command arguments, create a private JSON file containing `VF_SERVER_URL` and, when needed, `VF_API_KEY`, then pass `./install.sh --environment /path/to/client-environment.json`. Use file permissions `0600`; unspecified existing settings survive an upgrade. The file contains string-valued environment variables, not app preferences.

Grant Microphone and Accessibility from the app's Microphone page. Meeting system audio additionally needs Screen Recording permission. Return to the app after granting access; relaunch is not required for the permission recheck. Ad-hoc builds may need a fresh grant after rebuilding; a stable signing identity avoids changing the app's designated identity.

Open Capture or click the compact pill to record into Inbox. To place dictation in another application, focus its text field, hold Right Option, wait for Listening, speak, and release. The destination is checked before typing. A changed destination or uncertain insertion keeps the result in Inbox. Prompt mode offers three editable variants before insertion. Import a recording from Capture or the menu to process existing audio/video.

## Remote insertion

The insertion agent runs on the Mac you are controlling through Screen Sharing. Stage it with `remote-agent/deploy_agent.py --host user@destination`; provide a stable unlocked identity with `--sign` when available. Before activation, configure a private environment JSON containing `VF_AGENT_KEY` (at least 32 bytes), `VF_AGENT_HOST` (a reachable private interface), and optionally `VF_AGENT_PORT` (default 8791). Missing pairing configuration rejects activation or insertion.

The client needs three matching settings in its own environment JSON:

- `VF_REMOTE_AGENT_URL`: the agent's reachable address and port.
- `VF_REMOTE_AGENT_KEY`: the same pairing key.
- `VF_REMOTE_WINDOW_MATCH`: text identifying the intended Screen Sharing window.

Grant Accessibility to the agent on that Mac and focus an editable field there before recording. The agent prepares the target before capture, checks it again before insertion, and saves a receipt before sending keys. It does not fall back to typing blindly into a different local or remote window.

## Dictionary, recovery and removal

Dictionary contains corrections, terms, and snippets. Learning suggestions require approval; removal and learning actions offer conflict-aware undo. History and Inbox explain where each result is stored. Recordings survive processing errors and can be retried. An unsaved edit remains open if the disk write fails.

`client/install.sh --uninstall` removes the app and login item while retaining user recordings, preferences and server data. See [Operations](OPERATIONS.md) for the separate deletion and backup boundaries.

## Verify a checkout

Build the client and remote agent, run the `vf-tests` executable, then run the server reliability/learning tests, transport checks and agent protocol checks. The UI preview uses synthetic data and requires an active console for keyboard interaction. Physical microphones, Screen Recording, VoiceOver and real destination typing require the relevant permissions; a build or screenshot does not prove those paths.

### Persistent pairing and limited accessibility receipts

The client also reads `~/Library/Application Support/WhisperType/RemotePairing.json` with the same `VF_REMOTE_AGENT_URL`, `VF_REMOTE_AGENT_KEY` and `VF_REMOTE_WINDOW_MATCH` keys. Environment values take precedence. Keep the file mode 0600 and do not commit it. With the intended Screen Sharing window focused, the signed client's `--diagnose-destination --save-remote-window-match` command saves that window's identity without typing or recording.

An existing authenticated SSH connection can forward a local loopback port to the paired Mac's loopback-only agent. For a persistent tunnel use a separate login item with `ssh -NT`, `ExitOnForwardFailure=yes`, keepalive options and an explicit loopback forwarding address. Keep the agent pairing key enabled even through the tunnel. Verify health through the client endpoint and check that unauthenticated insertion is rejected before use. The paired Mac must be unlocked and the agent's actual signed app must have Accessibility permission.

The `--diagnose-destination` support command reports permission, process identity and focused roles without field text or window titles. It may request the target application's accessibility tree. Chromium/Electron can expose that tree on demand: see [Chromium accessibility](https://www.chromium.org/developers/design-documents/accessibility/) and [Electron accessibility](https://github.com/electron/electron/blob/main/docs/tutorial/accessibility.md).

Some editors and terminals accept typing but cannot expose an exact plain-text receipt. Those entries are marked sent but unverified and are never automatically repeated. Check the destination, then use **It’s in place** to acknowledge successful placement, or review the retained text carefully before choosing another insertion.


### Spoken lists and finishing pending work

Dictation keeps the server cleanup result and applies a narrow local list fallback when one explicit announcement (two to five things, points, items, questions or steps) is followed by a complete consecutive one/two sequence. It preserves every item's wording and never answers dictated questions. Existing multiline text, code-like text, terminal/editor destinations and unknown remote app identities are left unchanged. The paired agent supplies its captured application name; Screen Sharing itself is not treated as the destination editor. The server history retains the server result; Inbox and local placement use the formatted text.

Quitting waits for queued dictation processing and insertion verification to finish before the application exits. New captures are held while quitting; active recording and unsaved-audio protections remain in place. Typing without an exact receipt remains explicitly unverified and is never automatically replayed.
