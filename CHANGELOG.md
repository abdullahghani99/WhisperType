# Changelog

## [0.9.28] - 2026-10-18

### Fixed
- Recover brief voices in short meetings when the normal diarizer produces an invalid speaker vector. Recovery requires distinct valid voice vectors and leaves ordinary results unchanged; mixed or overlapping ASR segments are explicitly uncertain instead of falsely assigned.
- Require a speaker's own self-introduction before automatic naming; addressing someone by name is not identity evidence.
- Remove concrete task examples from the notes prompt. Decision, commitment and unresolved-issue items now require source excerpts with context checks; concise summaries remain generated and are not a guarantee of perfect factual accuracy.

This is a server update. Desktop capture, microphone lifecycle, native paste and paired remote transport are unchanged. Existing recordings remain intact.


## [0.9.27] - 2026-10-18

### Fixed
- A local Secure Input lock no longer blocks authenticated paired remote insertion before the remote agent can validate its own destination. Remote app, window, canvas and session identity checks remain; remote password fields and changed focus are still refused by the agent. Local native paste behavior is unchanged.

## [0.9.26] - 2026-10-18

### Fixed
- File Inbox recordings in History without claiming delivery or removing audio,
  with a reversible Move to Inbox action for archived dictations.
- Recover interrupted meeting audio once into History, retaining original PCM
  fragments; empty capture sessions no longer produce empty playable recordings.
- Assemble app bundles in the build cache and keep rollback copies outside app
  search, leaving one installed WhisperType app in Applications.


## 0.9.7 — 2026-10-13

- Preserve complete clauses whose noun phrase starts with this, that, these or those.
- Retain supported restarts, repetition cleanup, coordination and explicit corrections.
- Server-only policy repair; model weights and native client are unchanged.

## 0.9.6 — 2026-10-12

- Preserve complete clauses, locally attributed actions and conditional cues during polishing, using the established editing prompt.
- Preserve prefixed direct questions and permit ordinary cleanup of “Do it” instructions.
- Server-only policy repair; model weights and the native client are unchanged.

## 0.5.1 — 2026-09-06

- Capture Bluetooth microphone audio in its native format and convert it inside the app; release input after recording when Bluetooth warming is disabled.
- Honor the selected Bluetooth recording input independently of idle warming.
- Wait for input samples before Listening, clean up canceled/timed-out startup and retain interrupted results for review.
- Keep empty transcription responses in recovery with an explanation instead of reporting Ready or inserting empty text.
- Preserve isolated Review configuration across launches and make the Review identity visible.
- Use a 44×24-point translucent idle pill with background-click and automatic collapse, retained result/error indicators and reduced idle Dock polling.
- Only the compact idle pill is translucent; controls, recovery and call offers use opaque surfaces. Meter history updates at 10 Hz with gentle attack/release smoothing.
- Surface call offers over retained result/error status and diagnose placement failures without logging field content.
- Include native CoreMedia conversion regression coverage alongside 98 Swift tests and327 assertions.

- Retain sent-but-unverified results with explicit confirmation; diagnose current editable destinations and support authenticated paired remote insertion.
- Format complete explicitly spoken lists locally while preserving words and excluding terminal/editor or code-like content.
- Skip receipt waiting when no baseline exists; finish pending dictation before quitting.

- Keep manually started meetings independent of ambient call endings; only an accepted call offer owns automatic stop.

## 0.5.0 — 2026-09-06

Released capture ownership, durable recovery, destination validation and native client interface improvements.
