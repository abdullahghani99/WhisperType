# Dictation repair — 6 September 2026

## Confirmed cleanup regression

An actual Dictation capture retained the spoken question through recognition and vocabulary correction, then model cleanup replaced its opening with an invented answer. Replaying the same private case through the current model reproduced the failure.

The earlier July regression fix selected the loaded stronger 14B model for cleanup. The original server source retained on the server Mac, dated 3 September, still has that selection. The September reliability change added `and not _polish_distilled`, choosing the smaller adapter model instead when an adapter loaded. That was a regression introduced by our change. Earlier reports saying model selection was unchanged compared against an intermediate baseline already containing that change; they do not establish equivalence to the previously working runtime. The adapter artifacts retain August timestamps; there is no evidence that this work rewrote them.

## Repair and evidence

Cleanup again uses the loaded stronger model, with the existing smaller model as fallback. Questions and requests receive an additional bounded safeguard against newly introduced content and replacement of an opening question/request. Question punctuation, numbers and negation remain protected. Capitalization, punctuation, list layout, ordinary filler removal and self-corrections remain available. The stricter candidate that required identical words was rejected because it suppressed valid polishing.

Actual same-case comparison: the regressed model invented the answer in about 2.15 seconds; restored 14B cleanup preserved the question and cleaned the passage in about 2.51 seconds. The refined safeguard preserved that restored output. Ten additional cases exercised questions, requests, mixed passages, multilingual questions, filler, lists, negation and corrections. These are bounded observations, not a universal quality score.

The live release is `df6772f-beb8a34a`. Health confirms `polish_uses_prompt_model=true`. A retained-audio request through the live endpoint preserved the question and matched the persisted/returned result in 4.50 seconds. It did not insert into any application. The verification-only history row was removed afterward; the original recording/history was preserved. Existing model files, adapter, settings and data remained in place, with the old release, previous service configuration and a database snapshot retained for rollback.

Private/public regression checks: 21 tests and the complete learning test suite pass. The selection regression specifically verifies that a loaded stronger model wins even when the smaller model has an adapter. Public defaults for the fallback model differ; private model timings are not measurements of that public fallback.

## Separate delivery repair

A reported GPT chat attempt failed before sending because its focused AX text field was unavailable, despite a known app/window. Missing AX text metadata must not block normal paste into the intended app. The next client change uses one native local paste transaction, with app/window/known secure-field checks, complete clipboard preservation, ownership-safe restoration and optional text receipts. Controlled AppKit/WebKit tests pass; installed real-composer acceptance is still pending. Mini/VNC retains its paired-agent path.

The four-centred-pill changes are already installed and merged in both PR #4s. The older broad experimental polishing guard in PR #3 is separate and is not the live repair. Its evidence and history remain retained.
