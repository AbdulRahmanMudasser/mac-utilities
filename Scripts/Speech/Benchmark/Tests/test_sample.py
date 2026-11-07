"""Focused deterministic and privacy checks for sample.py."""

from __future__ import annotations

import hashlib
import io
import json
import os
import stat
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from typing import Any
from unittest.mock import patch

import sample


class SampleManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="speech-sample-test-")
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def make_row(
        self,
        index: int,
        duration: float = 1.0,
        *,
        speaker: str | None = None,
    ) -> dict[str, Any]:
        audio_hash = hashlib.sha256(f"audio-{index}".encode()).hexdigest()
        row: dict[str, Any] = {
            "schema_version": 1,
            "id": f"clip-{index:03d}",
            "source_record_id": f"source-{index:03d}",
            "language": "en",
            "slice": "baseline",
            "audio_path": f"/private/corpus/clip-{index:03d}.wav",
            "reference": f"reference text {index}",
            "duration_seconds": duration,
            "audio_format": "WAV",
            "sample_rate_hz": 16000,
            "channels": 1,
            "audio_sha256": audio_hash,
            "source_audio_sha256": audio_hash,
            "source": "local",
            "source_revision": "consented-v1",
            "source_license": "PRIVATE-CONSENTED",
        }
        if speaker is not None:
            row["speaker_id"] = speaker
        return row

    def write_manifest(
        self,
        rows: list[dict[str, Any]],
        name: str = "manifest.jsonl",
        *,
        allow_nan: bool = False,
    ) -> Path:
        path = self.root / name
        body = "".join(
            json.dumps(row, ensure_ascii=False, separators=(",", ":"), allow_nan=allow_nan) + "\n"
            for row in rows
        )
        path.write_text(body, encoding="utf-8")
        path.chmod(0o600)
        return path

    def run_sample(
        self,
        rows: list[dict[str, Any]],
        name: str,
        budget: float,
        *,
        seed: int = 42,
    ) -> tuple[dict[str, Any], Path]:
        manifest = self.write_manifest(rows, f"{name}-input.jsonl")
        output = self.root / name
        record = sample.sample_manifest(manifest, budget, seed, output)
        return record, output

    def test_sampling_is_seeded_and_independent_of_manifest_order(self) -> None:
        rows = [self.make_row(index, 1.0 + index / 100) for index in range(12)]
        first, first_output = self.run_sample(rows, "first", 5.2)
        second, second_output = self.run_sample(list(reversed(rows)), "second", 5.2)

        first_manifest = (first_output / "manifest.jsonl").read_bytes()
        second_manifest = (second_output / "manifest.jsonl").read_bytes()
        self.assertEqual(first_manifest, second_manifest)
        self.assertEqual(first["selected_manifest_sha256"], second["selected_manifest_sha256"])
        self.assertNotEqual(first["source_manifest_sha256"], second["source_manifest_sha256"])
        first_rows = [json.loads(line) for line in first_manifest.splitlines()]
        self.assertTrue(first_rows)
        self.assertEqual(len({row["id"] for row in first_rows}), len(first_rows))

    def test_selection_stays_within_budget_and_preserves_selected_rows(self) -> None:
        rows = [self.make_row(index, duration) for index, duration in enumerate((1.25, 2.5, 3.75, 4.0))]
        record, output = self.run_sample(rows, "bounded", 7.5)
        selected_bytes = (output / "manifest.jsonl").read_bytes()
        selected_rows = [json.loads(line) for line in selected_bytes.splitlines()]
        self.assertLessEqual(record["selected_duration_seconds"], record["budget_seconds"])
        self.assertEqual(
            record["selected_duration_seconds"],
            sum(row["duration_seconds"] for row in selected_rows),
        )
        source_by_id = {row["id"]: row for row in rows}
        for row in selected_rows:
            self.assertEqual(row, source_by_id[row["id"]])
        self.assertEqual(
            record["selected_manifest_sha256"], hashlib.sha256(selected_bytes).hexdigest()
        )
        self.assertEqual(record["source_count"], len(rows))
        self.assertEqual(record["eligible_unique_count"], len(rows))

    def test_exact_duplicate_audio_is_counted_once_and_conflicts_are_rejected(self) -> None:
        canonical = self.make_row(1, 2.0, speaker="speaker-1")
        duplicate = dict(canonical)
        duplicate.update(id="clip-002", source_record_id="source-002", source_duplicate_of=canonical["id"])
        record, output = self.run_sample([canonical, duplicate], "deduplicated", 3.0)
        selected = [json.loads(line) for line in (output / "manifest.jsonl").read_text().splitlines()]
        self.assertEqual(record["source_count"], 2)
        self.assertEqual(record["eligible_unique_count"], 1)
        self.assertEqual(record["selected_count"], 1)
        self.assertEqual(selected, [canonical])

        conflicting = dict(duplicate, reference="a conflicting reference")
        manifest = self.write_manifest([canonical, conflicting], "conflict.jsonl")
        with self.assertRaises(sample.SampleError):
            sample.sample_manifest(manifest, 3.0, 42, self.root / "conflict-output")

    def test_duplicate_identifiers_and_mixed_source_labels_are_rejected(self) -> None:
        row = self.make_row(1)
        duplicate_id = dict(self.make_row(2), id=row["id"])
        manifest = self.write_manifest([row, duplicate_id], "duplicate-id.jsonl")
        with self.assertRaises(sample.SampleError):
            sample.sample_manifest(manifest, 5.0, 42, self.root / "duplicate-id-output")

        row_a = self.make_row(3)
        row_b = self.make_row(4)
        row_b["source"] = "librispeech"
        manifest = self.write_manifest([row_a, row_b], "mixed-source.jsonl")
        with self.assertRaises(sample.SampleError):
            sample.sample_manifest(manifest, 5.0, 42, self.root / "mixed-source-output")

    def test_zero_negative_and_non_finite_budgets_are_rejected(self) -> None:
        manifest = self.write_manifest([self.make_row(1)])
        for index, budget in enumerate((0.0, -1.0, float("nan"), float("inf"))):
            output = self.root / f"bad-budget-{index}"
            with self.subTest(budget=budget), self.assertRaises(sample.SampleError):
                sample.sample_manifest(manifest, budget, 42, output)
            self.assertFalse(output.exists())

    def test_budget_over_phase_limit_is_rejected_before_output_creation(self) -> None:
        manifest = self.write_manifest([self.make_row(1)])
        output = self.root / "over-phase-limit"
        with self.assertRaises(sample.SampleError) as error:
            sample.sample_manifest(manifest, sample.MAX_AUDIO_DURATION_SECONDS + 1, 42, output)
        self.assertEqual(error.exception.code, "duration_limit_exceeded")
        self.assertFalse(output.exists())

    def test_budget_below_every_clip_fails_before_creating_output(self) -> None:
        manifest = self.write_manifest([self.make_row(1, 1.0)])
        output = self.root / "too-small-budget"
        with self.assertRaises(sample.SampleError) as error:
            sample.sample_manifest(manifest, 0.5, 42, output)
        self.assertEqual(error.exception.code, "budget_too_small")
        self.assertFalse(output.exists())

    def test_oversized_manifest_is_rejected_before_reading_contents(self) -> None:
        manifest = self.root / "oversized-manifest.jsonl"
        with manifest.open("wb") as handle:
            handle.truncate(sample.MAX_MANIFEST_BYTES + 1)
        manifest.chmod(0o600)
        with patch.object(Path, "read_bytes", side_effect=AssertionError("read_bytes called")):
            with self.assertRaises(sample.SampleError) as error:
                sample.sample_manifest(manifest, 5.0, 42, self.root / "oversized-output")
        self.assertEqual(error.exception.code, "manifest_too_large")
        self.assertFalse((self.root / "oversized-output").exists())

    def test_zero_negative_and_non_finite_clip_durations_are_rejected(self) -> None:
        for index, duration in enumerate((0.0, -0.1, float("nan"))):
            row = self.make_row(index, duration)
            manifest = self.write_manifest(
                [row], f"bad-duration-{index}.jsonl", allow_nan=True
            )
            with self.subTest(duration=duration), self.assertRaises(sample.SampleError):
                sample.sample_manifest(
                    manifest, 5.0, 42, self.root / f"bad-duration-output-{index}"
                )

    def test_round_robin_covers_speakers_and_duration_quartiles(self) -> None:
        rows: list[dict[str, Any]] = []
        for index in range(16):
            rows.append(
                self.make_row(
                    index,
                    1.0 + index / 1000,
                    speaker="speaker-a" if index % 2 == 0 else "speaker-b",
                )
            )
        record, output = self.run_sample(rows, "coverage", 8.2)
        selected = [json.loads(line) for line in (output / "manifest.jsonl").read_text().splitlines()]
        self.assertEqual(record["selected_count"], 8)
        self.assertEqual({row["speaker_id"] for row in selected}, {"speaker-a", "speaker-b"})
        rank_by_id = {row["id"]: index for index, row in enumerate(sorted(rows, key=lambda r: r["duration_seconds"]))}
        covered = {
            (row["speaker_id"], rank_by_id[row["id"]] * 4 // len(rows)) for row in selected
        }
        self.assertEqual(len(covered), 8)

    def test_selection_record_contains_only_aggregate_provenance(self) -> None:
        row = self.make_row(1)
        record, output = self.run_sample([row], "private-record", 5.0)
        selection_path = output / "selection.json"
        saved = json.loads(selection_path.read_text(encoding="utf-8"))
        expected_keys = {
            "schema_version",
            "method",
            "seed",
            "source_manifest_sha256",
            "selected_manifest_sha256",
            "source_count",
            "eligible_unique_count",
            "selected_count",
            "source_duration_seconds",
            "selected_duration_seconds",
            "budget_seconds",
            "language",
            "source",
            "source_revision",
        }
        self.assertEqual(set(saved), expected_keys)
        self.assertEqual(saved, record)
        encoded = selection_path.read_text(encoding="utf-8")
        for private_value in (row["id"], row["audio_path"], row["reference"]):
            self.assertNotIn(private_value, encoded)
        self.assertEqual(stat.S_IMODE(selection_path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE((output / "manifest.jsonl").stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o700)

    def test_existing_repository_and_symlink_output_paths_are_rejected(self) -> None:
        manifest = self.write_manifest([self.make_row(1)])
        existing = self.root / "existing"
        existing.mkdir()
        with self.assertRaises(sample.SampleError):
            sample.sample_manifest(manifest, 5.0, 42, existing)

        repo_alias = self.root / "repo-alias"
        repo_alias.symlink_to(sample.REPO_ROOT, target_is_directory=True)
        with self.assertRaises(sample.SampleError):
            sample.sample_manifest(manifest, 5.0, 42, repo_alias / "sample-output")

        symlink_leaf = self.root / "symlink-output"
        symlink_leaf.symlink_to(existing, target_is_directory=True)
        with self.assertRaises(sample.SampleError):
            sample.sample_manifest(manifest, 5.0, 42, symlink_leaf)

    def test_symbolic_link_manifest_is_rejected(self) -> None:
        manifest = self.write_manifest([self.make_row(1)])
        alias = self.root / "manifest-alias.jsonl"
        alias.symlink_to(manifest)
        with self.assertRaises(sample.SampleError):
            sample.sample_manifest(alias, 5.0, 42, self.root / "symlink-input-output")

    def test_cli_errors_are_safe_and_do_not_print_private_paths(self) -> None:
        manifest = self.write_manifest([{"private": "invalid schema"}], "private-input.jsonl")
        stderr = io.StringIO()
        with redirect_stderr(stderr):
            result = sample.main(
                [
                    "--manifest",
                    str(manifest),
                    "--max-seconds",
                    "5",
                    "--output",
                    str(self.root / "private-output"),
                ]
            )
        self.assertEqual(result, 2)
        self.assertIn("manifest_invalid", stderr.getvalue())
        self.assertNotIn(str(manifest), stderr.getvalue())
        self.assertNotIn("Traceback", stderr.getvalue())
        self.assertFalse((self.root / "private-output").exists())


if __name__ == "__main__":
    unittest.main()
