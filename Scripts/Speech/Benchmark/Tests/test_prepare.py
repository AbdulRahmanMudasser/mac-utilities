from __future__ import annotations

import io
import json
import os
import stat
import struct
import tarfile
import tempfile
import unittest
import wave
from pathlib import Path
from unittest.mock import patch

import prepare


def make_wav(rate: int = 44100, channels: int = 2, frames: int = 4410) -> bytes:
    target = io.BytesIO()
    with wave.open(target, "wb") as output:
        output.setnchannels(channels)
        output.setsampwidth(2)
        output.setframerate(rate)
        frame = struct.pack("<h", 1234) * channels
        output.writeframes(frame * frames)
    return target.getvalue()


def add_tar_bytes(archive: tarfile.TarFile, name: str, data: bytes) -> None:
    info = tarfile.TarInfo(name)
    info.size = len(data)
    archive.addfile(info, io.BytesIO(data))


class PrepareTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="speech-prepare-test-")
        self.root = Path(self.temp.name)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def make_fleurs_inputs(self, *, malicious: bool = False) -> tuple[Path, Path, bytes, bytes]:
        metadata = self.root / "test.tsv"
        archive_path = self.root / "test.tar.gz"
        first = make_wav()
        second = make_wav(rate=16000, channels=1, frames=1600)
        metadata.write_text(
            "1\tfirst.wav\tRaw one\tReference one\tphone one\t4410\tFEMALE\n"
            "1\tsecond.wav\tRaw two\tReference two\tphone two\t1600\tMALE\n",
            encoding="utf-8",
        )
        with tarfile.open(archive_path, "w:gz") as archive:
            if malicious:
                add_tar_bytes(archive, "../first.wav", first)
            else:
                add_tar_bytes(archive, "audio/first.wav", first)
                add_tar_bytes(archive, "audio/second.wav", second)
        return metadata, archive_path, first, second

    def test_fleurs_local_mode_preserves_source_audio_and_tsv_metadata(self) -> None:
        metadata, archive, first, second = self.make_fleurs_inputs()
        output = self.root / "fleurs-output"
        count = prepare._prepare_records(
            output,
            prepare._fleurs_local_specs(str(metadata), str(archive), "en", prepare.FLEURS_REVISION),
        )
        self.assertEqual(count, 2)
        rows = [json.loads(line) for line in (output / "manifest.jsonl").read_text().splitlines()]
        self.assertEqual([row["reference"] for row in rows], ["Reference one", "Reference two"])
        self.assertEqual(rows[0]["source_revision"], prepare.FLEURS_REVISION)
        self.assertEqual(rows[0]["source_license"], "CC-BY-4.0")
        self.assertEqual(rows[0]["source_metadata"]["raw_transcription"], "Raw one")
        self.assertEqual(rows[0]["source_metadata"]["phonemes"], "phone one")
        self.assertEqual(rows[0]["source_metadata"]["sentence_id"], "1")
        self.assertEqual(rows[1]["source_metadata"]["sentence_id"], "1")
        self.assertEqual(rows[0]["sample_rate_hz"], 44100)
        self.assertEqual(rows[0]["channels"], 2)
        self.assertEqual(rows[0]["audio_format"], "WAV")
        self.assertEqual(Path(rows[0]["audio_path"]).read_bytes(), first)
        self.assertEqual(Path(rows[1]["audio_path"]).read_bytes(), second)
        self.assertEqual(rows[0]["audio_sha256"], rows[0]["source_audio_sha256"])
        self.assertAlmostEqual(rows[0]["duration_seconds"], 0.1, places=5)
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((output / "audio").stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((output / "manifest.jsonl").stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(Path(rows[0]["audio_path"]).stat().st_mode), 0o600)

    def test_local_sukhan_mixed_language_maps_to_selected_urdu_language(self) -> None:
        audio_root = self.root / "corpus"
        audio_root.mkdir(mode=0o700)
        (audio_root / "clip.wav").write_bytes(make_wav(rate=16000, channels=1, frames=3200))
        metadata = self.root / "metadata.jsonl"
        metadata.write_text(
            json.dumps(
                {
                    "file_name": "clip.wav",
                    "transcription": "اردو English",
                    "language": "ur+en",
                    "duration": 0.2,
                    "speaker_id": "speaker-1",
                },
                ensure_ascii=False,
            )
            + "\n",
            encoding="utf-8",
        )
        output = self.root / "sukhan-output"
        count = prepare._prepare_records(
            output,
            prepare._local_specs(
                str(metadata),
                str(audio_root),
                "sukhan",
                "ur",
                prepare.SUKHAN_REVISION,
                True,
                "mixed",
            ),
        )
        self.assertEqual(count, 1)
        row = json.loads((output / "manifest.jsonl").read_text())
        self.assertEqual(row["language"], "ur")
        self.assertEqual(row["slice"], "mixed")
        self.assertEqual(row["source_metadata"]["source_language"], "ur+en")
        self.assertEqual(row["source_metadata"]["file_name"], "clip.wav")
        self.assertEqual(row["speaker_id"], "speaker-1")
        self.assertEqual(row["source_license"], "SOURCE-TERMS-REVIEW-REQUIRED")

    def test_sukhan_empty_language_is_allowed_only_for_explicit_no_speech_rows(self) -> None:
        audio_root = self.root / "sukhan-no-speech"
        audio_root.mkdir(mode=0o700)
        (audio_root / "silence.wav").write_bytes(make_wav(rate=16000, channels=1, frames=3200))
        metadata = self.root / "sukhan-no-speech.jsonl"
        row = {
            "file_name": "silence.wav",
            "transcription": "",
            "language": "",
            "duration": 0.2,
        }
        metadata.write_text(json.dumps(row) + "\n", encoding="utf-8")
        output = self.root / "sukhan-no-speech-output"
        count = prepare._prepare_records(
            output,
            prepare._local_specs(
                str(metadata),
                str(audio_root),
                "sukhan",
                "en",
                prepare.SUKHAN_REVISION,
                True,
                "silence",
            ),
        )
        manifest_row = json.loads((output / "manifest.jsonl").read_text())
        self.assertEqual(count, 1)
        self.assertEqual(manifest_row["language"], "en")
        self.assertEqual(manifest_row["slice"], "silence")
        self.assertEqual(manifest_row["reference"], "")
        self.assertEqual(manifest_row["source_metadata"]["source_language"], "")

        invalid_rows = (
            ({**row, "transcription": "unexpected speech"}, "silence"),
            (row, "baseline"),
        )
        for index, (invalid_row, slice_name) in enumerate(invalid_rows):
            with self.subTest(slice=slice_name, transcription=invalid_row["transcription"]):
                metadata.write_text(json.dumps(invalid_row) + "\n", encoding="utf-8")
                specs = prepare._local_specs(
                    str(metadata),
                    str(audio_root),
                    "sukhan",
                    "en",
                    prepare.SUKHAN_REVISION,
                    True,
                    slice_name,
                )
                with self.assertRaises(prepare.InputError):
                    next(specs)

    def test_gated_local_material_requires_explicit_authorization_flag(self) -> None:
        audio_root = self.root / "corpus"
        audio_root.mkdir()
        metadata = self.root / "metadata.jsonl"
        metadata.write_text("{}\n", encoding="utf-8")
        output = self.root / "must-be-cleaned"
        specs = prepare._local_specs(str(metadata), str(audio_root), "sukhan", "ur", prepare.SUKHAN_REVISION, False)
        with self.assertRaises(prepare.InputError):
            prepare._prepare_records(output, specs)
        self.assertFalse(output.exists())

    def test_private_local_corpus_also_requires_consent_attestation(self) -> None:
        audio_root = self.root / "local-corpus"
        audio_root.mkdir()
        metadata = self.root / "local-metadata.jsonl"
        metadata.write_text("{}\n", encoding="utf-8")
        specs = prepare._local_specs(
            str(metadata), str(audio_root), "local", "en", "consented-v1", False
        )
        with self.assertRaises(prepare.InputError):
            next(specs)

    def test_duplicate_audio_is_marked_without_losing_source_rows(self) -> None:
        audio_root = self.root / "corpus"
        audio_root.mkdir()
        audio = make_wav(rate=16000, channels=1, frames=1600)
        (audio_root / "same.wav").write_bytes(audio)
        metadata = self.root / "metadata.jsonl"
        rows = [
            {"id": "record-1", "audio_path": "same.wav", "reference": "same words", "slice": "baseline"},
            {"id": "record-2", "audio_path": "same.wav", "reference": "same words", "slice": "baseline"},
        ]
        metadata.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
        output = self.root / "duplicate-output"
        count = prepare._prepare_records(
            output,
            prepare._local_specs(str(metadata), str(audio_root), "local", "en", "consented-v1", True),
        )
        manifest = [json.loads(line) for line in (output / "manifest.jsonl").read_text().splitlines()]
        self.assertEqual(count, 2)
        self.assertEqual(manifest[1]["source_duplicate_of"], manifest[0]["id"])
        self.assertEqual(len(manifest), 2)
        self.assertEqual(manifest[0]["audio_sha256"], manifest[1]["audio_sha256"])

    def test_tar_traversal_is_rejected_without_creating_output(self) -> None:
        metadata, archive, _, _ = self.make_fleurs_inputs(malicious=True)
        output = self.root / "unsafe-output"
        with self.assertRaises(prepare.InputError):
            prepare._prepare_records(
                output,
                prepare._fleurs_local_specs(str(metadata), str(archive), "en", prepare.FLEURS_REVISION),
            )
        self.assertFalse(output.exists())
        self.assertFalse((self.root / "first.wav").exists())

    def test_librispeech_tar_uses_two_streaming_passes_and_archive_audio_order(self) -> None:
        archive_path = self.root / "librispeech.tar.gz"
        transcript_path = "LibriSpeech/test-clean/10/20/10-20.trans.txt"
        first_audio_path = "LibriSpeech/test-clean/10/20/10-20-0001.flac"
        second_audio_path = "LibriSpeech/test-clean/10/20/10-20-0002.flac"
        audio = make_wav(rate=16000, channels=1, frames=4800)
        second_audio = make_wav(rate=16000, channels=1, frames=3200)
        with tarfile.open(archive_path, "w:gz") as archive:
            # Audio precedes its transcript to exercise the metadata-first pass.
            add_tar_bytes(archive, second_audio_path, second_audio)
            add_tar_bytes(archive, first_audio_path, audio)
            add_tar_bytes(
                archive,
                transcript_path,
                b"10-20-0001 First sentence.\n10-20-0002 Second sentence.\n",
            )
        with patch.object(prepare.tarfile, "open", wraps=prepare.tarfile.open) as open_tar:
            specs = list(prepare._librispeech_archive_specs(str(archive_path), "test-clean", "openslr-12"))
        self.assertEqual([call.kwargs["mode"] for call in open_tar.call_args_list], ["r|*", "r|*"])
        self.assertEqual([spec["source_record_id"] for spec in specs], ["10-20-0002", "10-20-0001"])
        output = self.root / "librispeech-output"
        count = prepare._prepare_records(
            output,
            iter(specs),
        )
        self.assertEqual(count, 2)
        rows = [json.loads(line) for line in (output / "manifest.jsonl").read_text().splitlines()]
        self.assertEqual(rows[0]["source"], "librispeech")
        self.assertEqual(rows[0]["slice"], "test_clean")
        self.assertEqual(rows[0]["speaker_id"], "10")
        self.assertEqual(Path(rows[0]["audio_path"]).read_bytes(), second_audio)
        self.assertEqual(Path(rows[1]["audio_path"]).read_bytes(), audio)
        self.assertFalse((self.root / "LibriSpeech").exists())

    def test_librispeech_streaming_pass_rejects_incomplete_audio_coverage(self) -> None:
        archive_path = self.root / "librispeech-missing-audio.tar.gz"
        with tarfile.open(archive_path, "w:gz") as archive:
            add_tar_bytes(
                archive,
                "LibriSpeech/test-clean/10/20/10-20.trans.txt",
                b"10-20-0001 Transcript without audio.\n",
            )
        output = self.root / "librispeech-incomplete-output"
        with self.assertRaises(prepare.InputError):
            prepare._prepare_records(
                output,
                prepare._librispeech_archive_specs(str(archive_path), "test-clean", "openslr-12"),
            )
        self.assertFalse(output.exists())

    def test_invalid_audio_format_is_rejected(self) -> None:
        output = self.root / "invalid-audio-output"
        spec = {
            "id": "bad-audio",
            "source_record_id": "bad-audio",
            "source": "local",
            "source_revision": "fixture-v1",
            "language": "en",
            "slice": "baseline",
            "reference": "private transcript",
            "audio": b"not an audio file",
        }
        with self.assertRaises(prepare.InputError):
            prepare._prepare_records(output, [spec])
        self.assertFalse(output.exists())

    def test_repository_output_is_rejected_without_creation(self) -> None:
        target = prepare.REPO_ROOT / "private-benchmark-output-test"
        with self.assertRaises(prepare.InputError):
            prepare._new_private_directory(target)
        self.assertFalse(target.exists())


if __name__ == "__main__":
    unittest.main()
