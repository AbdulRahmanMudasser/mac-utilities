#!/usr/bin/env python3
"""Create a private, deterministic, duration-bounded sample from a prepared manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import random
import re
import stat
import sys
from collections import defaultdict, deque
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1
METHOD = "seeded-speaker-duration-round-robin-v1"
MAX_MANIFEST_BYTES = 64 * 1024 * 1024
MAX_AUDIO_DURATION_SECONDS = 90 * 60
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
TOKEN_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")
SHA256_RE = re.compile(r"[0-9a-f]{64}\Z")
REPO_ROOT = Path(__file__).resolve().parents[4]
REQUIRED_FIELDS = {
    "schema_version",
    "id",
    "source_record_id",
    "language",
    "slice",
    "audio_path",
    "reference",
    "duration_seconds",
    "audio_format",
    "sample_rate_hz",
    "channels",
    "audio_sha256",
    "source_audio_sha256",
    "source",
    "source_revision",
    "source_license",
}
ALLOWED_FIELDS = REQUIRED_FIELDS | {
    "speaker_id",
    "speech_end_seconds",
    "source_duplicate_of",
    "source_metadata",
}


class SampleError(Exception):
    """A safe sampling error with a stable code and no private input details."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def _is_under(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def _json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise SampleError("manifest_invalid", "manifest contains duplicate JSON keys")
        value[key] = item
    return value


def _reject_json_constant(_: str) -> None:
    raise SampleError("manifest_invalid", "manifest contains a non-finite JSON value")


def _private_manifest(value: str | Path) -> tuple[Path, bytes]:
    raw = Path(value).expanduser()
    try:
        if raw.is_symlink():
            raise SampleError("manifest_invalid", "symbolic-link manifest is not allowed")
        path = raw.resolve(strict=True)
        details = path.stat()
        if _is_under(path, REPO_ROOT):
            raise SampleError("manifest_invalid", "private manifest must be outside the repository")
        if not stat.S_ISREG(details.st_mode):
            raise SampleError("manifest_invalid", "manifest must be a regular file")
        if details.st_size > MAX_MANIFEST_BYTES:
            raise SampleError("manifest_too_large", "manifest exceeds the 64 MiB size limit")
        if stat.S_IMODE(details.st_mode) & 0o077:
            raise SampleError("manifest_invalid", "manifest permissions must be private")
        return path, path.read_bytes()
    except SampleError:
        raise
    except Exception as exc:
        raise SampleError("manifest_invalid", "private manifest is unavailable") from exc


def _load_rows(raw: bytes) -> list[dict[str, Any]]:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise SampleError("manifest_invalid", "manifest is not valid UTF-8") from exc

    rows: list[dict[str, Any]] = []
    try:
        for line in text.splitlines():
            if not line.strip():
                continue
            row = json.loads(
                line,
                object_pairs_hook=_json_object,
                parse_constant=_reject_json_constant,
            )
            if not isinstance(row, dict):
                raise SampleError("manifest_invalid", "manifest rows must be JSON objects")
            rows.append(row)
    except SampleError:
        raise
    except Exception as exc:
        raise SampleError("manifest_invalid", "manifest JSONL is invalid") from exc
    if not rows:
        raise SampleError("manifest_invalid", "manifest contains no records")
    return rows


def _token(value: Any, label: str) -> str:
    if not isinstance(value, str) or not TOKEN_RE.fullmatch(value):
        raise SampleError("manifest_invalid", f"manifest has an invalid {label}")
    return value


def _sha256(value: Any) -> str:
    if not isinstance(value, str) or not SHA256_RE.fullmatch(value):
        raise SampleError("manifest_invalid", "manifest contains an invalid audio hash")
    return value


def _decimal(value: Any, *, positive: bool, label: str) -> Decimal:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise SampleError("manifest_invalid", f"manifest has an invalid {label}")
    try:
        number = float(value)
        exact = Decimal(str(value))
    except (OverflowError, ValueError, InvalidOperation) as exc:
        raise SampleError("manifest_invalid", f"manifest has an invalid {label}") from exc
    if not math.isfinite(number) or (exact <= 0 if positive else exact < 0):
        raise SampleError("manifest_invalid", f"manifest has an invalid {label}")
    return exact


def _validate_row(row: dict[str, Any]) -> dict[str, Any]:
    if set(row) - ALLOWED_FIELDS or not REQUIRED_FIELDS.issubset(row):
        raise SampleError("manifest_invalid", "manifest schema is unsupported")
    if type(row["schema_version"]) is not int or row["schema_version"] != SCHEMA_VERSION:
        raise SampleError("manifest_invalid", "manifest schema is unsupported")

    _token(row["id"], "record identifier")
    _token(row["source_record_id"], "source record identifier")
    if (
        not isinstance(row["language"], str)
        or row["language"] not in LANGUAGES
        or not isinstance(row["source"], str)
        or row["source"] not in SOURCES
    ):
        raise SampleError("manifest_invalid", "manifest source labels are unsupported")
    if not isinstance(row["slice"], str) or row["slice"] not in SLICES:
        raise SampleError("manifest_invalid", "manifest slice label is unsupported")
    revision = _token(row["source_revision"], "source revision")
    if row["source_license"] != LICENSES[row["source"]]:
        raise SampleError("manifest_invalid", "manifest license does not match its source")

    if not isinstance(row["reference"], str) or "\x00" in row["reference"]:
        raise SampleError("manifest_invalid", "manifest reference is invalid")
    audio_path = row["audio_path"]
    if not isinstance(audio_path, str) or "\x00" in audio_path:
        raise SampleError("manifest_invalid", "manifest audio path is invalid")
    try:
        path = Path(audio_path)
        if not path.is_absolute() or _is_under(path, REPO_ROOT) or _is_under(
            path.resolve(strict=False), REPO_ROOT
        ):
            raise SampleError("manifest_invalid", "manifest audio path is invalid")
    except SampleError:
        raise
    except Exception as exc:
        raise SampleError("manifest_invalid", "manifest audio path is invalid") from exc

    duration = _decimal(row["duration_seconds"], positive=True, label="clip duration")
    if duration > Decimal("600"):
        raise SampleError("manifest_invalid", "manifest clip duration exceeds the supported limit")
    if not isinstance(row["audio_format"], str) or row["audio_format"] not in {"WAV", "FLAC"}:
        raise SampleError("manifest_invalid", "manifest audio format is unsupported")
    sample_rate = row["sample_rate_hz"]
    channels = row["channels"]
    if (
        type(sample_rate) is not int
        or not 8000 <= sample_rate <= 192000
        or type(channels) is not int
        or not 1 <= channels <= 8
    ):
        raise SampleError("manifest_invalid", "manifest audio metadata is invalid")

    _sha256(row["audio_sha256"])
    _sha256(row["source_audio_sha256"])
    if "speaker_id" in row and row["speaker_id"] is not None:
        _token(row["speaker_id"], "speaker identifier")
    if "speech_end_seconds" in row and row["speech_end_seconds"] is not None:
        endpoint = _decimal(row["speech_end_seconds"], positive=True, label="speech endpoint")
        if endpoint > duration or row["reference"] == "":
            raise SampleError("manifest_invalid", "manifest speech endpoint is invalid")
    if "source_duplicate_of" in row and row["source_duplicate_of"] is not None:
        _token(row["source_duplicate_of"], "duplicate record identifier")
    if "source_metadata" in row and not isinstance(row["source_metadata"], dict):
        raise SampleError("manifest_invalid", "manifest source metadata is invalid")

    return {
        "row": row,
        "duration": duration,
        "audio_hash": row["audio_sha256"],
        "revision": revision,
    }


def _validate_manifest(
    rows: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], str, str, str, Decimal]:
    checked = [_validate_row(row) for row in rows]
    ids: set[str] = set()
    source_record_ids: set[str] = set()
    language: str | None = None
    source: str | None = None
    revision: str | None = None
    source_duration = Decimal(0)
    by_audio: dict[str, list[dict[str, Any]]] = defaultdict(list)

    for item in checked:
        row = item["row"]
        if row["id"] in ids or row["source_record_id"] in source_record_ids:
            raise SampleError("manifest_invalid", "manifest contains duplicate record identifiers")
        ids.add(row["id"])
        source_record_ids.add(row["source_record_id"])

        labels = (row["language"], row["source"], item["revision"], row["source_license"])
        if language is None:
            language, source, revision = labels[:3]
        elif labels[:3] != (language, source, revision) or row["source_license"] != LICENSES[source]:
            raise SampleError("manifest_invalid", "manifest mixes language or source revisions")

        source_duration += item["duration"]
        by_audio[item["audio_hash"]].append(item)

    unique: list[dict[str, Any]] = []
    for audio_hash, group in by_audio.items():
        canonical_rows = [
            item for item in group if item["row"].get("source_duplicate_of") is None
        ]
        if len(canonical_rows) != 1:
            raise SampleError("manifest_invalid", "manifest duplicate audio markers are invalid")
        canonical = canonical_rows[0]
        base = canonical["row"]
        speaker_ids: set[str] = set()
        for item in group:
            row = item["row"]
            if item is not canonical and row.get("source_duplicate_of") != base["id"]:
                raise SampleError("manifest_invalid", "manifest duplicate audio markers are invalid")
            comparable = (
                row["reference"],
                row["language"],
                row["slice"],
                item["duration"],
                row["source_audio_sha256"],
                row["audio_format"],
                row["sample_rate_hz"],
                row["channels"],
            )
            canonical_comparable = (
                base["reference"],
                base["language"],
                base["slice"],
                canonical["duration"],
                base["source_audio_sha256"],
                base["audio_format"],
                base["sample_rate_hz"],
                base["channels"],
            )
            if comparable != canonical_comparable:
                raise SampleError("manifest_invalid", "duplicate audio has conflicting metadata")
            speaker = row.get("speaker_id")
            if speaker is not None:
                speaker_ids.add(speaker)
        if len(speaker_ids) > 1:
            raise SampleError("manifest_invalid", "duplicate audio has conflicting speaker labels")
        canonical["group_speaker"] = next(iter(speaker_ids), None)
        unique.append(canonical)

    if language is None or source is None or revision is None:
        raise SampleError("manifest_invalid", "manifest contains no usable records")
    return unique, language, source, revision, source_duration


def _output_directory(value: str | Path) -> Path:
    raw = Path(value).expanduser()
    if not raw.is_absolute():
        raise SampleError("output_invalid", "output must be an explicit absolute path")
    try:
        if raw.exists() or raw.is_symlink():
            raise SampleError("output_invalid", "output directory already exists")
        parent = raw.parent.resolve(strict=True)
        if not parent.is_dir():
            raise SampleError("output_invalid", "output parent is unavailable")
        target = parent / raw.name
        if _is_under(target, REPO_ROOT):
            raise SampleError("output_invalid", "private outputs must be outside the repository")
        os.mkdir(target, 0o700)
        try:
            os.chmod(target, 0o700)
        except Exception:
            try:
                target.rmdir()
            except OSError:
                pass
            raise
        return target
    except SampleError:
        raise
    except Exception as exc:
        raise SampleError("output_invalid", "could not create private output directory") from exc


def _private_write(path: Path, data: bytes) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor: int | None = None
    created = False
    try:
        descriptor = os.open(path, flags, 0o600)
        created = True
        handle = os.fdopen(descriptor, "wb")
        descriptor = None
        with handle:
            handle.write(data)
            handle.flush()
        os.chmod(path, 0o600)
    except Exception as exc:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass
        if created:
            try:
                path.unlink()
            except OSError:
                pass
        raise SampleError("write_failed", "could not write private sample output") from exc


def _manifest_bytes(rows: list[dict[str, Any]]) -> bytes:
    try:
        return b"".join(
            (json.dumps(row, ensure_ascii=False, separators=(",", ":"), allow_nan=False) + "\n").encode(
                "utf-8"
            )
            for row in rows
        )
    except Exception as exc:
        raise SampleError("manifest_invalid", "manifest contains unsupported JSON values") from exc


def _select(
    unique: list[dict[str, Any]], budget: Decimal, seed: int
) -> tuple[list[dict[str, Any]], Decimal]:
    ordered = sorted(
        unique,
        key=lambda item: (item["duration"], item["audio_hash"], item["row"]["id"]),
    )
    groups: dict[tuple[bool, str, int], list[dict[str, Any]]] = defaultdict(list)
    count = len(ordered)
    for index, item in enumerate(ordered):
        quartile = min(3, index * 4 // count)
        speaker = item["group_speaker"]
        groups[(speaker is not None, speaker or "", quartile)].append(item)

    rng = random.Random(seed)
    group_keys = sorted(groups)
    rng.shuffle(group_keys)
    queues: dict[tuple[bool, str, int], deque[dict[str, Any]]] = {}
    for key in sorted(groups):
        clips = sorted(
            groups[key], key=lambda item: (item["audio_hash"], item["row"]["id"])
        )
        rng.shuffle(clips)
        queues[key] = deque(clips)

    selected: list[dict[str, Any]] = []
    elapsed = Decimal(0)
    remaining = budget
    while True:
        made_progress = False
        for key in group_keys:
            queue = queues[key]
            while queue and queue[0]["duration"] > remaining:
                queue.popleft()
            if queue:
                item = queue.popleft()
                selected.append(item)
                elapsed += item["duration"]
                remaining -= item["duration"]
                made_progress = True
        if not made_progress:
            break
    return selected, elapsed


def sample_manifest(
    manifest: str | Path,
    max_seconds: float,
    seed: int,
    output: str | Path,
) -> dict[str, Any]:
    if isinstance(max_seconds, bool) or not isinstance(max_seconds, (int, float)):
        raise SampleError("invalid_budget", "duration budget must be a finite positive number")
    try:
        budget_number = float(max_seconds)
        budget = Decimal(str(max_seconds))
    except (OverflowError, ValueError, InvalidOperation) as exc:
        raise SampleError("invalid_budget", "duration budget must be a finite positive number") from exc
    if not math.isfinite(budget_number) or budget <= 0:
        raise SampleError("invalid_budget", "duration budget must be a finite positive number")
    if budget > MAX_AUDIO_DURATION_SECONDS:
        raise SampleError("duration_limit_exceeded", "duration budget exceeds the 90-minute phase limit")
    if type(seed) is not int:
        raise SampleError("invalid_seed", "seed must be an integer")

    _, source_bytes = _private_manifest(manifest)
    rows = _load_rows(source_bytes)
    unique, language, source, revision, source_duration = _validate_manifest(rows)
    selected, selected_duration = _select(unique, budget, seed)
    if not selected:
        raise SampleError("budget_too_small", "duration budget is too small to include any clip")
    selected_rows = [item["row"] for item in selected]
    selected_bytes = _manifest_bytes(selected_rows)
    source_hash = hashlib.sha256(source_bytes).hexdigest()
    selected_hash = hashlib.sha256(selected_bytes).hexdigest()
    selection_record = {
        "schema_version": SCHEMA_VERSION,
        "method": METHOD,
        "seed": seed,
        "source_manifest_sha256": source_hash,
        "selected_manifest_sha256": selected_hash,
        "source_count": len(rows),
        "eligible_unique_count": len(unique),
        "selected_count": len(selected),
        "source_duration_seconds": float(source_duration),
        "selected_duration_seconds": float(selected_duration),
        "budget_seconds": float(budget),
        "language": language,
        "source": source,
        "source_revision": revision,
    }
    try:
        selection_bytes = (json.dumps(selection_record, indent=2, allow_nan=False) + "\n").encode(
            "utf-8"
        )
    except (OverflowError, ValueError) as exc:
        raise SampleError("manifest_invalid", "manifest duration totals are outside supported bounds") from exc

    target = _output_directory(output)
    written: list[str] = []
    try:
        _private_write(target / "manifest.jsonl", selected_bytes)
        written.append("manifest.jsonl")
        _private_write(target / "selection.json", selection_bytes)
        written.append("selection.json")
    except SampleError:
        for name in written:
            try:
                (target / name).unlink()
            except OSError:
                pass
        try:
            target.rmdir()
        except OSError:
            pass
        raise
    return selection_record


def _argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, help="private schema-v1 prepared JSONL manifest")
    parser.add_argument("--max-seconds", required=True, type=float, help="maximum selected duration, up to 90 minutes")
    parser.add_argument("--seed", type=int, default=42, help="deterministic sampling seed (default: 42)")
    parser.add_argument("--output", required=True, help="new private output directory outside the repository")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _argument_parser().parse_args(argv)
    try:
        record = sample_manifest(args.manifest, args.max_seconds, args.seed, args.output)
    except SampleError as exc:
        print(f"sample: {exc.code}: {exc.message}", file=sys.stderr)
        return 2
    except Exception:
        print("sample: internal_error: sampling failed", file=sys.stderr)
        return 2
    print(f"selected {record['selected_count']} of {record['eligible_unique_count']} unique clips")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
