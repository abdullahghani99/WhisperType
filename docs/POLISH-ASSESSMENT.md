# WhisperType polishing assessment — 6 September 2026

The tested Inbox update is installed as 0.5.1 build a1d1441. Complete sends with an unavailable receipt now stay recoverable in History without demanding confirmation. Partial, interrupted, failed and unsent items remain actionable. Audio/text are retained; receipt verification and destination checks are unchanged. The server changes below are a draft candidate, not deployed. Production ASR remains release 4f487a6-376f4983.

## Decision

Keep the current polishing model, adapter and prompt. The shorter prompt was faster but lost useful list/correction behavior. An expanded layout prompt added latency for too little improvement. Retain these rejected experiments as evidence. Propose a conservative Unicode-aware acceptance check that preserves word order, emphasis, negation, language, numbers and technical spelling, with narrowly defined explicit correction allowances. It adds no model call. Ambiguous edits return the original transcript.

This is a fidelity candidate with a real tradeoff: some useful grammar repairs, filler removal and complex corrections will be rejected. It should be reviewed as a conservative default, not claimed as a complete Wispr equivalent or general semantic guarantee. No ASR, Bluetooth capture, insertion batching, active-app data collection or model migration is included.

## What Wispr documents

Wispr's Smart Formatting/Backtrack handles formatting and explicit spoken corrections while distinguishing literal uses such as “actually.” The docs describe an undo route for AI edits. These are product behavior descriptions, not a published implementation or benchmark. [Smart Formatting and Backtrack](https://docs.wisprflow.ai/articles/5373093536-how-do-i-use-smart-formatting-and-backtrack)

Wispr documents application categories and nearby cursor context, including names and coding context. WhisperType currently sends no such application context to polishing; it uses local destination checks/formatting exclusions. Broad screen/context collection should not be introduced as a hidden quality change. [Context Awareness](https://docs.wisprflow.ai/articles/4678293671-Context-Awareness)

The September 4 release notes describe Auto Cleanup in Style with None, Light, Medium and High levels. Some help pages still describe the older Smart Formatting controls. Separating faithful dictation from stronger rewriting is a useful design direction, but no new mode/UI is included here. [Wispr release notes](https://wisprflow.ai/whats-new)

Both products support vocabulary customization. WhisperType already has terms, replacements, snippets and a correction-learning loop; improving it does not require replacing the model. Wispr documents dictionary boosting and correction rules. [Dictionary](https://docs.wisprflow.ai/articles/4052411709-teach-flow-your-words-with-the-dictionary)

Wispr also documents language selection and limits around mixed-language dictation, plus IDE-specific recognition of variables and files. These capabilities are not evidence that arbitrary translation is acceptable during faithful cleanup. [Languages](https://docs.wisprflow.ai/articles/3191899797-use-flow-with-multiple-languages), [IDE support](https://docs.wisprflow.ai/articles/6434410694-use-flow-with-cursor-vs-code-and-other-ides)

## Existing pipeline

Microphone audio → Whisper with vocabulary hints → literal vocabulary/snippet replacements → LLM polish → acceptance check → saved history/result → local formatting and guarded insertion. Raw, corrected and polished text are retained by the existing history pipeline. The client also has a narrow explicit spoken-list fallback; the model-only figures below do not score that fallback.

The current model is the existing distilled Llama 3.1 8B adapter. The previous acceptance check used ASCII tokens, broad word overlap and numeric/English-negation counts. This can reject a valid numeric correction while allowing changed word order or non-English intent.

## Bounded evaluation

All inputs are synthetic text. No microphone, private transcript, destination typing or production history was used. Actual inference ran in a separate finite process on the existing model host, with the same 8B model/adapter, temporary data directories and no new listening service. One warmup was excluded. There were 108 calls: 28 baseline, 28 shorter-prompt, 4 repeats, 28 layout-prompt, 4 repeats and 16 unseen holdout cases. No holdout-specific tuning followed.

| Configuration | Required/forbidden checks | Reference token match | Explicit format cases | Median polish time |
| --- | --- | --- | --- | --- |
| Existing prompt + existing check | 21/28 | 16/28 | 2/5 | 0.619 s |
| Shorter prompt + existing check, rejected | 21/28 | 19/28 | 1/5 | 0.474 s |
| Layout prompt + candidate check, rejected | 27/28 | 24/28 | 3/5 | 0.719 s |
| Existing baseline outputs replayed through candidate check | 28/28 | 25/28 | 2/5 | No new inference |
| Existing prompt + candidate check, unseen holdout | 15/16 | 14/16 | Not scored | 0.578 s |
| Same holdout outputs replayed through existing check | 12/16 | 12/16 | Not scored | No new inference |

These small, unblinded fixture scores are diagnostic, not quality percentages or production latency claims. Required phrases do not prove meaning preservation; reference token matching ignores punctuation and allows alternative valid outputs to score poorly. Formatting was only required in five development cases. The holdout covers fidelity, not formatting. Warm isolated text-only latency excludes ASR, network, queue contention, recording startup and insertion. The candidate guard itself took approximately 0.054 ms median in a single local replay; this is not a reliable performance benchmark. No Wispr application was benchmarked.

## Findings and limits

- The existing model/check accepted a French change from refusing to cancel a meeting to cancelling it. The candidate rejects it. It also rejects mixed-language translation, loss of repeated emphasis and deletion caused by treating dictated instructions as actions.
- Clear adjacent corrections such as “15, sorry, 50” and “$80, sorry, $90” can now accept the replacement. Recipient correction with a repeated preposition and a narrow repeated-clause correction are allowed. These are explicit patterns, not general language understanding.
- The holdout keeps “Reserve 12 seats, actually 14 seats” unchanged because repeated-unit correction is outside the narrow allowance. It also rejects the benign repair “we was” → “we were.” These limits are retained rather than patched to improve this score.
- Exact ordered words plus protected code atoms reduce hallucinations, reordering and spelling changes. Punctuation, unquoted syntax, casing and semantic ambiguity remain imperfectly checked. Returning the original also retains ASR mistakes.
- Two spoken questions still do not reliably become a numbered list in model-only output. Email/long-topic paragraphing remains inconsistent. The layout experiment solved only one additional development format case at higher latency. Existing client formatting may improve eligible English lists, but broader formatting is future work.
- Two earlier learning regression examples intentionally change expectations: ambiguous deletion of “also make a message…” and “like” is now rejected. Faithful questions and safe filler/stutter cleanup remain tested. This compatibility cost is explicit.

## Validation and release boundary

Private and public clients build and pass 101 tests / 346 assertions. A background native state/view test verifies quiet History routing, actionable failures, legacy conservatism, reload stability and retained audio/text without taking focus or recording. The installed client signature and unchanged login configuration were verified; its input was idle after restart. The previous app is preserved as a recovery archive.

Both repositories pass 16 server reliability tests, 11 fidelity tests, the learning integration script and 10 release/training tests. An initial broad discovery attempt also selected speaker/model tests without MLX installed and failed to import them; the bounded dependency-light suites above then passed. No speaker/model implementation changed. Known existing Swift concurrency/deprecation warnings remain.

The candidate module is included in both server staging paths and the explicit public export allowlist. Public export sanitizes identities/configuration and includes synthetic fixtures/results only. It does not include weights, recorded audio, runtime databases, private logs or credentials. Public defaults differ from the evaluated private model; these results do not claim an evaluation of the public default model.

No server activation is authorized by this assessment. Before any later activation, stage the exact approved commit, preserve the live environment/adapter/data paths and previous launch configuration, run the release checks, and use the existing rollback procedure if startup/health fails. The current live release remains the rollback target. A full live meeting is still the user's next practical acceptance check, separate from this change.

## Reproduction and evidence

`tests/polish/cases.json` and `holdout.json` contain the synthetic cases. `focused_prompt.txt` and `layout_prompt.txt` are rejected experiments, not runtime prompts. `results/` contains raw synthetic results and separate replay summaries. `scripts/eval_polish_quality.py` runs the selected source/model in isolation and records prompt, adapter, corpus and source hashes; current versions also record the separate guard hash. Earlier recorded model runs predate that metadata field; their source/guard candidate is retained here. Early development raw records can overcount guard fallbacks when marker removal occurred; rely on replay evidence for fallback counts, not those early flags.

Run dependency-light checks with a disposable environment containing fastapi, httpx, requests, numpy and python-multipart:

```sh
python -m unittest discover -s server -p test_reliability.py
python -m unittest discover -s server -p test_polish_guard.py
python server/test_learning.py
python tests/test_release_and_training.py
```

Model evaluation requires the existing MLX environment and adapter. Pass `--server`, `--cases`, `--focused-prompt`, `--model`, `--adapter`, `--out` and `--variant baseline` to the runner. Do not point scratch/output paths at production data. Results are not expected to be bit-for-bit deterministic across runtime/model versions.
