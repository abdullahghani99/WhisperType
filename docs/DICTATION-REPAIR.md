# Dictation repair — 6 September 2026

## Confirmed cleanup regression

An actual Dictation capture retained the spoken question through recognition and vocabulary correction, then model cleanup replaced its opening with an invented answer. Replaying the same private case through the current model reproduced the failure.

The earlier July regression fix selected the loaded stronger 14B model for cleanup. The original server source retained on the server Mac, dated 3 September, still has that selection. The September reliability change (private commit `e7740e9`, public `4be81b2`) added `and not _polish_distilled`, choosing the smaller adapter model instead when an adapter loaded. That was a regression introduced by our change. Earlier reports saying model selection was unchanged compared against an intermediate baseline already containing that change; they do not establish equivalence to the previously working runtime. The adapter artifacts retain August timestamps; there is no evidence that this work rewrote them.

## Repair and evidence

Cleanup again uses the loaded stronger model, with the existing smaller model as fallback. Questions and requests receive an additional bounded safeguard against newly introduced content and replacement of an opening question/request. Question punctuation, numbers and negation remain protected. Capitalization, punctuation, list layout, ordinary filler removal and self-corrections remain available. The stricter candidate that required identical words was rejected because it suppressed valid polishing.

Actual same-case comparison: the regressed model invented the answer in about 2.15 seconds; restored 14B cleanup preserved the question and cleaned the passage in about 2.51 seconds. The refined safeguard preserved that restored output. Ten additional cases exercised questions, requests, mixed passages, multilingual questions, filler, lists, negation and corrections. These are bounded observations, not a universal quality score.

The live release is `df6772f-beb8a34a`. Health confirms `polish_uses_prompt_model=true`. A retained-audio request through the live endpoint preserved the question and matched the persisted/returned result in 4.50 seconds. It did not insert into any application. The verification-only history row was removed afterward; the original recording/history was preserved. Existing model files, adapter, settings and data remained in place, with the old release, previous service configuration and a database snapshot retained for rollback.

Private/public regression checks: 21 tests and the complete learning test suite pass. The selection regression specifically verifies that a loaded stronger model wins even when the smaller model has an adapter. Public defaults for the fallback model differ; private model timings are not measurements of that public fallback.

## Native paste delivery

WhisperType 0.5.1 build **abcc076** is installed with one native local paste transaction. App/window identity is captured at the dictation trigger; missing AX text-field metadata no longer blocks normal paste. Known secure fields, secure input and changed targets remain rejected. The previous per-character local typer was removed, and the explicit diagnostic follows the same delivery path. Mini/VNC retains its paired-agent transport.

Clipboard contents are captured in all available types, restored only while the transaction still owns them, and never restored over a newer copy. Paste preserves the user's selection and supports Unicode/multiple lines without Enter. AX value/selection improve verification when available. A readable field confirmed unchanged after paste remains actionable in Inbox; completed dispatch without a readable receipt stays quietly recoverable in History, without claiming verified delivery or automatically replaying it.

Validation: private/public release builds and 107 tests / 393 assertions; 17 focus/capability checks; real native AppKit and WebKit paste with independent text/DOM receipts, Unicode/multiline/selection, clipboard all-type restoration, ownership changes and cancellation before dispatch. The native fixtures operate only on their own controls and do not send text into a user's application. 71 source/fixture inputs matched the canonical commit before packaging. The installed app is signed with the existing identity and retains login configuration, settings and recordings.

The user confirmed the real GPT composer is now working: “Yes the GPT composer is now working.” This closes the remaining composer delivery acceptance check for this repair. The confirmation is user-reported; it is not an independently observed text receipt or a universal reliability score. No test text was inserted into the user’s composer by the engineering agent.

The four-centred-pill changes are installed and both PR #4s are merged; the saved position is bottom-centre. The model repair is merged in both PR #5s and native paste in both PR #6s. The older broad experimental guard in PR #3 is closed unmerged as superseded; its branch and evidence remain preserved. Canonical working copies are on merged main, with installed code corresponding to that tree. Recovery archives retain the previous app builds, and the previous server release/configuration/database snapshot remain available.
