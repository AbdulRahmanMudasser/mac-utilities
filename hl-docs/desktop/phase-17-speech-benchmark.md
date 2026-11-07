# Phase 17 - Speech Quality And Resource Benchmark

## 1. Phase Purpose

Measure the implemented English and Urdu q5_0 transcription paths on macOS and record enough reproducible evidence to decide whether the feature meets its personal-use quality, responsiveness and resource goals.

## 2. Phase Contract

- **Goal:** Benchmark the exact pinned q5_0 models, native runtime, VAD settings and streaming/segment pipeline used by Transcribe.
- **Scope:** Reference-based recognition scoring; short, quiet, code-switched, long and no-speech cases; real microphone capture; model load, partial/final latency, real-time factor, peak memory and energy; aggregate report and acceptance decision.
- **Out Of Scope:** Replacing either model, adding a fallback or alternate quantization, model training, changing model licenses, publishing audio or transcript examples, and sending speech to a remote service.
- **Dependency:** Phase 16 post-fix native capture and integration verification, plus its privacy controls, must be complete before benchmarking begins. Record the candidate build and asset digests in the private run manifest.
- **Target Environment:** macOS. Public reports and tracked docs must not identify a device, user account or local file path.

## 3. Evaluation Data And Rights

Use the [Urdu Sukhan ASR test sets](https://huggingface.co/datasets/Loudness-ai/urdu-sukhan-asr-test-sets) only after obtaining their separate access approval and following the dataset's listed source licenses. Model access does not grant dataset access. The dataset includes short replies, quiet speech, Urdu-to-English switching, long speech, noise and silence. Its English-only stress subset is small; add a separately licensed held-out English corpus and a private, consent-based set representative of the intended user.

Do not place recordings, reference transcripts, per-utterance hypotheses or account credentials in Git. Keep downloaded datasets, temporary recordings and full machine-readable results outside the repository. Publish only aggregate metrics, sample counts, methodology and asset/runtime revisions. If a set is gated or its reuse terms are unclear, do not use or redistribute it until access and terms are established.

## 4. Scoring Method

- Pin the dataset revision, file manifest and SHA-256 values in the private run record.
- Use the publisher's text normalization for comparable Urdu results. Score English WER, Urdu WER and CER, and Urdu-English code-switch results separately. Keep raw and normalized outputs distinct; do not normalize away meaningful Urdu spelling or spacing differences.
- Use a pinned JiWER version for WER/CER and edit alignments, cross-checking the publisher's scoring method. Preserve substitution, deletion and insertion counts. Calculate deterministic clip-level bootstrap 95% confidence intervals and report the number of clips and speakers for each slice.
- Score no-speech clips separately: report the number and rate that produce any text. Measure VAD speech-boundary misses, short-utterance misses, clipped starts/ends, duplicate text, overlaps and incorrect segment timing separately from aggregate WER/CER.
- Keep a blind human review of a small, preselected sample to classify whether errors change meaning. Do not use subjective review in place of the reference-based scores.

## 5. Run Protocol

1. Record macOS version, app version/build, runtime revision, model/VAD revisions and hashes, scorer/dataset revisions, decode settings, power source, display state, thermal state and background workload. Do not record device identifiers, account names or local paths.
2. Confirm the exact q5_0 asset for each selected language. Keep the selected language fixed for each run and use the production Whisper/VAD and streaming segment settings. Do not compare a different checkpoint as a fallback.
3. Run the full held-out corpus for each language and stress slice. Preserve individual predictions only in the private run directory. Re-run a fixed subset to confirm deterministic scoring and repeatability.
4. Measure cold-process load and warm load separately; do not describe a process restart as a cold disk cache. Measure first-partial latency, speech-end-to-final latency and inference wall time. Report median and p95, plus real-time factor (inference time divided by audio duration).
5. Measure peak app memory with Instruments/Activity Monitor during cold load and sustained transcription. Measure energy against an idle baseline under the same conditions. Use macOS-supported power telemetry when available; otherwise report Activity Monitor Energy Impact as a relative proxy, not joules. Do not use iOS-only Power Profiler results as Mac measurements.
6. Run live microphone checks through the signed app for English and Urdu: clean speech, short/faint speech, a pause, code-switching and silence. Check start/stop, partial/final output, final buffered speech, History persistence, and that only complete nonempty results are saved. Keep test audio transient unless a separately consented private recording is necessary for scoring.

## 6. Provisional Acceptance Gates

- Keep the existing provisional targets: real-time factor below 1 and final output within two seconds after speech ends. Report median and p95; a target is met only when the recorded result meets the stated statistic.
- No capture audio may be silently dropped, duplicated across finalized segments, or saved to History after an empty, failed or cancelled session.
- Report false text on silence/noise, missed short/faint speech, and segment boundary errors as explicit counts and rates. Do not hide a failure inside an aggregate score.
- Report English WER, Urdu WER/CER and code-switch results with confidence intervals. The project has no evidence-based numeric WER/CER cutoff for these exact q5_0 builds; propose an acceptance decision from the measured results and representative examples instead of inventing a threshold.
- Do not mark the feature benchmarked until all requested metrics, data provenance, limitations and post-fix live results are recorded. Any unmet target remains visible; never substitute another model.

## 7. Evidence And Completion

The report must identify the tested app/runtime/assets and scoring method, show per-language and per-stress-slice results, include latency/load/memory/energy measurements, document limitations, and state which provisional gates passed or failed. Keep raw audio, reference text, detailed predictions and private run manifests out of public artifacts. The phase remains In Progress until the report and acceptance decision are complete.

## 8. Execution Notes

- **Status:** Planned
- **Started At:** Not started
- **Completed At:** Not completed
- **Blockers:** The publisher evaluation dataset requires a separate access approval. A private consent-based evaluation set is an alternative; do not request or download gated data without authorization.
- **Notes:** No benchmark measurements are claimed yet. The English and Urdu q5_0 models remain the only transcription checkpoints in scope.
