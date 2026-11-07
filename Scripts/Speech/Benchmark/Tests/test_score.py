from __future__ import annotations

import hashlib
import json
import os
import stat
import struct
import tempfile
import unittest
import wave
from pathlib import Path
from typing import Any
from unittest.mock import patch

import score


def wav_bytes() -> bytes:
    import io

    target = io.BytesIO()
    with wave.open(target, "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(16000)
        output.writeframes(struct.pack("<h", 500) * 16000)
    return target.getvalue()


def write_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    path.write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows), encoding="utf-8")


class ScoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="speech-score-test-")
        self.root = Path(self.temp.name)
        self.manifest_path = self.root / "manifest.jsonl"
        self.results_path = self.root / "results.jsonl"
        self.manifest, self.results = self._fixture_rows()
        write_jsonl(self.manifest_path, self.manifest)
        write_jsonl(self.results_path, self.results)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _fixture_rows(self, *, language: str = "en", source: str = "fleurs") -> tuple[list[dict], list[dict]]:
        audio = wav_bytes()
        rows = []
        result_rows = []
        clips = [
            ("speech-good", "Hello, world!", "hello world", "baseline", "speaker-a", "ok"),
            ("speech-failed", "two words", "", "baseline", "speaker-b", "failed"),
            ("silence-text", "", "unexpected text", "silence", None, "ok"),
            ("silence-failed", "", "", "silence", None, "failed"),
            ("silence-quiet", "", "", "silence", None, "ok"),
            ("silence-punctuation", "", ".", "silence", None, "ok"),
        ]
        revision = (
            "70bb2e84b976b7e960aa89f1c648e09c59f894dd"
            if source == "fleurs"
            else "3ed8a7c799a265f3a01f6be65ce0786b1ac9174f"
        )
        for index, (identifier, reference, hypothesis, slice_name, speaker, status) in enumerate(clips):
            raw = audio + bytes([index])
            audio_path = self.root / f"audio-{index}.wav"
            audio_path.write_bytes(raw)
            os.chmod(audio_path, 0o600)
            sha = hashlib.sha256(raw).hexdigest()
            row = {
                "schema_version": 1,
                "id": identifier,
                "source_record_id": f"record-{index}",
                "language": language,
                "slice": slice_name,
                "audio_path": str(audio_path.resolve()),
                "reference": reference,
                "duration_seconds": 1.0,
                "audio_format": "WAV",
                "sample_rate_hz": 16000,
                "channels": 1,
                "audio_sha256": sha,
                "source_audio_sha256": sha,
                "source": source,
                "source_revision": revision,
                "source_license": score.LICENSES[source],
                "source_metadata": {"transcript_marker": "PRIVATE SOURCE METADATA"},
            }
            if speaker is not None:
                row["speaker_id"] = speaker
            rows.append(row)
            result = {
                "schema_version": 1,
                "id": identifier,
                "language": language,
                "slice": slice_name,
                "status": status,
                "hypothesis": hypothesis,
                "duration_seconds": 0.0 if status == "failed" else 1.0,
                "first_partial_seconds": 0.25 if identifier == "speech-good" else None,
                "stop_to_final_seconds": 0.5 if identifier == "speech-good" else None,
                "speech_end_to_final_seconds": None,
                "inference_seconds": 0.2,
                "inference_calls": 2 if status == "ok" else 0,
            }
            if status == "failed":
                result["error_code"] = "inference_failed"
            result_rows.append(result)
        return rows, result_rows

    def run_score(self, name: str, **kwargs: Any) -> dict[str, Any]:
        return score.score(
            manifest_value=str(self.manifest_path),
            results_value=str(self.results_path),
            output_value=str(self.root / name),
            bootstrap_samples=50,
            seed=731,
            **kwargs,
        )

    def selection_record(self, **overrides: Any) -> dict[str, Any]:
        duration = sum(row["duration_seconds"] for row in self.manifest)
        selection = {
            "schema_version": 1,
            "method": score.SELECTION_METHOD,
            "seed": 741,
            "source_manifest_sha256": hashlib.sha256(b"source manifest fixture").hexdigest(),
            "selected_manifest_sha256": hashlib.sha256(self.manifest_path.read_bytes()).hexdigest(),
            "source_count": 20,
            "eligible_unique_count": 12,
            "selected_count": len(self.manifest),
            "source_duration_seconds": 100.0,
            "selected_duration_seconds": duration + 0.0000005,
            "budget_seconds": duration + 1.0,
            "language": self.manifest[0]["language"],
            "source": self.manifest[0]["source"],
            "source_revision": self.manifest[0]["source_revision"],
        }
        selection.update(overrides)
        return selection

    def write_selection_record(self, name: str, **overrides: Any) -> Path:
        path = self.root / f"{name}.json"
        path.write_text(json.dumps(self.selection_record(**overrides)), encoding="utf-8")
        return path

    def test_failed_speech_counts_full_deletions_and_silence_failures_are_not_passes(self) -> None:
        aggregate = self.run_score("report")
        all_group = aggregate["groups"][0]
        self.assertEqual(all_group["sample_count"], 6)
        self.assertEqual(all_group["speech_clip_count"], 2)
        self.assertEqual(all_group["failed_speech_count"], 1)
        self.assertEqual(all_group["word_error_rate"]["deletions"], 2)
        self.assertEqual(all_group["word_error_rate"]["reference_units"], 4)
        self.assertAlmostEqual(all_group["word_error_rate"]["value"], 0.5)
        self.assertEqual(all_group["normalized_word_error_rate"], all_group["word_error_rate"])
        self.assertEqual(all_group["raw_word_error_rate"]["substitutions"], 2)
        self.assertEqual(all_group["raw_word_error_rate"]["deletions"], 2)
        self.assertAlmostEqual(all_group["raw_word_error_rate"]["value"], 1.0)
        self.assertEqual(all_group["silence_clip_count"], 4)
        self.assertEqual(all_group["silence_false_text_count"], 2)
        self.assertAlmostEqual(all_group["silence_false_text_rate"], 0.5)
        self.assertEqual(all_group["silence_no_text_success_count"], 1)
        self.assertEqual(all_group["silence_failed_count"], 1)
        self.assertIsNone(all_group["speaker_count"])
        self.assertEqual(all_group["speaker_id_status"], "partial")
        self.assertEqual(all_group["speaker_id_missing_clip_count"], 4)
        raw_cer = all_group["raw_character_error_rate_with_whitespace"]
        normalized_cer = all_group["normalized_character_error_rate_without_whitespace"]
        self.assertEqual(raw_cer["reference_units"], 22)
        self.assertGreaterEqual(raw_cer["deletions"], 9)
        self.assertEqual(normalized_cer["reference_units"], 18)

    def test_interrupted_replay_remains_a_failed_trial(self) -> None:
        for row in self.results:
            if row["status"] == "failed":
                row["error_code"] = "audio_replay_interrupted"
        write_jsonl(self.results_path, self.results)
        group = self.run_score("interrupted")["groups"][0]
        self.assertEqual(group["failed_speech_count"], 1)
        self.assertEqual(group["silence_failed_count"], 1)
        self.assertEqual(group["word_error_rate"]["deletions"], 2)
        self.assertEqual(group["sample_count"], 6)

    def test_raw_cer_preserves_leading_repeated_and_trailing_whitespace(self) -> None:
        self.manifest[0]["reference"] = " Hello,  world!\n"
        write_jsonl(self.manifest_path, self.manifest)
        aggregate = self.run_score("raw-whitespace")
        group = aggregate["groups"][0]
        self.assertEqual(group["raw_character_error_rate_with_whitespace"]["reference_units"], 25)
        self.assertEqual(group["normalized_character_error_rate_without_whitespace"]["reference_units"], 18)
        report = (self.root / "raw-whitespace" / "report.md").read_text()
        self.assertIn("Raw CER, whitespace preserved", report)
        self.assertIn("including all whitespace", report)

    def test_missing_endpoint_remains_unmeasured_and_timing_uses_valid_rows(self) -> None:
        self.manifest[0]["speech_end_seconds"] = 0.75
        self.results[0]["speech_end_to_final_seconds"] = 0.1
        write_jsonl(self.manifest_path, self.manifest)
        write_jsonl(self.results_path, self.results)
        aggregate = self.run_score("timing-report")
        group = aggregate["groups"][0]
        self.assertNotIn("speech_end_to_final_seconds", group["timing"])
        partial = group["timing"]["first_partial_seconds"]
        self.assertEqual(partial["sample_count"], 1)
        self.assertEqual(partial["minimum"], 0.25)
        self.assertEqual(partial["maximum"], 0.25)
        self.assertNotIn("p95", partial)
        self.assertEqual(partial["unmeasured_count"], 5)
        rtf = group["timing"]["real_time_factor"]
        self.assertEqual(rtf["sample_count"], 4)
        self.assertEqual(rtf["unmeasured_count"], 2)
        report = (self.root / "timing-report" / "report.md").read_text()
        self.assertIn("Range seconds", report)
        self.assertNotIn("p95", report)
        self.assertNotIn("Speech end to final", report)

    def test_total_audio_duration_cannot_exceed_phase_limit_without_sampling_record(self) -> None:
        manifest = [dict(row) for row in self.manifest]
        results = [dict(row) for row in self.results]
        for index in range(9):
            row = dict(manifest[0])
            audio_path = self.root / f"long-audio-{index}.wav"
            audio = wav_bytes() + f"-extra-{index}".encode()
            audio_path.write_bytes(audio)
            audio_path.chmod(0o600)
            audio_hash = hashlib.sha256(audio).hexdigest()
            row.update(
                id=f"long-speech-{index}",
                source_record_id=f"long-record-{index}",
                audio_path=str(audio_path.resolve()),
                duration_seconds=600.0,
                audio_sha256=audio_hash,
                source_audio_sha256=audio_hash,
            )
            manifest.append(row)
            result = dict(results[0])
            result.update(id=row["id"], duration_seconds=600.0)
            results.append(result)
        write_jsonl(self.manifest_path, manifest)
        write_jsonl(self.results_path, results)

        output = self.root / "over-phase-limit"
        with self.assertRaises(score.ScoreError):
            self.run_score("over-phase-limit")
        self.assertFalse(output.exists())

    def test_report_is_aggregate_only_and_outputs_are_private(self) -> None:
        aggregate = self.run_score("private-report")
        output = self.root / "private-report"
        content = (output / "aggregate.json").read_text() + (output / "report.md").read_text()
        report = (output / "report.md").read_text()
        scorer = aggregate["scorer"]
        self.assertEqual(scorer["jiwer_version"], "4.0.0")
        self.assertEqual(
            scorer["script_sha256"],
            hashlib.sha256(Path(score.__file__).resolve().read_bytes()).hexdigest(),
        )
        self.assertRegex(scorer["python_version"], r"\A\d+\.\d+\.\d+\Z")
        self.assertIn(scorer["script_sha256"], content)
        self.assertNotIn(scorer["script_sha256"], report)
        self.assertIn("Range seconds", report)
        self.assertNotIn("p95", report)
        self.assertNotIn("Speech end to final", report)
        self.assertNotIn("Normalizer SHA-256", report)
        self.assertIn("JiWER version: `4.0.0`", content)
        self.assertEqual(aggregate["population_coverage_status"], "unknown")
        self.assertIn("Population coverage: unknown", content)
        for private_value in (
            "Hello, world!",
            "two words",
            "ignored hypothesis",
            "unexpected text",
            "speaker-a",
            "PRIVATE SOURCE METADATA",
            str(self.root),
            "speech-good",
        ):
            self.assertNotIn(private_value, content)
        self.assertFalse(aggregate["acceptance_claim"])
        self.assertIn("not installed-app resource or live-microphone measurement", aggregate["runner_scope"])
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((output / "aggregate.json").stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE((output / "report.md").stat().st_mode), 0o600)

    def test_scorer_refuses_unpinned_jiwer_version(self) -> None:
        output = self.root / "unsupported-jiwer-report"
        with patch.object(score.importlib.metadata, "version", return_value="4.0.1"):
            with self.assertRaises(score.ScoreError):
                self.run_score("unsupported-jiwer-report")
        self.assertFalse(output.exists())

    def test_selection_record_is_validated_projected_and_reported(self) -> None:
        selection_path = self.write_selection_record("selection")
        aggregate = self.run_score("selection-report", selection_record_value=str(selection_path))
        selection = aggregate["selection_provenance"]
        self.assertEqual(set(selection), score.SELECTION_RECORD_KEYS)
        self.assertEqual(selection["selected_count"], len(self.manifest))
        self.assertEqual(aggregate["population_coverage_status"], "selection_recorded")
        content = (
            (self.root / "selection-report" / "aggregate.json").read_text()
            + (self.root / "selection-report" / "report.md").read_text()
        )
        report = (self.root / "selection-report" / "report.md").read_text()
        self.assertIn("Population coverage", content)
        self.assertNotIn(selection["source_manifest_sha256"], report)
        self.assertNotIn(selection["selected_manifest_sha256"], report)
        self.assertNotIn("Source manifest SHA-256", report)
        self.assertNotIn("Selected manifest SHA-256", report)
        for private_value in (str(selection_path), "speech-good", "speaker-a", "PRIVATE SOURCE METADATA"):
            self.assertNotIn(private_value, content)

    def test_selection_record_rejects_mismatched_hashes_counts_durations_and_labels(self) -> None:
        invalid_records = (
            ("selected-hash", {"selected_manifest_sha256": "0" * 64}),
            ("source-hash", {"source_manifest_sha256": "not-a-hash"}),
            ("count", {"selected_count": len(self.manifest) - 1}),
            ("count-order", {"source_count": 5}),
            ("duration", {"selected_duration_seconds": 6.1}),
            ("budget", {"budget_seconds": 5.0}),
            ("source-duration", {"source_duration_seconds": 5.0}),
            ("language", {"language": "ur"}),
            ("source", {"source": "local"}),
            ("revision", {"source_revision": "different-revision"}),
            ("extra-private-field", {"selected_ids": ["private-id"]}),
            ("boolean-seed", {"seed": True}),
        )
        for label, changes in invalid_records:
            with self.subTest(label=label):
                selection_path = self.write_selection_record(f"invalid-selection-{label}", **changes)
                with self.assertRaises(score.ScoreError):
                    self.run_score(
                        f"invalid-selection-report-{label}",
                        selection_record_value=str(selection_path),
                    )

    def test_bootstrap_is_deterministic(self) -> None:
        first = self.run_score("deterministic-a")
        second = self.run_score("deterministic-b")
        self.assertEqual(first["groups"], second["groups"])

    def test_results_require_exact_unique_coverage(self) -> None:
        for label, rows in (
            ("missing", self.results[:-1]),
            ("unknown", self.results[:-1] + [{**self.results[0], "id": "unknown-id"}]),
            ("duplicate", self.results + [dict(self.results[0])]),
        ):
            with self.subTest(label=label):
                write_jsonl(self.results_path, rows)
                with self.assertRaises(score.ScoreError):
                    self.run_score(f"invalid-{label}")
        write_jsonl(self.results_path, self.results)

    def test_result_metadata_must_match_manifest(self) -> None:
        rows = [dict(row) for row in self.results]
        rows[0]["language"] = "ur"
        write_jsonl(self.results_path, rows)
        with self.assertRaises(score.ScoreError):
            self.run_score("bad-language")

    def test_failed_rows_cannot_publish_hypotheses_or_endpoint_latencies(self) -> None:
        rows = [dict(row) for row in self.results]
        rows[1]["hypothesis"] = "must not be retained"
        write_jsonl(self.results_path, rows)
        with self.assertRaises(score.ScoreError):
            self.run_score("failed-hypothesis")
        rows[1]["hypothesis"] = ""
        rows[1]["first_partial_seconds"] = 0.1
        write_jsonl(self.results_path, rows)
        with self.assertRaises(score.ScoreError):
            self.run_score("failed-latency")

    def test_failed_rows_require_an_allowlisted_failure_code(self) -> None:
        rows = [dict(row) for row in self.results]
        rows[1].pop("error_code")
        write_jsonl(self.results_path, rows)
        with self.assertRaises(score.ScoreError):
            self.run_score("missing-failure-code")

    def test_input_data_must_be_private_when_parent_directory_is_shared(self) -> None:
        self.root.chmod(0o755)
        try:
            with self.assertRaises(score.ScoreError):
                score._private_file(self.manifest_path)
        finally:
            self.root.chmod(0o700)

    def test_manifest_audio_hash_is_verified(self) -> None:
        rows = [dict(row) for row in self.manifest]
        rows[0]["audio_sha256"] = "0" * 64
        write_jsonl(self.manifest_path, rows)
        with self.assertRaises(score.ScoreError):
            self.run_score("bad-audio-hash")

    def test_duplicate_audio_is_covered_but_excluded_from_sample_denominator(self) -> None:
        rows = [dict(row) for row in self.manifest]
        duplicate = dict(rows[0])
        duplicate["id"] = "speech-duplicate"
        duplicate["source_record_id"] = "record-duplicate"
        duplicate["source_duplicate_of"] = rows[0]["id"]
        rows.append(duplicate)
        result_rows = [dict(row) for row in self.results]
        duplicate_result = dict(result_rows[0])
        duplicate_result["id"] = duplicate["id"]
        result_rows.append(duplicate_result)
        write_jsonl(self.manifest_path, rows)
        write_jsonl(self.results_path, result_rows)
        aggregate = self.run_score("duplicate-report")
        group = aggregate["groups"][0]
        self.assertEqual(aggregate["source_record_count"], 7)
        self.assertEqual(aggregate["duplicate_record_count"], 1)
        self.assertEqual(aggregate["sample_count"], 6)
        self.assertEqual(group["source_record_count"], 7)
        self.assertEqual(group["sample_count"], 6)

    def test_unreviewed_normalizer_is_rejected_before_execution(self) -> None:
        self.assertEqual(
            score.PUBLISHER_NORMALIZER_SHA256,
            "9f1619436d53af792639ebce4a4c8a85e9315c8f36b85b4088eede83959c5571",
        )
        self.manifest, self.results = self._fixture_rows(language="ur")
        write_jsonl(self.manifest_path, self.manifest)
        write_jsonl(self.results_path, self.results)
        normalizer = self.root / "custom-normalizer.py"
        normalizer.write_text(
            "from pathlib import Path\n"
            "Path(__file__).with_name('normalizer-ran').write_text('ran')\n"
            "def normalize_for_eval(text, lang):\n"
            "    return ' '.join(text.split())\n",
            encoding="utf-8",
        )
        digest = hashlib.sha256(normalizer.read_bytes()).hexdigest()
        with self.assertRaises(score.ScoreError):
            self.run_score(
                "custom-normalizer-report",
                normalizer_value=str(normalizer),
                normalizer_sha256=digest,
            )
        self.assertFalse((self.root / "normalizer-ran").exists())
        self.assertFalse((self.root / "custom-normalizer-report").exists())

    def test_normalizer_hash_mismatch_is_rejected(self) -> None:
        normalizer = self.root / "normalizer.py"
        normalizer.write_text("def normalize_for_eval(text, lang): return text\n", encoding="utf-8")
        with self.assertRaises(score.ScoreError):
            self.run_score("bad-normalizer", normalizer_value=str(normalizer), normalizer_sha256="0" * 64)

    def test_run_record_is_validated_and_included_by_safe_fields_only(self) -> None:
        manifest_hash = hashlib.sha256(self.manifest_path.read_bytes()).hexdigest()
        run_record = {
            "schema_version": 1,
            "language": "en",
            "manifest_sha256": manifest_hash,
            "model_sha256": "a" * 64,
            "vad_sha256": "b" * 64,
            "runtime_revision": "c" * 40,
            "source_revision": "d" * 40,
            "source_dirty": True,
            "model_load_seconds": 1.25,
            "selected_count": 6,
            "total_count": 647,
            "completed_count": 4,
            "failed_count": 2,
            "stream_settings": {
                "language": "en",
                "sample_rate_hz": 16000,
                "channel_count": 1,
                "source_decode_buffer_seconds": 0.2,
                "replay_in_real_time": True,
                "maximum_chunk_samples": 16000,
                "stream_buffer_capacity": 32000,
                "maximum_pending_samples": 160000,
                "window_samples": 480000,
                "inference_interval_samples": 32000,
                "finalization_lookback_samples": 32000,
                "finalization_context_overlap_samples": 0,
                "whisper_sampling": "greedy",
                "thread_count": 4,
                "vad_thread_count": 4,
                "translate": False,
                "no_timestamps": False,
                "detect_language": False,
                "vad": True,
                "use_gpu": True,
                "flash_attention": True,
            },
            "runtime_sha256": "e" * 64,
            "source_sha256": "f" * 64,
            "selected_ids": ["private-selected-id"],
            "data_sources": [{"source": "private-source-detail", "local_path": "/private/path"}],
            "model": {"name": "private-model-name"},
            "vad": {"name": "private-vad-name"},
        }
        sibling = self.root / "run.json"
        sibling.write_text(json.dumps(run_record), encoding="utf-8")
        aggregate = self.run_score("with-run-record")
        self.assertEqual(aggregate["run_record"]["model_sha256"], "a" * 64)
        self.assertEqual(aggregate["run_record"]["total_count"], 647)
        self.assertTrue(aggregate["run_record"]["source_dirty"])
        self.assertEqual(aggregate["run_record"]["stream_settings"]["channel_count"], 1)
        report_text = (self.root / "with-run-record" / "aggregate.json").read_text()
        public_report = (self.root / "with-run-record" / "report.md").read_text()
        for private_value in (
            "private-selected-id",
            "private-source-detail",
            "/private/path",
            "private-model-name",
            "private-vad-name",
        ):
            self.assertNotIn(private_value, report_text)
        self.assertEqual(aggregate["run_record"]["runtime_sha256"], "e" * 64)
        self.assertEqual(aggregate["run_record"]["source_sha256"], "f" * 64)
        self.assertIn("e" * 64, report_text)
        self.assertIn("f" * 64, report_text)
        for private_hash in ("a" * 64, "b" * 64, "e" * 64, "f" * 64):
            self.assertNotIn(private_hash, public_report)
        self.assertNotIn("Model load seconds", public_report)

    def test_run_record_dirty_state_and_hashes_are_strictly_validated(self) -> None:
        run_record = {
            "schema_version": 1,
            "language": "en",
            "manifest_sha256": hashlib.sha256(self.manifest_path.read_bytes()).hexdigest(),
            "model_sha256": "a" * 64,
            "vad_sha256": "b" * 64,
            "runtime_revision": "c" * 40,
            "source_revision": "d" * 40,
            "source_dirty": "yes",
            "model_load_seconds": 1.0,
            "selected_count": 6,
            "total_count": 6,
            "completed_count": 4,
            "failed_count": 2,
            "stream_settings": {"language": "en", "sample_rate_hz": 16000, "channel_count": 1},
        }
        run_path = self.root / "bad-run.json"
        run_path.write_text(json.dumps(run_record), encoding="utf-8")
        with self.assertRaises(score.ScoreError):
            self.run_score("bad-run", run_record_value=str(run_path))

    def test_repository_and_symlink_output_destinations_are_rejected(self) -> None:
        repo_output = score.REPO_ROOT / "private-report-test"
        with self.assertRaises(score.ScoreError):
            score._new_private_directory(repo_output)
        destination = self.root / "existing"
        destination.mkdir()
        symlink = self.root / "output-link"
        symlink.symlink_to(destination, target_is_directory=True)
        with self.assertRaises(score.ScoreError):
            self.run_score("output-link")


if __name__ == "__main__":
    unittest.main()
