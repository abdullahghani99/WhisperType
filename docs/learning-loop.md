# Learning from corrections

WhisperType now uses explicit corrections for immediate personalization and for measured model experiments. Saving more recordings alone does not train a model. Recordings provide examples to investigate; your corrected wording provides the target to learn.

## Teach the wording you wanted

In History, choose **Teach correction** beside a dictation. The sent items in Inbox also offer it in their menu. **Correct last dictation…** remains available from the menu bar. Saving records the original input and your correction, updates the displayed history, and never pastes the text again. A stale edit is rejected so it cannot overwrite a newer correction.

The active dictation polisher can retrieve up to two relevant saved corrections. Its normal meaning checks still apply. Dictionary suggestions remain separately approved: approved replacements fix recurring recognition mistakes, while approved terms help recognition of names. Editing text in another app is not automatically observed; use Teach correction to save that feedback.

Settings → Learning displays saved correction counts. Each new dictation records which polishing path ran, whether recovery was needed, how many examples were used, and the exact policy/model identity. Original audio and original outputs remain available.

Meeting details have separate **Teach correction** actions for notes and transcripts. These corrections update the view while preserving the original record. They form separate datasets; they do not silently become dictation training targets. Corrections made against an older, regenerated transcript are excluded.

## A bounded improvement cycle

1. Read the live database and the private reference archive. Ordinary outputs remain observations. Use explicit corrections and screened development references as potential labels.
2. Group normalized identical inputs before splitting training, validation and test sets. Exclude every reserved benchmark input from training. Keep already inspected benchmark batches marked as consumed; use a fresh reserved batch for new policy decisions.
3. Train a small staged adapter on the actual serving model family. Training learns corrected responses, with instruction tokens masked. Cap each experiment and preserve its data, policy and weight fingerprints.
4. Replay the current baseline and candidate on exactly the same inputs. Inspect punctuation, cleanup, preserved questions, numbers, negation, attribution and distinct points. Reference similarity and training loss are not quality scores; archived reference outputs can also contain mistakes or omissions.
5. Retain the existing model unless the candidate demonstrates an improvement without meaning regressions. Record the decision and exact evidence. Training scripts never activate a model. A future adapter release must isolate dictation weights from the shared prompt/meeting model, pass the semantic gate and normal release checks, and retain rollback.
6. Repeat when useful feedback or new failure patterns arrive. Skip retraining unchanged data. Notify only for meaningful improvements, failures or decisions requiring input.

Prepare a private dataset on the inference host:

```sh
python scripts/learning_cycle.py --database /private/history.sqlite --references /private/references.json --out /private/learning-runs
```

Add `--train` for a bounded response-only candidate. Use `scripts/evaluate_polish.py` to run actual model/policy replays; its manifest binds the corpus, policy and adapter weights. Never overwrite an evaluated adapter. `scripts/redistill.sh` delegates to this workflow and cannot run the retired unattended 8B promotion path.

## Current model decision

The baseline remains Qwen2.5 14B with Whisper Large V3 recognition. Two 14B adapter experiments were trained and evaluated during the September repair. Neither justified replacement: the response-only candidate increased fallback on the first reserved comparison. They remain rejected experiments. The deployed improvement is the verified copyediting policy, punctuation recovery, correction capture and relevant examples, rather than a claimed fine-tuning win.

This is a measured improvement loop, not a promise that every recording automatically improves model weights or that a finite benchmark proves perfect accuracy.
