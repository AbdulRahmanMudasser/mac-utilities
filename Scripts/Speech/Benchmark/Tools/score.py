#!/usr/bin/env python3
"""Score private speech benchmark results and write aggregate-only reports."""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import importlib.metadata
import importlib.util
import io
import json
import math
import os
import random
import re
import stat
import sys
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable


SCHEMA_VERSION = 1
JIWER_VERSION = "4.0.0"
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
LICENSES = {
    "fleurs": "CC-BY-4.0",
    "librispeech": "CC-BY-4.0",
    "sukhan": "SOURCE-TERMS-REVIEW-REQUIRED",
    "local": "PRIVATE-CONSENTED",
}
FAILURE_CODES = {
    "audio_decode_failed",
    "audio_format_unsupported",
    "audio_conversion_failed",
    "audio_stream_overflow",
    "audio_replay_interrupted",
    "audio_timeline_overflow",
    "inference_backlog_exceeded",
    "audio_discontinuity",
    "inference_window_limit",
    "audio_chunk_invalid",
    "audio_missing",
    "transcript_limit_exceeded",
    "inference_cancelled",
    "inference_failed",
    "audio_hash_mismatch",
    "model_load_failed",
    "manifest_invalid",
}
RUN_RECORD_KEYS = {
    "schema_version",
    "language",
    "manifest_sha256",
    "model_sha256",
    "vad_sha256",
    "runtime_revision",
    "source_revision",
    "source_dirty",
    "model_load_seconds",
    "selected_count",
    "total_count",
    "completed_count",
    "failed_count",
    "stream_settings",
}
SELECTION_METHOD = "seeded-speaker-duration-round-robin-v1"
SELECTION_RECORD_KEYS = {
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
SELECTION_DURATION_TOLERANCE_SECONDS = 1e-6
MAX_AUDIO_DURATION_SECONDS = 90 * 60
STREAM_SETTING_INTEGER_KEYS = {
    "sample_rate_hz",
    "channel_count",
    "maximum_chunk_samples",
    "stream_buffer_capacity",
    "maximum_pending_samples",
    "window_samples",
    "inference_interval_samples",
    "finalization_lookback_samples",
    "finalization_context_overlap_samples",
    "thread_count",
    "vad_thread_count",
}
STREAM_SETTING_FLOAT_KEYS = {"source_decode_buffer_seconds"}
STREAM_SETTING_BOOLEAN_KEYS = {
    "replay_in_real_time",
    "translate",
    "no_timestamps",
    "detect_language",
    "vad",
    "use_gpu",
    "flash_attention",
}
STREAM_SETTING_STRING_KEYS = {"language", "whisper_sampling"}
STREAM_SETTING_KEYS = (
    STREAM_SETTING_INTEGER_KEYS
    | STREAM_SETTING_FLOAT_KEYS
    | STREAM_SETTING_BOOLEAN_KEYS
    | STREAM_SETTING_STRING_KEYS
)
NORMALIZER_SOURCE = "Loudness-ai/urdu-sukhan-asr"
NORMALIZER_REVISION = "ec6da1c4d82f165014d95152ac1931b6b115817a"
PUBLISHER_NORMALIZER_SHA256 = "9f1619436d53af792639ebce4a4c8a85e9315c8f36b85b4088eede83959c5571"
HEX_SHA256 = re.compile(r"[0-9a-f]{64}\Z")
GIT_REVISION = re.compile(r"[0-9a-f]{40}\Z")
TOKEN_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")
REPO_ROOT = Path(__file__).resolve().parents[4]


class ScoreError(Exception):
    """A validation failure whose message contains no private input data."""


@dataclass(frozen=True)
class ClipErrors:
    word_substitutions: int
    word_deletions: int
    word_insertions: int
    reference_words: int
    char_substitutions: int
    char_deletions: int
    char_insertions: int
    reference_characters: int


def _is_under(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def _private_file(value: str | Path, *, require_private: bool = True) -> Path:
    raw = Path(value).expanduser()
    try:
        if raw.is_symlink():
            raise ScoreError("symbolic-link inputs are not allowed")
        path = raw.resolve(strict=True)
        details = path.stat()
    except ScoreError:
        raise
    except Exception as exc:
        raise ScoreError("private input is unavailable") from exc
    if _is_under(path, REPO_ROOT):
        raise ScoreError("private benchmark inputs must be outside the repository")
    if not stat.S_ISREG(details.st_mode):
        raise ScoreError("private input has an unsupported file type")
    if require_private:
        file_is_private = stat.S_IMODE(details.st_mode) & 0o077 == 0
        try:
            parent_details = path.parent.stat()
            parent_is_private = (
                stat.S_ISDIR(parent_details.st_mode)
                and stat.S_IMODE(parent_details.st_mode) & 0o077 == 0
            )
        except Exception as exc:
            raise ScoreError("private input permissions could not be verified") from exc
        if not file_is_private and not parent_is_private:
            raise ScoreError("private input permissions are not restrictive")
    return path


def _new_private_directory(value: str | Path) -> Path:
    raw = Path(value).expanduser()
    if not raw.is_absolute():
        raise ScoreError("output must be an explicit absolute path")
    try:
        if raw.exists() or raw.is_symlink():
            raise ScoreError("output directory already exists")
        parent = raw.parent.resolve(strict=True)
        target = parent / raw.name
        if _is_under(target, REPO_ROOT):
            raise ScoreError("private reports must be outside the repository")
        os.mkdir(target, 0o700)
        os.chmod(target, 0o700)
    except ScoreError:
        raise
    except Exception as exc:
        raise ScoreError("could not create private report directory") from exc
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
        raise ScoreError("could not write private report") from exc


def _json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ScoreError("input row contains duplicate keys")
        result[key] = value
    return result


def _load_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    try:
        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                if not line.strip():
                    continue
                value = json.loads(line, object_pairs_hook=_json_object)
                if not isinstance(value, dict):
                    raise ScoreError("JSONL rows must be objects")
                rows.append(value)
    except ScoreError:
        raise
    except Exception as exc:
        raise ScoreError("private JSONL input is invalid") from exc
    if not rows:
        raise ScoreError("private JSONL input is empty")
    return rows


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(block)
    except Exception as exc:
        raise ScoreError("could not verify a private file") from exc
    return digest.hexdigest()


def _scorer_provenance() -> dict[str, str]:
    try:
        jiwer_version = importlib.metadata.version("jiwer")
    except Exception as exc:
        raise ScoreError("JiWER package version metadata is unavailable") from exc
    if jiwer_version != JIWER_VERSION:
        raise ScoreError("installed JiWER version does not match the pinned scorer version")
    python_version = ".".join(
        str(part) for part in (sys.version_info.major, sys.version_info.minor, sys.version_info.micro)
    )
    return {
        "script_sha256": _sha256_file(Path(__file__).resolve()),
        "jiwer_version": jiwer_version,
        "python_version": python_version,
    }


def _valid_hash(value: Any, *, label: str = "SHA-256") -> str:
    if not isinstance(value, str) or not HEX_SHA256.fullmatch(value):
        raise ScoreError(f"invalid {label}")
    return value


def _valid_token(value: Any, *, label: str = "label") -> str:
    if not isinstance(value, str) or not TOKEN_RE.fullmatch(value):
        raise ScoreError(f"invalid {label}")
    return value


def _finite(value: Any, *, nullable: bool = False, positive: bool = False) -> float | None:
    if value is None and nullable:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ScoreError("metric value is invalid")
    converted = float(value)
    if not math.isfinite(converted) or (converted <= 0 if positive else converted < 0):
        raise ScoreError("metric value is invalid")
    return converted


def _validate_manifest(rows: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], str, str, str, str]:
    allowed = {
        "schema_version",
        "id",
        "source_record_id",
        "language",
        "slice",
        "audio_path",
        "reference",
        "speaker_id",
        "speech_end_seconds",
        "duration_seconds",
        "audio_format",
        "sample_rate_hz",
        "channels",
        "audio_sha256",
        "source_audio_sha256",
        "source",
        "source_revision",
        "source_license",
        "source_duplicate_of",
        "source_metadata",
    }
    seen_ids: set[str] = set()
    seen_source_records: set[str] = set()
    language: str | None = None
    source: str | None = None
    revision: str | None = None
    license_label: str | None = None
    normalized_rows: list[dict[str, Any]] = []
    for row in rows:
        if set(row) - allowed or row.get("schema_version") != SCHEMA_VERSION:
            raise ScoreError("manifest schema is unsupported")
        identifier = _valid_token(row.get("id"), label="manifest identifier")
        source_record_id = _valid_token(row.get("source_record_id"), label="source record identifier")
        if identifier in seen_ids or source_record_id in seen_source_records:
            raise ScoreError("manifest contains duplicate records")
        seen_ids.add(identifier)
        seen_source_records.add(source_record_id)
        row_language = row.get("language")
        row_source = row.get("source")
        row_slice = row.get("slice")
        if row_language not in LANGUAGES or row_source not in SOURCES or row_slice not in SLICES:
            raise ScoreError("manifest labels are unsupported")
        row_revision = _valid_token(row.get("source_revision"), label="source revision")
        row_license = row.get("source_license")
        if row_license != LICENSES[row_source]:
            raise ScoreError("manifest license label does not match source")
        if language is None:
            language, source, revision, license_label = row_language, row_source, row_revision, row_license
        elif (row_language, row_source, row_revision, row_license) != (
            language,
            source,
            revision,
            license_label,
        ):
            raise ScoreError("manifest mixes language or source revisions")
        reference = row.get("reference")
        if not isinstance(reference, str) or "\x00" in reference:
            raise ScoreError("manifest reference is invalid")
        path_value = row.get("audio_path")
        if not isinstance(path_value, str) or not Path(path_value).is_absolute():
            raise ScoreError("manifest audio path is invalid")
        path = Path(path_value)
        try:
            audio_path = _private_file(path)
        except ScoreError:
            raise
        except Exception as exc:
            raise ScoreError("manifest audio is unavailable") from exc
        audio_hash = _valid_hash(row.get("audio_sha256"), label="audio SHA-256")
        if _sha256_file(audio_path) != audio_hash:
            raise ScoreError("prepared audio hash verification failed")
        source_hash = _valid_hash(row.get("source_audio_sha256"), label="source audio SHA-256")
        duration = _finite(row.get("duration_seconds"), positive=True)
        audio_format = row.get("audio_format")
        sample_rate = row.get("sample_rate_hz")
        channels = row.get("channels")
        if audio_format not in {"WAV", "FLAC"}:
            raise ScoreError("manifest audio format is unsupported")
        if (
            isinstance(sample_rate, bool)
            or not isinstance(sample_rate, int)
            or not 8000 <= sample_rate <= 192000
            or isinstance(channels, bool)
            or not isinstance(channels, int)
            or not 1 <= channels <= 8
        ):
            raise ScoreError("manifest audio header metadata is invalid")
        if duration > 600:
            raise ScoreError("manifest audio duration exceeds the supported bound")
        speech_end = _finite(row.get("speech_end_seconds"), nullable=True, positive=True)
        if speech_end is not None and (reference == "" or speech_end > duration):
            raise ScoreError("manifest speech endpoint exceeds duration")
        speaker_id = row.get("speaker_id")
        if speaker_id is not None:
            _valid_token(speaker_id, label="speaker identifier")
        source_duplicate_of = row.get("source_duplicate_of")
        if source_duplicate_of is not None:
            _valid_token(source_duplicate_of, label="duplicate source identifier")
        if "source_metadata" in row and not isinstance(row["source_metadata"], dict):
            raise ScoreError("manifest source metadata is invalid")
        normalized_rows.append(
            {
                **row,
                "audio_path": str(audio_path),
                "duration_seconds": duration,
                "audio_format": audio_format,
                "sample_rate_hz": sample_rate,
                "channels": channels,
                "speech_end_seconds": speech_end,
                "audio_sha256": audio_hash,
                "source_audio_sha256": source_hash,
            }
        )

    if not normalized_rows or language is None or source is None or revision is None or license_label is None:
        raise ScoreError("manifest contains no usable records")

    canonical_by_audio: dict[str, dict[str, Any]] = {}
    for row in normalized_rows:
        canonical = canonical_by_audio.get(row["audio_sha256"])
        duplicate_of = row.get("source_duplicate_of")
        if canonical is None:
            if duplicate_of is not None:
                raise ScoreError("manifest duplicate marker has no canonical record")
            canonical_by_audio[row["audio_sha256"]] = row
        else:
            if duplicate_of != canonical["id"]:
                raise ScoreError("manifest duplicate audio is not marked")
            if (
                row["reference"] != canonical["reference"]
                or row["language"] != canonical["language"]
                or row["slice"] != canonical["slice"]
            ):
                raise ScoreError("duplicate audio has conflicting source labels")

    for row in normalized_rows:
        duplicate_of = row.get("source_duplicate_of")
        if duplicate_of is not None:
            canonical = next((item for item in normalized_rows if item["id"] == duplicate_of), None)
            if canonical is None or canonical.get("source_duplicate_of") is not None:
                raise ScoreError("manifest duplicate link is invalid")

    return normalized_rows, language, source, revision, license_label


def _validate_results(
    rows: list[dict[str, Any]], manifest: list[dict[str, Any]]
) -> dict[str, dict[str, Any]]:
    allowed = {
        "schema_version",
        "id",
        "language",
        "slice",
        "status",
        "hypothesis",
        "duration_seconds",
        "first_partial_seconds",
        "stop_to_final_seconds",
        "speech_end_to_final_seconds",
        "inference_seconds",
        "inference_calls",
        "error_code",
    }
    expected = {row["id"]: row for row in manifest}
    by_id: dict[str, dict[str, Any]] = {}
    for row in rows:
        if set(row) - allowed or row.get("schema_version") != SCHEMA_VERSION:
            raise ScoreError("result schema is unsupported")
        identifier = _valid_token(row.get("id"), label="result identifier")
        if identifier in by_id:
            raise ScoreError("results contain duplicate identifiers")
        if identifier not in expected:
            raise ScoreError("results contain unknown identifiers")
        manifest_row = expected[identifier]
        if row.get("language") != manifest_row["language"] or row.get("slice") != manifest_row["slice"]:
            raise ScoreError("result metadata does not match manifest")
        status = row.get("status")
        if status not in {"ok", "failed"}:
            raise ScoreError("result status is invalid")
        hypothesis = row.get("hypothesis")
        if not isinstance(hypothesis, str) or "\x00" in hypothesis:
            raise ScoreError("result hypothesis is invalid")
        duration = _finite(row.get("duration_seconds"), positive=status == "ok")
        if duration > 0 and abs(duration - manifest_row["duration_seconds"]) > 0.05:
            raise ScoreError("result duration does not match manifest")
        timing = {
            key: _finite(row.get(key), nullable=True)
            for key in (
                "first_partial_seconds",
                "stop_to_final_seconds",
                "speech_end_to_final_seconds",
            )
        }
        inference_seconds = _finite(row.get("inference_seconds"))
        calls = row.get("inference_calls")
        if isinstance(calls, bool) or not isinstance(calls, int) or calls < 0:
            raise ScoreError("inference call count is invalid")
        error_code = row.get("error_code")
        if error_code is not None and error_code not in FAILURE_CODES:
            raise ScoreError("failure code is not allowlisted")
        if status == "ok" and error_code is not None:
            raise ScoreError("successful result has a failure code")
        if status == "failed" and error_code is None:
            raise ScoreError("failed results require an allowlisted failure code")
        if status == "failed" and hypothesis:
            raise ScoreError("failed results must not contain hypotheses")
        if status == "failed" and any(value is not None for value in timing.values()):
            raise ScoreError("failed results must not contain endpoint latencies")
        by_id[identifier] = {
            **row,
            "duration_seconds": duration,
            "inference_seconds": inference_seconds,
            "inference_calls": calls,
            **timing,
        }
    if set(by_id) != set(expected):
        raise ScoreError("results do not cover every manifest record")
    return by_id


def _minimal_normalize(text: str, language: str) -> str:
    text = unicodedata.normalize("NFC", text)
    if language == "en":
        text = text.casefold()
        text = "".join(" " if unicodedata.category(char).startswith("P") else char for char in text)
    return " ".join(text.split())


def _load_normalizer(path_value: str | None, expected_hash: str | None) -> tuple[Callable[[str, str], str] | None, str | None]:
    if path_value is None:
        if expected_hash is not None:
            raise ScoreError("normalizer hash requires a normalizer file")
        return None, None
    if expected_hash is None or not HEX_SHA256.fullmatch(expected_hash):
        raise ScoreError("a valid normalizer SHA-256 is required")
    path = _private_file(path_value, require_private=False)
    digest = _sha256_file(path)
    if digest != expected_hash:
        raise ScoreError("normalizer SHA-256 does not match")
    if digest != PUBLISHER_NORMALIZER_SHA256:
        raise ScoreError("only the reviewed publisher normalizer is supported")
    try:
        spec = importlib.util.spec_from_file_location("speech_benchmark_publisher_normalizer", path)
        if spec is None or spec.loader is None:
            raise ScoreError("normalizer module is invalid")
        module = importlib.util.module_from_spec(spec)
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            spec.loader.exec_module(module)
        function = getattr(module, "normalize_for_eval", None)
        if not callable(function):
            raise ScoreError("normalizer API is invalid")
    except ScoreError:
        raise
    except Exception as exc:
        raise ScoreError("normalizer could not be loaded") from exc

    def normalize(text: str, language: str) -> str:
        try:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                value = function(text, language)
        except Exception as exc:
            raise ScoreError("normalizer failed") from exc
        if not isinstance(value, str) or "\x00" in value:
            raise ScoreError("normalizer returned an invalid value")
        return value

    return normalize, digest


def _normalize(text: str, language: str, publisher: Callable[[str, str], str] | None) -> str:
    if language == "ur" and publisher is not None:
        return publisher(text, "ur")
    return _minimal_normalize(text, language)


def _without_whitespace(text: str) -> str:
    return "".join(text.split())


def _clip_errors(
    reference: str,
    hypothesis: str,
    jiwer: Any,
    *,
    preserve_character_whitespace: bool = False,
) -> ClipErrors:
    word = jiwer.process_words([reference], [hypothesis])
    if preserve_character_whitespace:
        character_transform = jiwer.Compose([jiwer.ReduceToListOfListOfChars()])
        char = jiwer.process_characters(
            [reference],
            [hypothesis],
            reference_transform=character_transform,
            hypothesis_transform=character_transform,
        )
    else:
        ref_characters = _without_whitespace(reference)
        hyp_characters = _without_whitespace(hypothesis)
        char = jiwer.process_characters([ref_characters], [hyp_characters])
    return ClipErrors(
        word_substitutions=int(word.substitutions),
        word_deletions=int(word.deletions),
        word_insertions=int(word.insertions),
        reference_words=sum(len(value) for value in word.references),
        char_substitutions=int(char.substitutions),
        char_deletions=int(char.deletions),
        char_insertions=int(char.insertions),
        reference_characters=sum(len(value) for value in char.references),
    )


def _quantile(values: list[float], probability: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * probability
    lower = int(math.floor(position))
    upper = int(math.ceil(position))
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def _bootstrap_ci(
    clips: list[ClipErrors], *, metric: str, samples: int, seed: int
) -> dict[str, float] | None:
    if not clips:
        return None
    rng = random.Random(seed)
    values: list[float] = []
    for _ in range(samples):
        selected = [clips[rng.randrange(len(clips))] for _ in clips]
        if metric == "wer":
            errors = sum(c.word_substitutions + c.word_deletions + c.word_insertions for c in selected)
            denominator = sum(c.reference_words for c in selected)
        else:
            errors = sum(c.char_substitutions + c.char_deletions + c.char_insertions for c in selected)
            denominator = sum(c.reference_characters for c in selected)
        if denominator:
            values.append(errors / denominator)
    if not values:
        return None
    return {"lower": _quantile(values, 0.025), "upper": _quantile(values, 0.975)}  # type: ignore[dict-item]


def _metric_summary(clips: list[ClipErrors], metric: str, samples: int, seed: int) -> dict[str, Any] | None:
    if not clips:
        return None
    if metric == "wer":
        substitutions = sum(c.word_substitutions for c in clips)
        deletions = sum(c.word_deletions for c in clips)
        insertions = sum(c.word_insertions for c in clips)
        units = sum(c.reference_words for c in clips)
    else:
        substitutions = sum(c.char_substitutions for c in clips)
        deletions = sum(c.char_deletions for c in clips)
        insertions = sum(c.char_insertions for c in clips)
        units = sum(c.reference_characters for c in clips)
    if units == 0:
        return None
    return {
        "value": (substitutions + deletions + insertions) / units,
        "confidence_interval_95": _bootstrap_ci(clips, metric=metric, samples=samples, seed=seed),
        "substitutions": substitutions,
        "deletions": deletions,
        "insertions": insertions,
        "reference_units": units,
    }


def _stable_seed(seed: int, language: str, slice_name: str, metric: str) -> int:
    material = f"{seed}:{language}:{slice_name}:{metric}".encode("ascii")
    return int.from_bytes(hashlib.sha256(material).digest()[:8], "big")


def _distribution_summary(values: list[float]) -> dict[str, Any]:
    return {
        "sample_count": len(values),
        "p50": _quantile(values, 0.50),
        "minimum": min(values) if values else None,
        "maximum": max(values) if values else None,
    }


def _timing_summary(rows: list[dict[str, Any]]) -> dict[str, Any]:
    valid = [row for row in rows if row["status"] == "ok"]
    fields = (
        "first_partial_seconds",
        "stop_to_final_seconds",
    )
    summary: dict[str, Any] = {}
    for field in fields:
        values = [row[field] for row in valid if row[field] is not None]
        summary[field] = {
            **_distribution_summary(values),
            "unmeasured_count": len(rows) - len(values),
        }
    rtf = [row["inference_seconds"] / row["duration_seconds"] for row in valid]
    summary["real_time_factor"] = {
        **_distribution_summary(rtf),
        "unmeasured_count": len(rows) - len(rtf),
    }
    summary["inference_calls"] = sum(row["inference_calls"] for row in valid)
    return summary


def _summarize_group(
    *,
    manifest_rows: list[dict[str, Any]],
    results: dict[str, dict[str, Any]],
    normalized: dict[str, tuple[str, str]],
    jiwer: Any,
    bootstrap_samples: int,
    seed: int,
    language: str,
    slice_name: str,
) -> dict[str, Any]:
    ids = {row["id"] for row in manifest_rows}
    metric_rows = [row for row in manifest_rows if row.get("source_duplicate_of") is None]
    result_rows = [results[row["id"]] for row in metric_rows]
    speaker_ids = {row["speaker_id"] for row in metric_rows if row.get("speaker_id") is not None}
    speaker_id_missing = sum(row.get("speaker_id") is None for row in metric_rows)
    speech = [row for row in metric_rows if row["reference"] != ""]
    silence = [row for row in metric_rows if row["reference"] == ""]
    clip_scores: list[ClipErrors] = []
    raw_clip_scores: list[ClipErrors] = []
    failed_speech = 0
    for row in speech:
        result = results[row["id"]]
        ref, hyp = normalized[row["id"]]
        raw_hypothesis = result["hypothesis"]
        if not ref:
            raise ScoreError("non-silence reference normalized to empty text")
        if result["status"] == "failed":
            failed_speech += 1
            hyp = ""
            raw_hypothesis = ""
        clip_scores.append(_clip_errors(ref, hyp, jiwer))
        raw_clip_scores.append(
            _clip_errors(
                row["reference"],
                raw_hypothesis,
                jiwer,
                preserve_character_whitespace=True,
            )
        )
    false_text = 0
    silent_success = 0
    silence_failures = 0
    for row in silence:
        result = results[row["id"]]
        has_text = bool(result["hypothesis"].strip())
        if has_text:
            false_text += 1
        if result["status"] == "failed":
            silence_failures += 1
        elif not has_text:
            silent_success += 1

    duplicate_rows = [row for row in manifest_rows if row.get("source_duplicate_of") is not None]
    duplicate_failures = sum(results[row["id"]]["status"] == "failed" for row in duplicate_rows)
    word_metric = _metric_summary(
        clip_scores,
        "wer",
        bootstrap_samples,
        _stable_seed(seed, language, slice_name, "wer"),
    )
    char_metric = _metric_summary(
        clip_scores,
        "cer",
        bootstrap_samples,
        _stable_seed(seed, language, slice_name, "cer"),
    )
    raw_word_metric = _metric_summary(
        raw_clip_scores,
        "wer",
        bootstrap_samples,
        _stable_seed(seed, language, slice_name, "raw_wer"),
    )
    raw_char_metric = _metric_summary(
        raw_clip_scores,
        "cer",
        bootstrap_samples,
        _stable_seed(seed, language, slice_name, "raw_cer"),
    )
    return {
        "slice": slice_name,
        "source_record_count": len(ids),
        "duplicate_record_count": len(duplicate_rows),
        "sample_count": len(metric_rows),
        "speaker_count": len(speaker_ids) if speaker_id_missing == 0 else None,
        "speaker_id_status": "complete" if speaker_id_missing == 0 else "unknown" if not speaker_ids else "partial",
        "speaker_id_known_clip_count": len(metric_rows) - speaker_id_missing,
        "speaker_id_missing_clip_count": speaker_id_missing,
        "speech_clip_count": len(speech),
        "failed_speech_count": failed_speech,
        "normalized_word_error_rate": word_metric,
        "word_error_rate": word_metric,
        "normalized_character_error_rate_without_whitespace": char_metric,
        "raw_word_error_rate": raw_word_metric,
        "raw_character_error_rate_with_whitespace": raw_char_metric,
        "silence_clip_count": len(silence),
        "silence_false_text_count": false_text,
        "silence_false_text_rate": false_text / len(silence) if silence else None,
        "silence_no_text_success_count": silent_success,
        "silence_failed_count": silence_failures,
        "failed_duplicate_record_count": duplicate_failures,
        "timing": _timing_summary(result_rows),
    }


def _validate_run_record(
    path: Path,
    *,
    manifest_path: Path,
    manifest_rows: list[dict[str, Any]],
    results: dict[str, dict[str, Any]],
    language: str,
) -> dict[str, Any]:
    value = _load_json(path)
    if not RUN_RECORD_KEYS.issubset(value) or value.get("schema_version") != SCHEMA_VERSION:
        raise ScoreError("run record schema is unsupported")
    if value.get("language") != language:
        raise ScoreError("run record language does not match manifest")
    manifest_hash = _valid_hash(value.get("manifest_sha256"), label="manifest SHA-256")
    if _sha256_file(manifest_path) != manifest_hash:
        raise ScoreError("run record manifest hash does not match")
    model_hash = _valid_hash(value.get("model_sha256"), label="model SHA-256")
    vad_hash = _valid_hash(value.get("vad_sha256"), label="VAD SHA-256")
    runtime_hash = value.get("runtime_sha256")
    source_hash = value.get("source_sha256")
    if runtime_hash is not None:
        runtime_hash = _valid_hash(runtime_hash, label="runtime SHA-256")
    if source_hash is not None:
        source_hash = _valid_hash(source_hash, label="source SHA-256")
    runtime_revision = value.get("runtime_revision")
    code_revision = value.get("source_revision")
    if not isinstance(runtime_revision, str) or not GIT_REVISION.fullmatch(runtime_revision):
        raise ScoreError("runtime revision is invalid")
    if not isinstance(code_revision, str) or not GIT_REVISION.fullmatch(code_revision):
        raise ScoreError("source revision is invalid")
    source_dirty = value.get("source_dirty")
    if not isinstance(source_dirty, bool):
        raise ScoreError("source dirty state is invalid")
    model_load_seconds = _finite(value.get("model_load_seconds"), nullable=True)
    counts: dict[str, int] = {}
    for key in ("selected_count", "total_count", "completed_count", "failed_count"):
        item = value.get(key)
        if isinstance(item, bool) or not isinstance(item, int) or item < 0:
            raise ScoreError("run record count is invalid")
        counts[key] = item
    if (
        counts["selected_count"] != len(manifest_rows)
        or counts["selected_count"] != len(results)
        or counts["selected_count"] > counts["total_count"]
        or counts["completed_count"] + counts["failed_count"] != counts["selected_count"]
    ):
        raise ScoreError("run record counts are inconsistent")
    status_counts = {
        "completed_count": sum(result["status"] == "ok" for result in results.values()),
        "failed_count": sum(result["status"] == "failed" for result in results.values()),
    }
    if any(counts[key] != status_counts[key] for key in status_counts):
        raise ScoreError("run record completion counts do not match results")
    stream_settings = value.get("stream_settings")
    if not isinstance(stream_settings, dict) or set(stream_settings) - STREAM_SETTING_KEYS:
        raise ScoreError("run record stream settings are not allowlisted")
    if not {"language", "sample_rate_hz", "channel_count"}.issubset(stream_settings):
        raise ScoreError("run record stream settings are incomplete")
    clean_settings: dict[str, Any] = {}
    for key, item in stream_settings.items():
        if key in STREAM_SETTING_INTEGER_KEYS:
            if isinstance(item, bool) or not isinstance(item, int):
                raise ScoreError("run record stream setting is invalid")
            minimum = 0 if key == "finalization_context_overlap_samples" else 1
            maximum = 1024 if key in {"thread_count", "vad_thread_count"} else 1_000_000_000
            if not minimum <= item <= maximum:
                raise ScoreError("run record stream setting is invalid")
        elif key in STREAM_SETTING_FLOAT_KEYS:
            if isinstance(item, bool) or not isinstance(item, (int, float)):
                raise ScoreError("run record stream setting is invalid")
            if not math.isfinite(float(item)) or not 0 <= float(item) <= 600:
                raise ScoreError("run record stream setting is invalid")
        elif key in STREAM_SETTING_BOOLEAN_KEYS:
            if not isinstance(item, bool):
                raise ScoreError("run record stream setting is invalid")
        elif key == "language":
            if item not in LANGUAGES or item != language:
                raise ScoreError("run record stream language does not match")
        elif key == "whisper_sampling":
            if item != "greedy":
                raise ScoreError("run record sampling mode is unsupported")
        clean_settings[key] = item
    if clean_settings["sample_rate_hz"] != 16000 or clean_settings["channel_count"] != 1:
        raise ScoreError("run record audio settings do not match benchmark input")
    return {
        "schema_version": SCHEMA_VERSION,
        "language": language,
        "manifest_sha256": manifest_hash,
        "model_sha256": model_hash,
        "vad_sha256": vad_hash,
        "runtime_revision": runtime_revision,
        "runtime_sha256": runtime_hash,
        "source_revision": code_revision,
        "source_sha256": source_hash,
        "source_dirty": source_dirty,
        "model_load_seconds": model_load_seconds,
        **counts,
        "stream_settings": clean_settings,
    }


def _validate_selection_record(
    path: Path,
    *,
    manifest_path: Path,
    manifest_rows: list[dict[str, Any]],
    language: str,
    source: str,
    source_revision: str,
) -> dict[str, Any]:
    value = _load_json(path)
    if set(value) != SELECTION_RECORD_KEYS:
        raise ScoreError("selection record fields are unsupported")
    if type(value.get("schema_version")) is not int or value["schema_version"] != SCHEMA_VERSION:
        raise ScoreError("selection record schema is unsupported")
    if value.get("method") != SELECTION_METHOD:
        raise ScoreError("selection method is unsupported")
    seed = value.get("seed")
    if isinstance(seed, bool) or not isinstance(seed, int) or not 0 <= seed <= 2**63 - 1:
        raise ScoreError("selection seed is invalid")
    source_manifest_hash = _valid_hash(
        value.get("source_manifest_sha256"), label="source manifest SHA-256"
    )
    selected_manifest_hash = _valid_hash(
        value.get("selected_manifest_sha256"), label="selected manifest SHA-256"
    )
    if _sha256_file(manifest_path) != selected_manifest_hash:
        raise ScoreError("selection manifest hash does not match")

    counts: dict[str, int] = {}
    for key in ("source_count", "eligible_unique_count", "selected_count"):
        count = value.get(key)
        if isinstance(count, bool) or not isinstance(count, int) or count < 1:
            raise ScoreError("selection count is invalid")
        counts[key] = count
    if not counts["source_count"] >= counts["eligible_unique_count"] >= counts["selected_count"]:
        raise ScoreError("selection counts are inconsistent")
    if counts["selected_count"] != len(manifest_rows):
        raise ScoreError("selection count does not match manifest")

    source_duration = _finite(value.get("source_duration_seconds"), positive=True)
    selected_duration = _finite(value.get("selected_duration_seconds"), positive=True)
    budget = _finite(value.get("budget_seconds"), positive=True)
    manifest_duration = sum(row["duration_seconds"] for row in manifest_rows)
    if abs(selected_duration - manifest_duration) > SELECTION_DURATION_TOLERANCE_SECONDS:
        raise ScoreError("selection duration does not match manifest")
    if selected_duration > budget or selected_duration > source_duration:
        raise ScoreError("selection duration exceeds its source or budget")

    row_language = value.get("language")
    row_source = value.get("source")
    if (
        not isinstance(row_language, str)
        or row_language not in LANGUAGES
        or row_language != language
        or not isinstance(row_source, str)
        or row_source not in SOURCES
        or row_source != source
    ):
        raise ScoreError("selection labels do not match manifest")
    revision = _valid_token(value.get("source_revision"), label="selection source revision")
    if revision != source_revision:
        raise ScoreError("selection revision does not match manifest")

    return {
        "schema_version": SCHEMA_VERSION,
        "method": SELECTION_METHOD,
        "seed": seed,
        "source_manifest_sha256": source_manifest_hash,
        "selected_manifest_sha256": selected_manifest_hash,
        **counts,
        "source_duration_seconds": source_duration,
        "selected_duration_seconds": selected_duration,
        "budget_seconds": budget,
        "language": language,
        "source": source,
        "source_revision": revision,
    }


def _load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_json_object)
    except ScoreError:
        raise
    except Exception as exc:
        raise ScoreError("private JSON input is invalid") from exc
    if not isinstance(value, dict):
        raise ScoreError("private JSON input must be an object")
    return value


def _report_markdown(aggregate: dict[str, Any]) -> str:
    source = aggregate["source"]
    lines = [
        "# Speech Benchmark Aggregate Report",
        "",
        f"- Source: `{source}` ({aggregate['source_license']})",
        f"- Source revision: `{aggregate['source_revision']}`",
        f"- Language: `{aggregate['language']}`",
        f"- Normalization: {aggregate['normalization']['description']}",
        f"- Publisher comparable: `{str(aggregate['normalization']['publisher_comparable']).lower()}`",
        f"- Reference policy: {aggregate['reference_policy']}",
        f"- Unique clips scored: {aggregate['sample_count']}",
        f"- Duplicate source records excluded from metric denominators: {aggregate['duplicate_record_count']}",
        f"- Bootstrap limitation: {aggregate['bootstrap']['limitations']}",
        f"- Runner scope: {aggregate['runner_scope']}",
        "- Installed-app memory, energy, and live-microphone measurements: not measured by this report.",
        "- This aggregate is tooling evidence only; it makes no acceptance claim.",
        "",
    ]
    selection = aggregate["selection_provenance"]
    lines.extend(["## Selection Coverage", ""])
    if selection is None:
        lines.append("Population coverage: unknown (no selection record supplied).")
    else:
        lines.extend(
            [
                "Population coverage: selection record supplied.",
                f"- Method: `{selection['method']}`",
                f"- Seed: `{selection['seed']}`",
                f"- Source / eligible unique / selected records: {selection['source_count']} / "
                f"{selection['eligible_unique_count']} / {selection['selected_count']}",
                f"- Source / selected / budget duration seconds: "
                f"{_format_number(selection['source_duration_seconds'])} / "
                f"{_format_number(selection['selected_duration_seconds'])} / "
                f"{_format_number(selection['budget_seconds'])}",
            ]
        )
    lines.append("")
    lines.extend(
        [
            "## Aggregate Scores",
            "",
            aggregate["raw_metric_policy"],
            "",
            "| Slice | Clips | Speakers | Failed speech | Normalized WER (95% CI) | Raw WER (95% CI) | "
            "Normalized CER, no whitespace (95% CI) | Raw CER, whitespace preserved (95% CI) | Silence false text |",
            "| --- | ---: | ---: | ---: | --- | --- | --- | --- | ---: |",
        ]
    )
    for group in aggregate["groups"]:
        wer = group["word_error_rate"]
        cer = group["normalized_character_error_rate_without_whitespace"]
        raw_wer = group["raw_word_error_rate"]
        raw_cer = group["raw_character_error_rate_with_whitespace"]
        wer_text = _format_metric(wer)
        cer_text = _format_metric(cer)
        raw_wer_text = _format_metric(raw_wer)
        raw_cer_text = _format_metric(raw_cer)
        speakers = (
            f"unknown ({group['speaker_id_missing_clip_count']} clip IDs missing)"
            if group["speaker_count"] is None
            else str(group["speaker_count"])
        )
        silence_rate = group["silence_false_text_rate"]
        silence_text = "unmeasured" if silence_rate is None else f"{group['silence_false_text_count']} ({silence_rate:.2%})"
        lines.append(
            f"| {group['slice']} | {group['sample_count']} | {speakers} | "
            f"{group['failed_speech_count']} | {wer_text} | {raw_wer_text} | {cer_text} | "
            f"{raw_cer_text} | {silence_text} |"
        )
    lines.extend(["", "## Timing", "", "Timing summaries use successful result rows with finite measurements; null endpoints remain unmeasured.", ""])
    for group in aggregate["groups"]:
        timing = group["timing"]
        lines.append(f"### {group['slice']}")
        lines.append("")
        lines.append("| Measure | Samples | p50 seconds | Range seconds | Unmeasured |")
        lines.append("| --- | ---: | ---: | ---: | ---: |")
        for key, label in (
            ("first_partial_seconds", "First partial"),
            ("stop_to_final_seconds", "Stop to final"),
        ):
            metric = timing[key]
            value_range = (
                "unmeasured"
                if metric["minimum"] is None
                else f"{_format_number(metric['minimum'])}–{_format_number(metric['maximum'])}"
            )
            lines.append(
                f"| {label} | {metric['sample_count']} | {_format_number(metric['p50'])} | "
                f"{value_range} | {metric['unmeasured_count']} |"
            )
        rtf = timing["real_time_factor"]
        rtf_range = (
            "unmeasured"
            if rtf["minimum"] is None
            else f"{_format_number(rtf['minimum'])}–{_format_number(rtf['maximum'])}"
        )
        lines.append(
            f"| Real-time factor | {rtf['sample_count']} | {_format_number(rtf['p50'])} | "
            f"{rtf_range} | {rtf['unmeasured_count']} |"
        )
        lines.append("")
    scorer = aggregate["scorer"]
    lines.extend(
        [
            "## Scorer Provenance",
            "",
            f"- JiWER version: `{scorer['jiwer_version']}`",
            f"- Python version: `{scorer['python_version']}`",
            "",
        ]
    )
    run_record = aggregate["run_record"]
    lines.extend(["## Runner Provenance", ""])
    if run_record is None:
        lines.append("No run record was supplied; model, VAD, runtime, and source-code revisions are unavailable.")
    else:
        lines.extend(
            [
                f"- Runtime revision: `{run_record['runtime_revision']}`",
                f"- Selected / total records: {run_record['selected_count']} / {run_record['total_count']}",
            ]
        )
    lines.append("")
    return "\n".join(lines)


def _format_number(value: float | int | None) -> str:
    return "unmeasured" if value is None else f"{value:.4f}"


def _format_metric(value: dict[str, Any] | None) -> str:
    if value is None:
        return "unmeasured"
    interval = value["confidence_interval_95"]
    if interval is None:
        return f"{value['value']:.4f} (CI unmeasured)"
    return f"{value['value']:.4f} ({interval['lower']:.4f}–{interval['upper']:.4f})"


def score(
    *,
    manifest_value: str,
    results_value: str,
    output_value: str,
    normalizer_value: str | None = None,
    normalizer_sha256: str | None = None,
    run_record_value: str | None = None,
    selection_record_value: str | None = None,
    bootstrap_samples: int = 2000,
    seed: int = 0,
) -> dict[str, Any]:
    try:
        import jiwer
    except ImportError as exc:
        raise ScoreError("pinned JiWER is required") from exc
    scorer_provenance = _scorer_provenance()
    if bootstrap_samples < 1 or bootstrap_samples > 100000:
        raise ScoreError("bootstrap sample count is out of range")
    if seed < 0 or seed > 2**63 - 1:
        raise ScoreError("bootstrap seed is out of range")
    manifest_path = _private_file(manifest_value)
    results_path = _private_file(results_value)
    manifest_rows_raw = _load_jsonl(manifest_path)
    result_rows_raw = _load_jsonl(results_path)
    manifest_rows, language, source, source_revision, source_license = _validate_manifest(manifest_rows_raw)
    total_audio_seconds = math.fsum(row["duration_seconds"] for row in manifest_rows)
    if total_audio_seconds > MAX_AUDIO_DURATION_SECONDS:
        raise ScoreError("total audio duration exceeds the 90-minute phase limit")
    if normalizer_value is not None and language != "ur":
        raise ScoreError("publisher normalizer is only valid for Urdu scoring")
    publisher_normalizer, normalizer_digest = _load_normalizer(normalizer_value, normalizer_sha256)
    results = _validate_results(result_rows_raw, manifest_rows)
    run_record_path: Path | None = None
    if run_record_value is not None:
        run_record_path = _private_file(run_record_value)
    else:
        sibling = results_path.parent / "run.json"
        if sibling.exists() or sibling.is_symlink():
            run_record_path = _private_file(sibling)
    run_record = None
    if run_record_path is not None:
        run_record = _validate_run_record(
            run_record_path,
            manifest_path=manifest_path,
            manifest_rows=manifest_rows,
            results=results,
            language=language,
        )
    selection_record = None
    if selection_record_value is not None:
        selection_record_path = _private_file(selection_record_value)
        selection_record = _validate_selection_record(
            selection_record_path,
            manifest_path=manifest_path,
            manifest_rows=manifest_rows,
            language=language,
            source=source,
            source_revision=source_revision,
        )

    normalized: dict[str, tuple[str, str]] = {}
    for row in manifest_rows:
        result = results[row["id"]]
        try:
            reference = _normalize(row["reference"], language, publisher_normalizer)
            hypothesis = _normalize(result["hypothesis"], language, publisher_normalizer)
        except ScoreError:
            raise
        except Exception as exc:
            raise ScoreError("normalization failed") from exc
        if row["reference"] != "" and not reference:
            raise ScoreError("non-silence reference normalized to empty text")
        normalized[row["id"]] = (reference, hypothesis)

    unique_rows = [row for row in manifest_rows if row.get("source_duplicate_of") is None]
    groups: list[dict[str, Any]] = []
    group_specs = [("all", manifest_rows)]
    for slice_name in sorted({row["slice"] for row in manifest_rows}):
        group_specs.append((slice_name, [row for row in manifest_rows if row["slice"] == slice_name]))
    for slice_name, group_rows in group_specs:
        groups.append(
            _summarize_group(
                manifest_rows=group_rows,
                results=results,
                normalized=normalized,
                jiwer=jiwer,
                bootstrap_samples=bootstrap_samples,
                seed=seed,
                language=language,
                slice_name=slice_name,
            )
        )
    duplicate_count = sum(row.get("source_duplicate_of") is not None for row in manifest_rows)
    publisher_comparable = language == "ur" and normalizer_digest == PUBLISHER_NORMALIZER_SHA256
    if publisher_comparable:
        normalization_description = (
            f"verified publisher normalizer normalize_for_eval at {NORMALIZER_SOURCE}@{NORMALIZER_REVISION}; "
            "CER removes whitespace before JiWER"
        )
    elif publisher_normalizer is not None:
        normalization_description = "external user-pinned normalizer; CER removes whitespace before JiWER"
    else:
        normalization_description = (
            "minimal Unicode NFC; English case-folding and punctuation separation; CER removes whitespace"
        )
    aggregate = {
        "schema_version": SCHEMA_VERSION,
        "source": source,
        "source_revision": source_revision,
        "source_license": source_license,
        "language": language,
        "sample_count": len(unique_rows),
        "source_record_count": len(manifest_rows),
        "duplicate_record_count": duplicate_count,
        "normalization": {
            "description": normalization_description,
            "publisher_comparable": publisher_comparable,
            "normalizer_sha256": normalizer_digest,
        },
        "raw_metric_policy": (
            "Raw WER uses the supplied reference and hypothesis with JiWER word tokenization; raw CER "
            "uses the original characters including all whitespace."
        ),
        "reference_policy": (
            "Reference text is preserved verbatim in the private manifest; metrics apply the declared normalization. "
            "The FLEURS transcription column may already be normalized, so original punctuation fidelity is not claimed."
            if source == "fleurs"
            else "Reference text is preserved verbatim in the private manifest; metrics apply the declared normalization."
        ),
        "bootstrap": {
            "samples": bootstrap_samples,
            "seed": seed,
            "confidence": 0.95,
            "unit": "clip",
            "limitations": "Repeated prompts and unknown speaker clustering can make clip-resampled intervals optimistic.",
        },
        "groups": groups,
        "run_record": run_record,
        "selection_provenance": selection_record,
        "population_coverage_status": "selection_recorded" if selection_record is not None else "unknown",
        "scorer": scorer_provenance,
        "runner_scope": "production-recognizer-replay; not installed-app resource or live-microphone measurement",
        "acceptance_claim": False,
    }
    output = _new_private_directory(output_value)
    try:
        _write_private(
            output / "aggregate.json",
            (json.dumps(aggregate, ensure_ascii=False, indent=2) + "\n").encode("utf-8"),
        )
        _write_private(output / "report.md", _report_markdown(aggregate).encode("utf-8"))
    except Exception:
        import shutil

        shutil.rmtree(output, ignore_errors=True)
        raise
    return aggregate


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, help="private schema-v1 manifest JSONL")
    parser.add_argument("--results", required=True, help="private schema-v1 native results JSONL")
    parser.add_argument("--output", required=True, help="new private aggregate output directory")
    parser.add_argument("--normalizer", help="external publisher normalizer Python source")
    parser.add_argument("--normalizer-sha256", help="required SHA-256 for the supplied normalizer")
    parser.add_argument("--run-record", help="optional private native run.json provenance file")
    parser.add_argument("--selection-record", help="optional private selection.json provenance file")
    parser.add_argument("--bootstrap-samples", type=int, default=2000)
    parser.add_argument("--seed", type=int, default=0)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    try:
        aggregate = score(
            manifest_value=args.manifest,
            results_value=args.results,
            output_value=args.output,
            normalizer_value=args.normalizer,
            normalizer_sha256=args.normalizer_sha256,
            run_record_value=args.run_record,
            selection_record_value=args.selection_record,
            bootstrap_samples=args.bootstrap_samples,
            seed=args.seed,
        )
        print(f"Scored {aggregate['sample_count']} unique clips. Aggregate report is private.")
        return 0
    except Exception:
        print("Scoring failed; private input details were withheld.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
