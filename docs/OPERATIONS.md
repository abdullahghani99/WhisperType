# WhisperType operations and recovery

WhisperType is a macOS client, a model server, and an optional agent on a Mac reached through Screen Sharing. Dictation preserves the spoken content; Prompt mode deliberately expands a request into three editable variants. Meeting notes are generated from a saved transcript.

## Start and grant access

Build with `client/build_app.sh`. The app uses its bundled fonts and stamps its version and source revision. Open Capture to record into Inbox; hold Right Option in another application to capture for that application. The compact pill expands on click, keeps recording controls visible while listening, and offers Inbox when a result needs attention. Open recording controls from the menu for keyboard access.

Microphone settings show the effective input and three independent permissions. Grant Microphone for dictation, Accessibility for typing and shortcuts, and Screen Recording for system audio in meetings. Return to the app after changing permissions: it rechecks access and installs missing event monitors. An ad-hoc signature may require another grant after a rebuild; a stable signing identity preserves the app's designated identity. Do not replace the installed application merely to borrow its permissions for a test build.

Input choice is a saved device UID, with another permitted physical device tried if startup fails. The displayed device is the one that actually started. Bluetooth eligibility, Bluetooth warming, and the 1.5-second pre-roll buffer are distinct settings. Pre-roll defaults on and stays in memory until a recording begins. Disabling Bluetooth warming releases a Bluetooth input after capture; keeping it active can affect headset playback quality. Changes during a recording take effect after stopping.

## Configuration

Environment variables must reach the application process, normally through its LaunchAgent. A shell assignment before `open` is not a reliable way to configure an already-running app. Restart through the configured LaunchAgent after editing its environment.

| Variable | Purpose |
|---|---|
| `VF_SERVER_URL`, `VF_API_KEY` | Client server address and optional matching server key |
| `VF_DATA_DIR`, `VF_LOG_PATH` | Optional isolated client recovery directory and diagnostic log |
| `VF_REMOTE_AGENT_URL`, `VF_REMOTE_AGENT_KEY` | Address and pairing key for the insertion agent |
| `VF_REMOTE_WINDOW_MATCH` | Identifies the intended Screen Sharing window; required for remote insertion |
| `VF_AGENT_HOST`, `VF_AGENT_PORT` | Agent bind address and port; defaults `127.0.0.1:8791` |
| `VF_AGENT_KEY` | Agent pairing key, at least 32 bytes; missing/short keys reject insertion |
| `VF_AGENT_DATA_DIR` | Durable insertion receipts on the destination Mac |
| `VF_DB_PATH`, `VF_VOCAB_PATH`, `VF_SPOOL_DIR` | Server database, learned vocabulary, and accepted meeting audio |
| `VF_POLISH`, `VF_PROMPT` | Enable polishing and prompt generation; both default on |
| `VF_WHISPER_MODEL`, `VF_WHISPER_URL` | Local Whisper model and remote fallback |
| `VF_POLISH_MODEL`, `VF_POLISH_ADAPTER`, `VF_PROMPT_MODEL` | Model/adapter selection; configured adapters take precedence for polish |
| `VF_DIARIZE_PY`, `VF_DIARIZE_SCRIPT` | Separate speaker-processing environment and helper |
| `VF_MAX_UPLOAD_MB`, `VF_MAX_PENDING_MEETINGS` | Meeting acceptance limits; defaults 1024 MB and 100 pending jobs |

When the server key is configured, every data and mutation route requires it; `/health` remains public. An unset server key preserves the existing open-server policy. Choose the network boundary deliberately. The remote insertion agent always requires pairing, even when the server is open. It binds to loopback until explicitly configured for a reachable private address.

## Transaction and recovery behavior

Each dictation gets a UUID, its own audio, and durable result metadata before insertion. Results are processed in recording order. The original application, window and field are checked before typing; a changed destination leaves the result in Inbox. Closing a prompt review saves its edits and removes its keyboard monitor. A disk-write failure keeps the review open. If saving newly captured audio fails, the app retains it in memory, offers Retry, and asks before quitting with unsaved audio.

An agent request first prepares a destination, then reserves a durable receipt before posting keys. Reusing a completed UUID returns its receipt without retyping. A partial or uncertain attempt is never automatically replayed. Where the destination exposes its text and selection, the posted text is verified. Otherwise the app retains the recording and tells the user to inspect the destination. Explicitly inserting again is a new placement and can duplicate text already received; inspect uncertain results first.

Live meetings append bounded, synced PCM journals during capture. Recovery can rebuild a playable WAV from an interrupted journal. A server accepts a meeting only after its spool file is synced. It commits the transcript before deleting spool audio, finishes notes before reporting done, and retains a user-chosen title. Startup resumes accepted work. Retry notes uses the saved transcript; a missing transcript and missing spool require the retained local recording to be uploaded again. Deleting a meeting cancels publication of its result and removes the corresponding spool and embeddings.

Model work uses a bounded, serial priority queue: dictation precedes queued meeting work and keepalive. Cancellation does not allow a second native model call to overlap a still-running first call. A running model call is not preemptible; a long meeting stage can still delay a newly arriving dictation. Queue and execution timings are logged separately. Disk copying and remote HTTP do not block the API event loop. When an older remote Whisper service has no translation endpoint, its original-language transcript is translated by the configured local language model. If neither translation path is available, the job reports an error and retains its recording; it never labels untranslated text as English.

## Retention and backups

Retention is manual by default; there is no hidden time-based deletion. The following stores have separate boundaries:

| Store | Removal |
|---|---|
| Local Inbox audio and draft | Audio released after verified insertion, or explicit Remove in Inbox |
| Completed local dictation metadata | Retained locally as a receipt; not shown as pending work |
| Local meeting WAV and interrupted journals | Retained for recovery; inspect the Recordings folder before manual removal |
| Server dictation history including audio | Delete the item in History |
| Meeting transcript, notes and embeddings | Delete the meeting |
| Learned corrections, terms and snippets | Remove in Dictionary; immediate undo rejects a conflicting later edit |
| Remembered speaker voices | Forget the voice separately; deleting one meeting does not revoke an already learned voice |
| Backups and pre-migration snapshots | Separate copies; current-item deletion does not remove them |

The configured backup workflow may copy the database, including retained audio, to cloud-synced storage. Preserve that choice intentionally and manage backup retention separately. Deletion removes application records; it is not a claim of forensic erasure from SQLite free pages or prior snapshots. Diagnostics record timings and counts; ASR and rejected-polish logs do not include the spoken text.

## Reproducible releases

The tested dependency locks target macOS arm64 and Python 3.13. Install with normal pip resolution and require `pip check` to pass. The inference lock includes local Whisper. The separate diarization lock includes its full dependency closure. Do not reuse the previous conflicting Transformers installation recipe.

`scripts/deploy_server.py --host user@server` stages a complete, hashed release with fresh inference and diarization environments. `--via user@jump-host` is optional. Staging does not stop the running service. Use `--environment path/to/overrides.json` for explicit string-valued overrides; unspecified existing environment entries survive. Existing database, vocabulary, spool and adapter paths remain stable when source moves into a release directory.

Add `--activate` only when ready to replace the service. Activation creates a consistent database snapshot, preserves the prior LaunchAgent, and requires `/health` to identify the new release. Failure restores the prior service configuration. It does not overwrite a database with new writes using an old backup. Staged releases and snapshots are retained for inspection and manual cleanup.

`remote-agent/deploy_agent.py --host user@destination` similarly stages and verifies a signed agent. Use `--sign` with a stable unlocked identity when available. Signing failures stop the process. There is no stored keychain password. Activation requires a valid pairing key, preserves existing settings, checks the new release's health, and restores the previous app/configuration on startup failure. Accessibility is an independent user grant reported by health.

## Learning evaluation

Training inputs are normalized and grouped before deterministic splitting. Train, validation and test partitions are disjoint; duplicate input with contradictory gold output is rejected. Only training edits are oversampled. A better test loss does not establish faithful dictation: review a separate comparison for numbers, negation, names, ownership, questions and commands before approving a candidate. The redistillation script is report-only by default and requires an explicit semantic-review artifact as well as better loss before its deployment branch. Run eval_distill.py with --candidate and --out, review the report, and set human_approved to true only after accepting its evidence. The gate checks that the approved candidate fingerprint still matches the actual weights; a stale report cannot approve a new training run.

## Validation limits

Unit and protocol suites, synthetic real-model inference, and native view captures cover different claims. VoiceOver, physical Bluetooth transitions, real system audio, and destination-app acceptance require an active console and the relevant permissions. A rendered window is not proof of those behaviors. Public exports contain allowlisted source and tests only; runtime data, keys, model weights, and private review records never belong in the public repository.
