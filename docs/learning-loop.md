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
   For a code-only policy repair, fresh reserved transcripts can support an independent source-preservation review: freeze the candidate, selection and source assertions before generating outputs, then compare complete baseline/candidate outputs and latency. Record ambiguities in advance and block unresolved changed interpretations. These analyst assertions are not user corrections or training targets, and do not establish recognition accuracy or benchmark parity. Improvements must also appear in separate development cases; unchanged holdout outputs demonstrate nonregression only. Previously requested audio-correction packets remain separately reserved until reviewed.

5. Retain the existing model unless the candidate demonstrates an improvement without meaning regressions. Record the decision and exact evidence. Training scripts never activate a model. A future adapter release must isolate dictation weights from the shared prompt/meeting model, pass the semantic gate and normal release checks, and retain rollback.
6. Repeat when useful feedback or new failure patterns arrive. Skip retraining unchanged data. Notify only for meaningful improvements, failures or decisions requiring input.

## Daily repair work

The daily cycle maintains a private repair backlog and a polishing completion matrix. Each run reviews up to 50 unreviewed observations, then advances an actionable repair through reproduction, a general hypothesis, legitimate-cleanup counterexamples, implementation and complete baseline/candidate comparisons. Existing unresolved evidence is sufficient for engineering; unchanged correction counts block neither policy work nor regression investigation.

Track questions and boundaries, self-corrections and repeats, apologies and uncertainty, literal knowledge versus filler, numeric references, dictionary alignment and distinct clauses/categories separately. A verified bounded fix closes only its stated scope. Keep broader failures open with exact evidence and a next step, rotate to independent work when one item is ambiguous, and resume saved candidates rather than repeating rejected unchanged experiments.

Promotion requires meaning, readability and latency gates, normal release checks, rollback and no-insertion verification while capture and meeting work are idle. New evidence is never permission to interrupt a recording. Keep the existing model unless the separate training and model-release gates pass; observation text and generated suggestions are never automatically correct targets. Report deployed, rejected, continuing and blocked work distinctly.

Prepare a private dataset on the inference host:

```sh
python scripts/learning_cycle.py --database /private/history.sqlite --references /private/references.json --out /private/learning-runs --reserved /private/reserved-inputs.json
```

Add `--train` for a bounded response-only candidate. Use `scripts/evaluate_polish.py` to run actual model/policy replays; its manifest binds the corpus, policy and adapter weights. Never overwrite an evaluated adapter. `scripts/redistill.sh` delegates to this workflow and cannot run the retired unattended 8B promotion path.

## Current model decision

The baseline remains Qwen2.5 14B with Whisper Large V3 recognition. Two 14B adapter experiments were trained and evaluated during the September repair. Neither justified replacement: the response-only candidate increased fallback on the first reserved comparison. They remain rejected experiments. The deployed improvement is the verified copyediting policy, punctuation recovery, correction capture and relevant examples, rather than a claimed fine-tuning win.

This is a measured improvement loop, not a promise that every recording automatically improves model weights or that a finite benchmark proves perfect accuracy.

The reservation ledger is cumulative and mandatory at the command-line entry point. It excludes protected inputs even if a later reference file reclassifies them, or an explicit correction has the same input. Preparation and isolated experiments are distinct from promotion: a staged candidate does not replace the live model.
# Keep deployment and learning aligned

`scripts/deploy_server.py --activate` now installs the matching versioned learning
toolchain after the new server is healthy, if a private learning workspace exists.
The installer checks the bundle, deployed source manifest, loaded policy and model
route, and shares the learning lock. It never prepares data or trains a model.
Previous versions remain available. If synchronization fails, serving remains
healthy but deployment reports the learning failure; the checked learning entry
point continues to refuse drift.

After a deployment made through another route, run
`python3 scripts/sync_learning_toolchain.py --host <server>` from the matching
verified source checkout, then run the private checked entry point. Do not bypass
the policy check or retrain a rejected unchanged candidate merely to clear drift.
