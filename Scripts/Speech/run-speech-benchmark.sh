#!/bin/bash

set -euo pipefail
IFS=$'\n\t'
umask 077

usage() {
    cat <<'USAGE'
Usage:
  Scripts/Speech/run-speech-benchmark.sh --self-test
  Scripts/Speech/run-speech-benchmark.sh --build-only
  Scripts/Speech/run-speech-benchmark.sh --manifest FILE --output DIRECTORY \
    --model FILE --vad FILE --language en|ur [--limit N]

The runner accepts a private schema-version-1 JSONL manifest with absolute WAV/FLAC
paths and audio SHA-256 values. It verifies the pinned model and VAD before replay.
Selected audio duration is capped at 90 minutes total.
The output directory must be new, outside this repository, and have an existing parent.
--self-test uses synthetic PCM and fake inference; it does not open a model or microphone.
--build-only compiles the runner and exits without opening models, audio, or output.
USAGE
}

fail() {
    printf 'error_code=%s\n' "$1" >&2
    exit 2
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
RUNTIME_SLICE="$ROOT/build/speech-runtime/whisper.xcframework/macos-arm64"
FRAMEWORK_PATH="$RUNTIME_SLICE/whisper.framework"

case "${1:-}" in
    --help|-h)
        usage
        exit 0
        ;;
    --self-test)
        [[ $# -eq 1 ]] || fail invalid_arguments
        MODE=self-test
        ;;
    --build-only)
        [[ $# -eq 1 ]] || fail invalid_arguments
        MODE=build-only
        ;;
    *)
        MODE=run
        ;;
esac

[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] || fail unsupported_host
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
[[ -d "$DEVELOPER_DIR" ]] || fail xcode_unavailable
[[ -d "$FRAMEWORK_PATH" && -f "$FRAMEWORK_PATH/Versions/A/whisper" ]] || fail runtime_unavailable

TEMP_PARENT="${TMPDIR:-/tmp}"
[[ "$TEMP_PARENT" == /* && -d "$TEMP_PARENT" ]] || fail temporary_directory_unavailable
TEMP_PARENT="$(cd "$TEMP_PARENT" && pwd -P)"
case "$TEMP_PARENT/" in
    "$ROOT/"*) fail temporary_directory_inside_repository ;;
esac
BUILD_DIR="$(mktemp -d "$TEMP_PARENT/mac-utilities-speech-benchmark-standalone.XXXXXX")" || fail temporary_directory_unavailable
cleanup() {
    rm -rf -- "$BUILD_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$BUILD_DIR/module-cache"

RELATIVE_SOURCES=(
    "MacUtilities/Platform/Speech/AudioCaptureStream.swift"
    "MacUtilities/Features/Speech/TranscriptionRecognition.swift"
    "MacUtilities/Platform/Speech/WhisperInference.swift"
    "MacUtilities/Features/Speech/StreamingTranscriptionRecognizer.swift"
    "MacUtilities/Features/Speech/SpeechSegments.swift"
    "MacUtilities/Features/Speech/TranscriptionLanguage.swift"
    "MacUtilities/Platform/Speech/SpeechModelMetadata.swift"
    "Scripts/Speech/Benchmark/Native/SpeechBenchmark.swift"
)
SOURCE_HASH_FILES=("${RELATIVE_SOURCES[@]}" "Scripts/Speech/run-speech-benchmark.sh" "Configuration/Version.xcconfig")
SWIFT_SOURCES=()
for source in "${RELATIVE_SOURCES[@]}"; do
    [[ -f "$ROOT/$source" ]] || fail source_file_missing
    SWIFT_SOURCES+=("$ROOT/$source")
done

SOURCE_REVISION="$(git -C "$ROOT" rev-parse HEAD)" || fail source_revision_unavailable
SOURCE_SHA256="$(cd "$ROOT" && shasum -a 256 "${SOURCE_HASH_FILES[@]}" | shasum -a 256 | awk '{ print $1 }')" || fail source_hash_unavailable
SOURCE_DIRTY=false
if [[ -n "$(git -C "$ROOT" status --porcelain -- "${SOURCE_HASH_FILES[@]}")" ]]; then
    SOURCE_DIRTY=true
fi
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)" || fail xcode_unavailable
OUTPUT_BINARY="$BUILD_DIR/speech-benchmark"

if ! xcrun --sdk macosx swiftc \
    -O \
    -swift-version 5 \
    -default-isolation MainActor \
    -enable-upcoming-feature MemberImportVisibility \
    -target arm64-apple-macosx26.6 \
    -sdk "$SDK_PATH" \
    -F "$RUNTIME_SLICE" \
    -framework whisper \
    -Xlinker -rpath -Xlinker "$RUNTIME_SLICE" \
    -module-cache-path "$BUILD_DIR/module-cache" \
    "${SWIFT_SOURCES[@]}" \
    -o "$OUTPUT_BINARY"; then
    fail standalone_build_failed
fi

POST_BUILD_SOURCE_SHA256="$(cd "$ROOT" && shasum -a 256 "${SOURCE_HASH_FILES[@]}" | shasum -a 256 | awk '{ print $1 }')" || fail source_hash_unavailable
[[ "$POST_BUILD_SOURCE_SHA256" == "$SOURCE_SHA256" ]] || fail source_changed_during_build

if [[ "$MODE" == build-only ]]; then
    printf 'build=ok\n'
    exit 0
fi

export MACUTILITIES_SPEECH_BENCHMARK_REPOSITORY_ROOT="$ROOT"
export MACUTILITIES_SPEECH_BENCHMARK_FRAMEWORK="$FRAMEWORK_PATH"
export MACUTILITIES_SPEECH_BENCHMARK_SOURCE_REVISION="$SOURCE_REVISION"
export MACUTILITIES_SPEECH_BENCHMARK_SOURCE_SHA256="$SOURCE_SHA256"
export MACUTILITIES_SPEECH_BENCHMARK_SOURCE_DIRTY="$SOURCE_DIRTY"
VERSION_CONFIG="$ROOT/Configuration/Version.xcconfig"
APP_VERSION_CANDIDATE="$(awk -F '=' '$1 ~ /^[[:space:]]*MARKETING_VERSION[[:space:]]*$/ { value = $2; gsub(/[[:space:]]/, "", value); print value; exit }' "$VERSION_CONFIG")"
APP_BUILD_CANDIDATE="$(awk -F '=' '$1 ~ /^[[:space:]]*CURRENT_PROJECT_VERSION[[:space:]]*$/ { value = $2; gsub(/[[:space:]]/, "", value); print value; exit }' "$VERSION_CONFIG")"
[[ "$APP_VERSION_CANDIDATE" =~ ^[0-9]+(\.[0-9]+)*$ && "$APP_BUILD_CANDIDATE" =~ ^[0-9]+$ ]] || fail app_version_metadata_unavailable
export MACUTILITIES_SPEECH_BENCHMARK_APP_VERSION_CANDIDATE="$APP_VERSION_CANDIDATE"
export MACUTILITIES_SPEECH_BENCHMARK_APP_BUILD_CANDIDATE="$APP_BUILD_CANDIDATE"

if [[ "$MODE" == self-test ]]; then
    "$OUTPUT_BINARY" --self-test
else
    "$OUTPUT_BINARY" "$@"
fi
