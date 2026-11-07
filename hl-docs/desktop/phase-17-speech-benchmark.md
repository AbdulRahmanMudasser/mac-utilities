# Phase 17 - Speech Quality And Responsiveness Benchmark

## 1. Phase Purpose

Measure the English and Urdu q5_0 Transcribe paths on macOS with a bounded public-corpus benchmark, synthetic diagnostics and basic installed-app smoke checks. Publish only reviewed aggregate evidence and state the limits of each measurement.

## 2. Feature Objective

- **Goal:** Measure the pinned models, native runtime, VAD settings and streaming path used by Transcribe.
- **Outcome:** Produce a reproducible, bounded quality and responsiveness profile for macOS.
- **In Scope:** Reference-based scoring on selected public English and Urdu corpora; clearly labeled synthetic diagnostics; one basic installed-app smoke check per language; and runner process-initialization, latency and RTF measurements.
- **Out Of Scope:** Natural faint/noisy or conversational code-switch evaluation; gated Urdu evaluation data; runner or installed-app resource profiling; speech-end latency statistics; and energy measurement. These are not acceptance gates for this bounded phase.

## 3. Current State And Implementation Delta

- **Verified State:** Phase 16's post-fix capture and integration verification is complete. The offline runner and data/scoring tools are verified. The bounded 594-clip, 88.8-minute public-data baseline, synthetic diagnostics and basic English/Urdu installed-app smoke checks are recorded in §14; timing summaries are supported by the verified scoring tools.
- **Bounded Decision:** Phase 17 is complete for this defined scope. Results describe the tested public corpora and synthetic inputs; they do not establish general natural-speech quality, broad microphone reliability, installed-app performance across workloads, resource use or energy use.
- **Deferred Beyond This Phase:** Natural faint/noisy speech, conversational code-switching and gated Urdu stress evaluation require suitable authorized data with checked references. They are future evaluation options, not active Phase 17 tasks or blockers.
- **Dependency:** Phase 16 and its privacy controls are complete. Full asset hashes, manifests and per-utterance records remain private; the public document contains aggregate results and limitations only.

## 4. Project Topology And Dependencies

- **Profile:** Native macOS application and local benchmark tooling.
- **Production Anchors:** `MacUtilities/Platform/Speech/WhisperInference.swift`, `MacUtilities/Platform/Speech/SpeechModelMetadata.swift`, `MacUtilities/Features/Speech/StreamingTranscriptionRecognizer.swift` and `MacUtilities/Features/Speech/SpeechSegments.swift` provide the inference, pinned assets and segmentation behavior under evaluation.
- **Benchmark Anchors:** `Scripts/Speech/Benchmark/Native/SpeechBenchmark.swift` is the runner; `Scripts/Speech/Benchmark/Tools/` owns preparation, sampling and scoring; `Scripts/Speech/Benchmark/Tests/` owns their fixtures and regression tests; `Scripts/Speech/run-speech-benchmark.sh` launches the runner.
- **Prerequisite:** [Phase 16](./phase-16-local-speech-transcription.md) is complete. No downstream phase depends on this acceptance decision.
- **Applicable Standards:** [Desktop Development Standards](./development-standards.md) §§2–3 and §§5–6; [Speech Transcription Conventions](../conventions/speech-transcription.md), especially §§3–4 and §6.
- **Related Product Intent:** [PRD, Journey 8](../mac-utilities-prd.md#journey-8-transcribe-speech-privately). This phase evaluates recognition quality and runner responsiveness; it does not revise product requirements.

## 5. Ownership And Delivery Notes

- **Owner / Priority / Target Window:** TBD.
- **Related Build Plan:** Not applicable; this phase verifies the existing local speech feature.
- **Environment Variables, Database, Feature Flags:** Not applicable; the benchmark uses local files and makes no application storage or configuration change.

## 6. Evaluation Data And Privacy

| Data | Use and limits |
| :--- | :--- |
| [FLEURS](https://huggingface.co/datasets/google/fleurs) `en_us` and `ur_pk` test splits | English/Urdu read-speech baseline. Use all Urdu and at most 20 minutes of seeded English. |
| [LibriSpeech](https://www.openslr.org/12) `test-clean` and `test-other` | Additional English check; at most 10 minutes per split. |
| [Urdu Sukhan ASR test sets](https://huggingface.co/datasets/Loudness-ai/urdu-sukhan-asr-test-sets) | Deferred and not used in Phase 17. Any future use requires separate dataset access and source-license review; model access does not grant dataset access. |
| Private consented dictation | Not used in Phase 17. Any future natural-speech evaluation requires consent, checked references and a separately scoped protocol. |

The public pass is bounded to about 90 minutes. English selections are made before inference with a fixed seed and round-robin speaker/duration groups (using duration quartiles) where labels exist. Exclude identical audio but retain distinct recordings of repeated prompts. Record corpus revisions, licenses, population and selection counts, durations, method and hashes in private run records. The full 13-hour corpus run is outside this phase. CSaLT-Voice and UrduSpeech remain excluded until their use terms are clear. Synthetic speech, attenuation/noise transformations and concatenated Urdu/English clips are diagnostics, not natural-speech evidence.

Keep datasets, temporary recordings, references, hypotheses, per-utterance results, credentials and build products outside Git and the public report. Publish aggregate metrics, sample counts, methodology and asset/runtime revisions only. Do not use or redistribute gated material without authorization. Public documentation must omit device identifiers, account names and local paths.

## 7. Benchmark Data And Scoring Contract

The private schema-version-1 JSONL manifest identifies each recording by unique `id`, `language` (`en` or `ur`), `slice`, local audio path and SHA-256, reference, source/revision, and optional speaker and annotated speech-end time. Results match the manifest ID/language/slice and contain status, private hypothesis, duration, available first-partial/stop-to-final/speech-end-to-final timings, inference time/calls and an allowlisted failure code. The private run record captures tool, dataset, source, runtime, model and VAD revisions/hashes, settings and load time. Selection records pin source and selected-manifest hashes.

Use pinned JiWER WER/CER and edit counts; report English WER, Urdu WER and CER, and mixed-language diagnostics separately. Urdu comparability requires the pinned publisher normalizer; its normalized CER excludes whitespace, so retain raw text privately and report the definition. Use deterministic clip-bootstrap 95% intervals and report clip/speaker counts. Unknown speaker grouping limits interval interpretation. Missing, duplicate and failed rows stay visible; failed speech remains in the quality denominator. Score generated silence false text separately. Natural-speech meaning review, VAD-boundary recall and segment-boundary scoring are outside this phase because no suitable checked-reference and annotated-boundary set was available.

## 8. System And Measurement Expectations

Use the exact pinned q5_0 model for the selected language and production Whisper/VAD/streaming settings. The runner replays bounded 16 kHz mono input in real time and validates model/VAD hashes against `SpeechModelMetadata`. The scorer supports corpus-slice summaries for first-partial, end-of-file-to-final, inference and RTF; process-initial model-load time remains in private run metadata. Publish timing summaries only after review. Runner timings do not establish installed-app latency, speech-end latency or resource use. Resource and energy measurements are outside this phase.

Replay more than 250 ms late fails as `audio_replay_interrupted` before overdue audio is delivered; do not burst buffered input or increase queue limits. Interrupted trials count as failures. On capture/reader failure, cancel and join inference, discard queued audio and preserve the original error; normal completion drains and finalizes. Numeric elapsed time includes scheduling and is not native CPU time.

## 9. Acceptance Criteria

- **A1 — Recognition:** Report English WER, Urdu WER/CER and available mixed-language diagnostic scores with confidence intervals, sample counts and limitations. These public read-speech results do not establish natural conversational quality. Do not invent a universal accuracy threshold or publish transcript examples.
- **A2 — Responsiveness:** The scorer supports corpus-slice summaries for first-partial, end-of-file-to-final and RTF with sample counts. Keep per-utterance timing and process-initial model-load data private; publish a timing summary only after review. Do not claim installed-app latency, p95 or speech-end latency from these runs.
- **A3 — Capture and segmentation:** Report regression coverage, generated digital-silence results and the basic English/Urdu installed-app smoke checks. Those smoke checks establish the core record/finalize/History path for one sample per language; they do not establish statistical accuracy, latency or broad capture reliability.
- **A4 — Measurement limits:** Keep local RAM, storage, RSS and CPU readings out of the public report; point-in-time or runner-process observations do not establish sustained installed-app resource use. Resource profiling and energy measurement are outside this phase's acceptance criteria; no validated energy result is claimed.
- **A5 — Completion:** Complete the bounded evidence and record its limitations. Natural-speech/gated-data studies, sustained installed-app profiling, speech-end latency statistics and energy measurement are deferred or excluded; they are not open acceptance gates for this phase.

## 10. Requirement Traceability

| Requirement | Implementation / Evidence | Acceptance |
| :--- | :--- | :--- |
| Reproducible corpus preparation and bounded selection | `Tools/prepare.py`, `Tools/sample.py`, private manifests and selection records | A1, A5 |
| Production-path recognition and failure accounting | `Native/SpeechBenchmark.swift`, fixed production settings and `Tools/score.py` | A1–A3 |
| Privacy and data rights | Private input/output roots, source/license records, aggregate-only public report | A5 |
| Bounded responsiveness | Runner timing/RTF support, regression coverage and basic installed-app smoke checks; explicit scope limits | A2–A5 |

## 11. Implementation Steps

- [x] Extract the audio-stream and recognition contracts into `MacUtilities/Platform/Speech/AudioCaptureStream.swift` and `MacUtilities/Features/Speech/TranscriptionRecognition.swift` without changing their contracts, so the runner can compile production recognition code without app lifecycle or History ownership.
- [x] Add the native runner, launcher, preparation/sampling/scoring tools and focused Python tests. Keep private data outside the repository; reject unsafe output paths and preserve missing, duplicate and failed results.
- [x] Record the bounded public baseline, FLEURS-derived slices, synthetic attenuation/noise and silence probes, fixed-language concatenation, runner timing support and basic English/Urdu installed-app smoke checks (§14).
- Natural-speech/gated-data evaluation, sustained installed-app profiling, speech-end latency statistics and energy measurement are outside this bounded phase and are not completion tasks.

## 12. Risks And Rollback Notes

- Public read-speech and synthetic inputs do not establish natural conversational or microphone performance. Future evaluation requires authorized data with checked references.
- Runner timing measurements do not establish installed-app latency. Local RAM, storage and process-resource readings are excluded from the public results; no resource-profile or energy claim is made.
- **Rollback:** Benchmark runs do not change production data. Stop a run normally; remove only task-owned private temporary outputs after verifying ownership. Do not touch model assets, History or the usage ledger.

## 13. Verification Protocol

Use a private `benchmark_root` outside the repository and authorized pinned model/VAD assets. Create new output directories for each run. Install pinned requirements, run the tooling and runner checks, then prepare/sample/run/score the bounded datasets. For Urdu, pass the reviewed publisher normalizer and its SHA-256. Tooling smoke runs do not count as benchmark evidence.

```sh
python3.12 -m venv "$benchmark_root/venv"
"$benchmark_root/venv/bin/python" -m pip install -r Scripts/Speech/Benchmark/requirements.txt -r Scripts/Speech/Benchmark/requirements-data.txt
PYTHONDONTWRITEBYTECODE=1 "$benchmark_root/venv/bin/python" -m unittest discover -s Scripts/Speech/Benchmark -p 'test_*.py'
Scripts/Speech/run-speech-benchmark.sh --self-test
```

Run hosted regressions and the signed Release build using [Standards §5](./development-standards.md#5-reproducible-project-and-local-signing). Verify the basic English/Urdu record, finalize and History smoke path. Keep per-utterance timing and local RAM/storage/process-resource readings, paths and raw inputs out of the public report. Publish only reviewed corpus aggregates; do not claim installed-app latency or resource use from runner timings.

## 14. Execution Notes

- **Status:** Completed — bounded evaluation with explicit limitations
- **Started At:** 2026-11-02
- **Completed At:** 2026-11-07
- **Blockers:** None within the bounded Phase 17 scope. Natural-speech and gated-data evaluation remain optional future work; energy and sustained installed-app profiling are not acceptance gates.

### Recorded Recognition Results

The bounded baseline contains 594 clips and 88.8 minutes. WER/CER are percentages with clip-bootstrap 95% confidence intervals. All WER/CER intervals in §14 use 2,000 resamples with seed 0; English uses minimal Unicode/case/punctuation normalization and Urdu uses the publisher normalizer, whose CER excludes whitespace.

| Corpus | Clips | Failures | WER | Urdu normalized CER, no whitespace |
| :--- | ---: | ---: | :--- | :--- |
| FLEURS English | 123 | 0 | 11.08% (9.53–12.67%) | — |
| FLEURS Urdu | 299 | 2 | 17.07% (15.74–18.47%) | 7.07% (6.17–8.20%) |
| LibriSpeech `test-clean` | 75 | 0 | 3.76% (2.58–5.19%) | — |
| LibriSpeech `test-other` | 97 | 0 | 6.04% (4.67–7.54%) | — |

Scoring used JiWER 4.0.0. Urdu used publisher normalizer revision `ec6da1c4d82f165014d95152ac1931b6b115817a`. Both FLEURS splits used revision `70bb2e84b976b7e960aa89f1c648e09c59f894dd`; runtime revision was `d1be6fde11ac6e0407606b4e42fe72d34add8037`. Full asset/source hashes and selection provenance remain in private records. English covers the approved subsets, not the full corpora; clip intervals do not fully account for repeated prompts or unknown speaker clustering.

The short slice is duration ≤5 seconds. The low-level proxy is the lowest quartile of whole-clip RMS within each selected FLEURS baseline, chosen before inspecting predictions. These are read-speech proxies, not annotated faint speech; stress slices overlap the baseline and are not independent samples.

| Language / slice | Clips | Audio | Failures | WER (95% CI) | Urdu normalized CER, no whitespace (95% CI) |
| :--- | ---: | ---: | ---: | :--- | :--- |
| English short | 5 | 0.37 min | 0 | 9.09% (1.43–18.75%) | — |
| English low-level proxy | 31 | 4.41 min | 0 | 14.04% (10.78–17.41%) | — |
| Urdu short | 10 | 0.76 min | 0 | 17.29% (13.29–21.99%) | 6.36% (4.29–9.35%) |
| Urdu low-level proxy | 75 | 12.31 min | 1 | 18.31% (15.53–21.85%) | 8.63% (6.38–11.93%) |

The following short-clip probes used paired FLEURS sources and synthetic inputs; they do not represent natural speech or microphone conditions.

| Language | Probe | Clips | Failures | WER (95% CI) | CER (95% CI) |
| :--- | :--- | ---: | ---: | :--- | :--- |
| English | −30 dB amplitude | 5 | 0 | 100.00% (100.00–100.00%) | 100.00% (100.00–100.00%) |
| English | White noise, 10 dB global RMS SNR | 5 | 0 | 15.15% (7.58–22.73%) | 9.45% (4.04–15.05%) |
| Urdu | −30 dB amplitude | 10 | 0 | 22.56% (18.38–27.78%) | 11.44% (8.61–14.50%) |
| Urdu | White noise, 10 dB global RMS SNR | 10 | 0 | 18.05% (13.67–22.48%) | 6.14% (4.24–7.97%) |

English's five attenuated clips produced empty text, counted as reference deletions. Generated digital silence at 3, 10 and 30 seconds per language completed without text or execution failure (0/3 false text and 0 failures per language); this does not measure ambient noise. Fixed-language concatenations of one English and one Urdu read-speech clip, with a 250 ms gap, yielded:

| Fixed model language | Clips | Failures | WER (95% CI) | CER without whitespace (95% CI) |
| :--- | ---: | ---: | :--- | :--- |
| English | 3 | 0 | 81.94% (55.56–100.00%) | 73.68% (51.75–88.07%) |
| Urdu | 3 | 0 | 31.94% (15.38–59.26%) | 26.97% (7.41–58.77%) |

These are composed clips, not spontaneous code-switching; the three-clip intervals are wide and the Urdu normalizer is not comparable to the Urdu-only baseline.

### Installed-App Smoke Verification

Basic installed-app smoke verification was confirmed for English and Urdu. This confirms the core recording and History path only; it is not a statistical accuracy, latency, capture-reliability or resource benchmark. Local device measurements and run-specific failure details are excluded from this public report.

The current tooling verification passed 47 benchmark Python tests, 48 targeted Swift speech tests across three suites, the native runner self-test and shell syntax validation. These checks cover benchmark input bounds, private-data handling, aggregate scoring, streaming recognition and audio capture regressions. They do not establish broader natural-speech or capture reliability.
