#!/usr/bin/env python3
"""Prepare private manifests while preserving WAV/FLAC bytes and native sample format."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import math
import os
import re
import shutil
import stat
import sys
import tarfile
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, Iterator


SCHEMA_VERSION = 1
LANGUAGES = {"en", "ur"}
SOURCES = {"fleurs", "librispeech", "sukhan", "local"}
SLICES = {
    "baseline",
    "short",
    "quiet",
    "phone",
    "mixed",
    "long",
    "noise",
    "silence",
    "test_clean",
    "test_other",
    "stress",
}
FLEURS_REVISION = "70bb2e84b976b7e960aa89f1c648e09c59f894dd"
SUKHAN_REVISION = "3ed8a7c799a265f3a01f6be65ce0786b1ac9174f"
MAX_INPUT_AUDIO_BYTES = 64 * 1024 * 1024
MAX_TAR_MEMBER_BYTES = 64 * 1024 * 1024
MAX_AUDIO_DURATION_SECONDS = 600
MIN_SAMPLE_RATE_HZ = 8000
MAX_SAMPLE_RATE_HZ = 192000
MAX_CHANNELS = 8
TOKEN_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")

REPO_ROOT = Path(__file__).resolve().parents[4]


class InputError(Exception):
    """A validation failure whose message contains no private input data."""


def _is_under(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def _safe_revision(value: str) -> str:
    if not isinstance(value, str) or not TOKEN_RE.fullmatch(value):
        raise InputError("invalid source revision")
    return value


def _safe_token(value: Any, *, label: str = "record identifier") -> str:
    if not isinstance(value, str) or not TOKEN_RE.fullmatch(value):
        raise InputError(f"invalid {label}")
    return value


def _safe_language(value: str) -> str:
    if value not in LANGUAGES:
        raise InputError("unsupported language")
    return value


def _safe_slice(value: Any) -> str:
    if not isinstance(value, str) or value not in SLICES:
        raise InputError("unsupported slice label")
    return value


def _private_input(value: str | Path, *, directory: bool = False) -> Path:
    raw = Path(value).expanduser()
    try:
        if raw.is_symlink():
            raise InputError("symbolic-link input is not allowed")
        resolved = raw.resolve(strict=True)
        details = resolved.stat()
    except InputError:
        raise
    except Exception as exc:
        raise InputError("input is unavailable") from exc
    if _is_under(resolved, REPO_ROOT):
        raise InputError("private corpus inputs must be outside the repository")
    expected = stat.S_ISDIR(details.st_mode) if directory else stat.S_ISREG(details.st_mode)
    if not expected:
        raise InputError("input has an unsupported file type")
    return resolved


def _private_input_either(value: str | Path) -> Path:
    raw = Path(value).expanduser()
    try:
        if raw.is_symlink():
            raise InputError("symbolic-link input is not allowed")
        resolved = raw.resolve(strict=True)
        details = resolved.stat()
    except InputError:
        raise
    except Exception as exc:
        raise InputError("input is unavailable") from exc
    if _is_under(resolved, REPO_ROOT):
        raise InputError("private corpus inputs must be outside the repository")
    if not (stat.S_ISDIR(details.st_mode) or stat.S_ISREG(details.st_mode)):
        raise InputError("input has an unsupported file type")
    return resolved


def _new_private_directory(value: str | Path) -> Path:
    raw = Path(value).expanduser()
    if not raw.is_absolute():
        raise InputError("output must be an explicit absolute path")
    try:
        if raw.exists() or raw.is_symlink():
            raise InputError("output directory already exists")
        parent = raw.parent.resolve(strict=True)
        if not parent.is_dir():
            raise InputError("output parent is unavailable")
        target = parent / raw.name
        if _is_under(target, REPO_ROOT):
            raise InputError("private outputs must be outside the repository")
        os.mkdir(target, 0o700)
        os.chmod(target, 0o700)
    except InputError:
        raise
    except Exception as exc:
        raise InputError("could not create private output directory") from exc
    return target


def _write_private(path: Path, data: bytes) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
        os.chmod(path, 0o600)
    except Exception as exc:
        raise InputError("could not write private output") from exc


def _jsonl_bytes(rows: Iterable[dict[str, Any]]) -> bytes:
    return b"".join(
        (json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
        for row in rows
    )


def _source_bytes(source: bytes | Path) -> bytes:
    if isinstance(source, bytes):
        raw = source
    else:
        try:
            if source.is_symlink() or not source.is_file():
                raise InputError("audio input is not a regular file")
            if source.stat().st_size > MAX_INPUT_AUDIO_BYTES:
                raise InputError("audio input exceeds the safe size limit")
            raw = source.read_bytes()
        except InputError:
            raise
        except Exception as exc:
            raise InputError("audio input is unavailable") from exc
    if not raw or len(raw) > MAX_INPUT_AUDIO_BYTES:
        raise InputError("audio input has an unsupported size")
    return raw


def _inspect_audio(raw: bytes) -> tuple[str, int, int, float]:
    try:
        import soundfile as sf

        info = sf.info(io.BytesIO(raw))
        audio_format = str(info.format).upper()
        rate = int(info.samplerate)
        channels = int(info.channels)
        frames = int(info.frames)
        duration = frames / rate if rate > 0 else math.inf
        if audio_format not in {"WAV", "FLAC"}:
            raise InputError("audio format must be WAV or FLAC")
        if (
            rate < MIN_SAMPLE_RATE_HZ
            or rate > MAX_SAMPLE_RATE_HZ
            or channels < 1
            or channels > MAX_CHANNELS
            or frames <= 0
            or not math.isfinite(duration)
            or duration > MAX_AUDIO_DURATION_SECONDS
        ):
            raise InputError("audio header is outside supported bounds")
        return audio_format, rate, channels, duration
    except InputError:
        raise
    except Exception as exc:
        raise InputError("audio format inspection failed") from exc


def _write_audio(
    path: Path,
    source: bytes,
    audio_info: tuple[str, int, int, float],
) -> None:
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(path, flags, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            written = handle.write(source)
            handle.flush()
            if written != len(source) or os.fstat(handle.fileno()).st_size != len(source):
                raise InputError("prepared audio copy is incomplete")
        os.chmod(path, 0o600)
    except InputError:
        raise
    except Exception as exc:
        raise InputError("audio copy failed") from exc


def _validate_reference(value: Any) -> str:
    if not isinstance(value, str) or "\x00" in value:
        raise InputError("reference text is invalid")
    return value


def _append_record(
    *,
    output: Path,
    ordinal: int,
    spec: dict[str, Any],
    seen_ids: set[str],
    seen_source_records: set[str],
    seen_source_hashes: dict[str, str],
) -> dict[str, Any]:
    source = spec.get("source")
    if source not in SOURCES:
        raise InputError("unsupported source label")
    language = _safe_language(spec.get("language"))
    slice_name = _safe_slice(spec.get("slice"))
    revision = _safe_revision(spec.get("source_revision"))
    record_id = _safe_token(spec.get("id"))
    source_record_id = _safe_token(spec.get("source_record_id", record_id), label="source record identifier")
    if record_id in seen_ids or source_record_id in seen_source_records:
        raise InputError("duplicate source record")
    seen_ids.add(record_id)
    seen_source_records.add(source_record_id)

    reference = _validate_reference(spec.get("reference"))
    speaker = spec.get("speaker_id")
    if speaker is not None:
        speaker = _safe_token(speaker, label="speaker identifier")
    speech_end = spec.get("speech_end_seconds")
    if speech_end is not None:
        if isinstance(speech_end, bool) or not isinstance(speech_end, (int, float)):
            raise InputError("speech endpoint is invalid")
        speech_end = float(speech_end)
        if not math.isfinite(speech_end) or speech_end <= 0:
            raise InputError("speech endpoint is invalid")

    source_audio = _source_bytes(spec.get("audio"))
    source_audio_hash = hashlib.sha256(source_audio).hexdigest()
    audio_directory = output / "audio"
    audio_info = _inspect_audio(source_audio)
    audio_format, sample_rate, channels, duration = audio_info
    audio_path = audio_directory / f"clip-{ordinal:06d}.{audio_format.lower()}"
    _write_audio(audio_path, source_audio, audio_info)
    # Preparation copies source bytes exactly, so both hashes describe the same bytes.
    audio_hash = source_audio_hash
    metadata = spec.get("source_metadata")
    if isinstance(metadata, dict) and "duration_seconds" in metadata:
        declared_duration = metadata["duration_seconds"]
        tolerance = max(0.1, duration * 0.01)
        if abs(declared_duration - duration) > tolerance:
            raise InputError("declared source duration does not match audio")
    duplicate_of = seen_source_hashes.get(audio_hash)
    if duplicate_of is None:
        seen_source_hashes[audio_hash] = record_id

    row: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "id": record_id,
        "source_record_id": source_record_id,
        "language": language,
        "slice": slice_name,
        "audio_path": str(audio_path.resolve()),
        "reference": reference,
        "duration_seconds": duration,
        "audio_format": audio_format,
        "sample_rate_hz": sample_rate,
        "channels": channels,
        "audio_sha256": audio_hash,
        "source_audio_sha256": source_audio_hash,
        "source": source,
        "source_revision": revision,
        "source_license": _source_license(source),
    }
    if duplicate_of is not None:
        row["source_duplicate_of"] = duplicate_of
    if speaker is not None:
        row["speaker_id"] = speaker
    if speech_end is not None:
        if speech_end > duration:
            raise InputError("speech endpoint exceeds audio duration")
        row["speech_end_seconds"] = speech_end
    if metadata is not None:
        if not isinstance(metadata, dict):
            raise InputError("source metadata is invalid")
        row["source_metadata"] = metadata
    return row


def _prepare_records(output_value: str | Path, specs: Iterable[dict[str, Any]]) -> int:
    output = _new_private_directory(output_value)
    rows: list[dict[str, Any]] = []
    try:
        audio_directory = output / "audio"
        audio_directory.mkdir(mode=0o700)
        os.chmod(audio_directory, 0o700)
        seen_ids: set[str] = set()
        seen_source_records: set[str] = set()
        seen_source_hashes: dict[str, str] = {}
        for ordinal, spec in enumerate(specs, start=1):
            rows.append(
                _append_record(
                    output=output,
                    ordinal=ordinal,
                    spec=spec,
                    seen_ids=seen_ids,
                    seen_source_records=seen_source_records,
                    seen_source_hashes=seen_source_hashes,
                )
            )
        if not rows:
            raise InputError("source contains no usable records")
        _write_private(output / "manifest.jsonl", _jsonl_bytes(rows))
        return len(rows)
    except Exception:
        shutil.rmtree(output, ignore_errors=True)
        raise


def _json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise InputError("metadata contains duplicate keys")
        result[key] = value
    return result


def _safe_tar_member(member: tarfile.TarInfo) -> str | None:
    name = member.name
    if not isinstance(name, str) or "\\" in name or name.startswith("/"):
        raise InputError("archive contains an unsafe member")
    parts = PurePosixPath(name).parts
    if any(part in {"..", ""} for part in parts):
        raise InputError("archive contains an unsafe member")
    if member.isdir():
        return None
    if not member.isfile() or member.issym() or member.islnk():
        raise InputError("archive contains a non-regular member")
    if member.size < 0 or member.size > MAX_TAR_MEMBER_BYTES:
        raise InputError("archive member exceeds the safe size limit")
    return PurePosixPath(name).name


def _read_tar_member(archive: tarfile.TarFile, member: tarfile.TarInfo) -> bytes:
    try:
        stream = archive.extractfile(member)
        if stream is None:
            raise InputError("archive member cannot be read")
        with stream:
            data = stream.read(member.size + 1)
        if len(data) != member.size:
            raise InputError("archive member size is inconsistent")
        return data
    except InputError:
        raise
    except Exception as exc:
        raise InputError("archive member could not be read") from exc


def _parse_fleurs_tsv(path: Path, language: str, revision: str) -> dict[str, dict[str, Any]]:
    records: dict[str, dict[str, Any]] = {}
    try:
        with path.open("r", encoding="utf-8", newline="") as handle:
            for line in handle:
                line = line.rstrip("\r\n")
                if not line:
                    continue
                fields = line.split("\t")
                if fields[0].strip().lower() in {"id", "utterance_id"}:
                    continue
                if len(fields) != 7:
                    raise InputError("FLEURS metadata row has an unexpected shape")
                sentence_id, filename, raw_transcription, transcription, phonemes, num_samples, gender = fields
                if not filename or PurePosixPath(filename).name != filename or "\\" in filename:
                    raise InputError("FLEURS audio filename is invalid")
                recording_id = PurePosixPath(filename).stem
                source_record_id = _safe_token(recording_id, label="source recording identifier")
                record_id = _safe_token(f"fleurs-{language}-{recording_id}")
                if filename in records or any(r["source_record_id"] == source_record_id for r in records.values()):
                    raise InputError("FLEURS metadata contains duplicate records")
                if not num_samples.isdecimal() or gender not in {"MALE", "FEMALE", "OTHER"}:
                    raise InputError("FLEURS metadata fields are invalid")
                if not sentence_id.strip() or "\x00" in sentence_id:
                    raise InputError("FLEURS sentence identifier is invalid")
                records[filename] = {
                    "id": record_id,
                    "source_record_id": source_record_id,
                    "source": "fleurs",
                    "source_revision": revision,
                    "language": language,
                    "slice": "baseline",
                    "reference": transcription,
                    "source_metadata": {
                        "sentence_id": sentence_id,
                        "filename": filename,
                        "raw_transcription": raw_transcription,
                        "phonemes": phonemes,
                        "num_samples": int(num_samples),
                        "gender": gender.lower(),
                    },
                }
    except InputError:
        raise
    except Exception as exc:
        raise InputError("FLEURS metadata could not be read") from exc
    if not records:
        raise InputError("FLEURS metadata is empty")
    return records


def _fleurs_local_specs(
    metadata_value: str,
    archive_value: str,
    language: str,
    revision: str,
) -> Iterator[dict[str, Any]]:
    metadata = _private_input(metadata_value)
    archive_path = _private_input(archive_value)
    if metadata.stat().st_size > 64 * 1024 * 1024:
        raise InputError("FLEURS metadata exceeds the safe size limit")
    records = _parse_fleurs_tsv(metadata, language, revision)
    found: set[str] = set()
    try:
        with tarfile.open(archive_path, mode="r|*") as archive:
            for member in archive:
                basename = _safe_tar_member(member)
                if basename is None or basename not in records:
                    continue
                if basename in found:
                    raise InputError("FLEURS archive contains duplicate audio records")
                found.add(basename)
                spec = dict(records[basename])
                spec["audio"] = _read_tar_member(archive, member)
                yield spec
    except InputError:
        raise
    except Exception as exc:
        raise InputError("FLEURS archive could not be read") from exc
    if found != set(records):
        raise InputError("FLEURS archive and metadata coverage differ")


def _safe_audio_under(root: Path, relative_value: Any) -> Path:
    if not isinstance(relative_value, str) or "\\" in relative_value:
        raise InputError("local audio path is invalid")
    relative = PurePosixPath(relative_value)
    if relative.is_absolute() or any(part in {"", ".", ".."} for part in relative.parts):
        raise InputError("local audio path is invalid")
    candidate = root.joinpath(*relative.parts)
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise InputError("symbolic-link audio is not allowed")
    try:
        resolved = candidate.resolve(strict=True)
    except Exception as exc:
        raise InputError("local audio is unavailable") from exc
    if not _is_under(resolved, root) or not resolved.is_file():
        raise InputError("local audio path is invalid")
    return resolved


def _check_source_language(source_language: str, app_language: str, slice_name: str) -> None:
    expected_app_language = {
        "en": "en",
        "ur": "ur",
        "en+ur": "ur",
        "ur+en": "ur",
        "mixed": "ur",
    }.get(source_language)
    if expected_app_language is None or app_language != expected_app_language:
        raise InputError("source language does not match the explicitly selected model language")
    if source_language in {"en+ur", "ur+en", "mixed"} and slice_name != "mixed":
        raise InputError("mixed source speech must use the explicitly selected mixed slice")


def _private_speaker_id(value: Any) -> str | None:
    if value is None or value == "":
        return None
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        raise InputError("speaker metadata is invalid")
    raw = str(value)
    if not raw or "\x00" in raw:
        raise InputError("speaker metadata is invalid")
    if TOKEN_RE.fullmatch(raw):
        return raw
    return "speaker-" + hashlib.sha256(raw.encode("utf-8")).hexdigest()[:24]


def _local_specs(
    metadata_value: str,
    audio_root_value: str,
    source: str,
    language: str,
    revision: str,
    authorized_local_material: bool,
    slice_override: str | None = None,
) -> Iterator[dict[str, Any]]:
    if not authorized_local_material:
        raise InputError("local corpus material requires explicit authorization confirmation")
    metadata = _private_input(metadata_value)
    root = _private_input(audio_root_value, directory=True)
    if metadata.stat().st_size > 128 * 1024 * 1024:
        raise InputError("local metadata exceeds the safe size limit")
    language = _safe_language(language)
    revision = _safe_revision(revision)
    seen_records: set[str] = set()
    try:
        with metadata.open("r", encoding="utf-8") as handle:
            for line in handle:
                if not line.strip():
                    continue
                value = json.loads(line, object_pairs_hook=_json_object)
                if not isinstance(value, dict):
                    raise InputError("local metadata row has an unexpected shape")
                if source == "sukhan":
                    allowed = {"file_name", "transcription", "language", "duration", "speaker_id", "speaker"}
                    if set(value) - allowed or slice_override is None:
                        raise InputError("Sukhan metadata requires a supported field set and explicit slice")
                    file_name = value.get("file_name")
                    if not isinstance(file_name, str) or "\\" in file_name:
                        raise InputError("Sukhan file name is invalid")
                    file_path = PurePosixPath(file_name)
                    if file_path.is_absolute() or any(part in {"", ".", ".."} for part in file_path.parts):
                        raise InputError("Sukhan file name is invalid")
                    source_language = value.get("language")
                    slice_name = _safe_slice(slice_override)
                    reference = _validate_reference(value.get("transcription"))
                    if source_language == "":
                        if reference != "" or slice_name not in {"noise", "silence"}:
                            raise InputError("empty Sukhan language is only valid for explicit no-speech rows")
                    else:
                        if not isinstance(source_language, str) or source_language not in {
                            "en",
                            "ur",
                            "en+ur",
                            "ur+en",
                            "mixed",
                        }:
                            raise InputError("Sukhan language label is invalid")
                        _check_source_language(source_language, language, slice_name)
                    relative_audio = file_path.as_posix()
                    audio = _safe_audio_under(root, relative_audio)
                    source_record_id = hashlib.sha256(relative_audio.encode("utf-8")).hexdigest()[:32]
                    record_id = f"sukhan-{source_record_id}"
                    if record_id in seen_records:
                        raise InputError("Sukhan metadata contains duplicate source records")
                    seen_records.add(record_id)
                    declared_duration = value.get("duration")
                    if isinstance(declared_duration, bool) or not isinstance(declared_duration, (int, float)):
                        raise InputError("Sukhan duration is invalid")
                    declared_duration = float(declared_duration)
                    if not math.isfinite(declared_duration) or declared_duration <= 0:
                        raise InputError("Sukhan duration is invalid")
                    source_speaker = value.get("speaker_id", value.get("speaker"))
                    if "speaker_id" in value and "speaker" in value and value["speaker_id"] != value["speaker"]:
                        raise InputError("Sukhan speaker metadata conflicts")
                    spec = {
                        "id": record_id,
                        "source_record_id": source_record_id,
                        "source": source,
                        "source_revision": revision,
                        "language": language,
                        "slice": slice_name,
                        "reference": reference,
                        "audio": audio,
                        "source_metadata": {
                            "file_name": relative_audio,
                            "source_language": source_language,
                            "duration_seconds": declared_duration,
                        },
                    }
                    if source_speaker is not None:
                        speaker_id = _private_speaker_id(source_speaker)
                        if speaker_id is not None:
                            spec["speaker_id"] = speaker_id
                else:
                    allowed = {"id", "audio_path", "reference", "slice", "speaker_id", "speech_end_seconds", "language"}
                    if set(value) - allowed:
                        raise InputError("local metadata row has an unexpected shape")
                    record_id = _safe_token(value.get("id"))
                    if record_id in seen_records:
                        raise InputError("local metadata contains duplicate records")
                    seen_records.add(record_id)
                    source_language = value.get("language")
                    slice_name = _safe_slice(value.get("slice"))
                    if source_language is not None:
                        if source_language not in {"en", "ur", "en+ur", "ur+en", "mixed"}:
                            raise InputError("local source language label is invalid")
                        _check_source_language(source_language, language, slice_name)
                    audio = _safe_audio_under(root, value.get("audio_path"))
                    spec = {
                        "id": f"{source}-{record_id}",
                        "source_record_id": record_id,
                        "source": source,
                        "source_revision": revision,
                        "language": language,
                        "slice": slice_name,
                        "reference": _validate_reference(value.get("reference")),
                        "audio": audio,
                    }
                    if source_language is not None:
                        spec["source_metadata"] = {"source_language": source_language}
                    if value.get("speaker_id") is not None:
                        spec["speaker_id"] = value["speaker_id"]
                    if value.get("speech_end_seconds") is not None:
                        spec["speech_end_seconds"] = value["speech_end_seconds"]
                yield spec
    except InputError:
        raise
    except Exception as exc:
        raise InputError("local metadata could not be read") from exc
    if not seen_records:
        raise InputError("local metadata is empty")


def _parse_librispeech_transcript(data: bytes) -> list[tuple[str, str]]:
    try:
        text = data.decode("utf-8")
    except Exception as exc:
        raise InputError("LibriSpeech transcript encoding is invalid") from exc
    rows: list[tuple[str, str]] = []
    for line in text.splitlines():
        pieces = line.split(maxsplit=1)
        if len(pieces) != 2:
            raise InputError("LibriSpeech transcript row is invalid")
        utterance_id = _safe_token(pieces[0], label="source record identifier")
        reference = _validate_reference(pieces[1])
        rows.append((utterance_id, reference))
    return rows


def _librispeech_folder_specs(root_value: str, split: str, revision: str) -> Iterator[dict[str, Any]]:
    root = _private_input(root_value, directory=True)
    transcripts: list[Path] = []
    for directory, names, filenames in os.walk(root, followlinks=False):
        current = Path(directory)
        for name in list(names):
            if (current / name).is_symlink():
                raise InputError("LibriSpeech folder contains a symbolic link")
        names[:] = [name for name in names if not (current / name).is_symlink()]
        for filename in filenames:
            path = current / filename
            if path.is_symlink():
                raise InputError("LibriSpeech folder contains a symbolic link")
            if filename.endswith(".trans.txt") and split in path.parts:
                transcripts.append(path)
    if not transcripts:
        raise InputError("LibriSpeech transcript files were not found")
    seen: set[str] = set()
    for transcript in sorted(transcripts):
        content = _source_bytes(transcript)
        for utterance_id, reference in _parse_librispeech_transcript(content):
            if utterance_id in seen:
                raise InputError("LibriSpeech contains duplicate source records")
            seen.add(utterance_id)
            audio_path = transcript.with_name(f"{utterance_id}.flac")
            audio_path = _safe_audio_under(root, audio_path.relative_to(root).as_posix())
            speaker_id = utterance_id.split("-", maxsplit=1)[0]
            _safe_token(speaker_id, label="speaker identifier")
            yield {
                "id": f"librispeech-{split}-{utterance_id}",
                "source_record_id": utterance_id,
                "source": "librispeech",
                "source_revision": revision,
                "language": "en",
                "slice": "test_clean" if split == "test-clean" else "test_other",
                "reference": reference,
                "speaker_id": speaker_id,
                "audio": audio_path,
                "source_metadata": {"chapter_id": "-".join(utterance_id.split("-")[:2])},
            }


def _librispeech_archive_specs(archive_value: str, split: str, revision: str) -> Iterator[dict[str, Any]]:
    archive_path = _private_input(archive_value)
    records_by_audio_path: dict[str, tuple[str, str] | None] = {}
    seen_record_ids: set[str] = set()
    try:
        # Keep only transcript metadata during the first forward pass; reopen the
        # compressed archive for a second forward pass to copy each audio member once.
        with tarfile.open(archive_path, mode="r|*") as archive:
            for member in archive:
                _safe_tar_member(member)
                if member.isdir() or not member.name.endswith(".trans.txt"):
                    continue
                normalized = PurePosixPath(member.name)
                if split not in normalized.parts:
                    continue
                for utterance_id, reference in _parse_librispeech_transcript(
                    _read_tar_member(archive, member)
                ):
                    if utterance_id in seen_record_ids:
                        raise InputError("LibriSpeech contains duplicate source records")
                    seen_record_ids.add(utterance_id)
                    audio_path = (normalized.parent / f"{utterance_id}.flac").as_posix()
                    if audio_path in records_by_audio_path:
                        raise InputError("LibriSpeech contains duplicate audio records")
                    records_by_audio_path[audio_path] = (utterance_id, reference)
        if not records_by_audio_path:
            raise InputError("LibriSpeech transcript files were not found")

        with tarfile.open(archive_path, mode="r|*") as archive:
            for member in archive:
                basename = _safe_tar_member(member)
                if basename is None:
                    continue
                audio_path = PurePosixPath(member.name).as_posix()
                if audio_path not in records_by_audio_path:
                    continue
                record = records_by_audio_path[audio_path]
                if record is None:
                    raise InputError("LibriSpeech archive contains duplicate audio records")
                records_by_audio_path[audio_path] = None
                utterance_id, reference = record
                speaker_id = utterance_id.split("-", maxsplit=1)[0]
                _safe_token(speaker_id, label="speaker identifier")
                yield {
                    "id": f"librispeech-{split}-{utterance_id}",
                    "source_record_id": utterance_id,
                    "source": "librispeech",
                    "source_revision": revision,
                    "language": "en",
                    "slice": "test_clean" if split == "test-clean" else "test_other",
                    "reference": reference,
                    "speaker_id": speaker_id,
                    "audio": _read_tar_member(archive, member),
                    "source_metadata": {"chapter_id": "-".join(utterance_id.split("-")[:2])},
                }
        if any(record is not None for record in records_by_audio_path.values()):
            raise InputError("LibriSpeech transcript and audio coverage differ")
    except InputError:
        raise
    except Exception as exc:
        raise InputError("LibriSpeech archive could not be read") from exc


def _source_license(source: str) -> str:
    return {
        "fleurs": "CC-BY-4.0",
        "librispeech": "CC-BY-4.0",
        "sukhan": "SOURCE-TERMS-REVIEW-REQUIRED",
        "local": "PRIVATE-CONSENTED",
    }[source]


def _add_parser(parser: argparse.ArgumentParser) -> None:
    commands = parser.add_subparsers(dest="command", required=True)

    fleurs = commands.add_parser(
        "fleurs",
        help="prepare local FLEURS TSV and test archive without re-encoding source audio",
    )
    fleurs.add_argument("--language", choices=sorted(LANGUAGES), required=True)
    fleurs.add_argument("--metadata", required=True, help="local test.tsv path")
    fleurs.add_argument("--archive", required=True, help="local test.tar.gz path")
    fleurs.add_argument("--revision", default=FLEURS_REVISION)
    fleurs.add_argument("--output", required=True, help="new private output directory")

    libri = commands.add_parser(
        "librispeech",
        help="prepare a local LibriSpeech test archive or folder without extracting archives",
    )
    libri.add_argument("--input", required=True, help="local archive or extracted corpus directory")
    libri.add_argument("--split", choices=("test-clean", "test-other"), required=True)
    libri.add_argument("--revision", default="openslr-12")
    libri.add_argument("--output", required=True, help="new private output directory")

    local = commands.add_parser("local", help="prepare local soundfolder JSONL metadata")
    local.add_argument("--source", choices=("sukhan", "local"), required=True)
    local.add_argument("--language", choices=sorted(LANGUAGES), required=True)
    local.add_argument("--metadata", required=True, help="local JSONL metadata path")
    local.add_argument("--audio-root", required=True, help="root for relative audio_path values")
    local.add_argument("--source-revision", required=True)
    local.add_argument("--slice", dest="slice_name", choices=sorted(SLICES))
    local.add_argument(
        "--authorized-local-material",
        action="store_true",
        help="attest that local audio and references are authorized for this private evaluation",
    )
    local.add_argument("--output", required=True, help="new private output directory")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    _add_parser(parser)
    args = parser.parse_args(argv)
    try:
        if args.command == "fleurs":
            language = _safe_language(args.language)
            revision = _safe_revision(args.revision)
            count = _prepare_records(
                args.output,
                _fleurs_local_specs(args.metadata, args.archive, language, revision),
            )
        elif args.command == "librispeech":
            revision = _safe_revision(args.revision)
            input_path = _private_input_either(args.input)
            if input_path.is_dir():
                specs = _librispeech_folder_specs(str(input_path), args.split, revision)
            else:
                specs = _librispeech_archive_specs(str(input_path), args.split, revision)
            count = _prepare_records(args.output, specs)
        else:
            revision = _safe_revision(args.source_revision)
            count = _prepare_records(
                args.output,
                _local_specs(
                    args.metadata,
                    args.audio_root,
                    args.source,
                    args.language,
                    revision,
                    args.authorized_local_material,
                    args.slice_name,
                ),
            )
        print(f"Prepared {count} clips. Private manifest and audio are ready.")
        return 0
    except Exception:
        print("Preparation failed; private input details were withheld.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
