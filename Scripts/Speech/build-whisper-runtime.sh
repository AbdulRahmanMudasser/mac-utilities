#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

readonly WHISPER_REVISION="d1be6fde11ac6e0407606b4e42fe72d34add8037"
readonly WHISPER_REPOSITORY="https://github.com/ggml-org/whisper.cpp.git"
readonly MACOS_MINIMUM="13.3"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

if [[ -n "${MACUTILITIES_SPEECH_RUNTIME_ROOT:-}" ]]; then
    RUNTIME_ROOT_INPUT="$MACUTILITIES_SPEECH_RUNTIME_ROOT"
else
    RUNTIME_ROOT_INPUT="$REPOSITORY_ROOT/build/speech-runtime"
fi

if [[ "$RUNTIME_ROOT_INPUT" != /* ]]; then
    RUNTIME_ROOT_INPUT="$REPOSITORY_ROOT/$RUNTIME_ROOT_INPUT"
fi

mkdir -p "$(dirname "$RUNTIME_ROOT_INPUT")"
if [[ -L "$RUNTIME_ROOT_INPUT" ]]; then
    echo "Refusing to use a symlink as the speech runtime build directory: $RUNTIME_ROOT_INPUT" >&2
    exit 1
fi
mkdir -p "$RUNTIME_ROOT_INPUT"
RUNTIME_ROOT="$(cd "$RUNTIME_ROOT_INPUT" && pwd -P)"
RUNTIME_ROOT_NAME="$(basename "$RUNTIME_ROOT")"

if [[ "$RUNTIME_ROOT" == "/" || "$RUNTIME_ROOT" == "$HOME" || "$RUNTIME_ROOT" == "$REPOSITORY_ROOT" ]] \
    || [[ "$RUNTIME_ROOT_NAME" != "speech-runtime" && "$RUNTIME_ROOT_NAME" != mac-utilities-whisper-runtime-* ]]; then
    echo "Choose a dedicated speech-runtime directory or a mac-utilities-whisper-runtime-* temporary directory." >&2
    exit 1
fi

readonly SOURCE_DIR="$RUNTIME_ROOT/source"
readonly CMAKE_BUILD_DIR="$RUNTIME_ROOT/cmake-build"
readonly PACKAGE_DIR="$RUNTIME_ROOT/package"
readonly COMBINED_ARCHIVE="$RUNTIME_ROOT/whisper-combined-arm64.a"
readonly FRAMEWORK_DIR="$PACKAGE_DIR/whisper.framework"
readonly XCFRAMEWORK_DIR="$RUNTIME_ROOT/whisper.xcframework"

fail() {
    echo "Speech runtime setup failed: $*" >&2
    exit 1
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || fail "required tool '$1' is not available"
}

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    fail "this builder requires a native macOS arm64 shell"
fi

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
[[ -d "$DEVELOPER_DIR" ]] || fail "Xcode developer directory not found at $DEVELOPER_DIR"

if ! command -v cmake >/dev/null 2>&1 && [[ -x "$HOME/.local/bin/cmake" ]]; then
    export PATH="$HOME/.local/bin:$PATH"
fi

for tool in git cmake xcodebuild xcrun libtool lipo nm otool; do
    require_tool "$tool"
done

CMAKE_VERSION="$(cmake --version | awk 'NR == 1 { print $3 }')"
CMAKE_MAJOR="${CMAKE_VERSION%%.*}"
CMAKE_REMAINDER="${CMAKE_VERSION#*.}"
CMAKE_MINOR="${CMAKE_REMAINDER%%.*}"
if (( CMAKE_MAJOR < 3 || (CMAKE_MAJOR == 3 && CMAKE_MINOR < 28) )); then
    fail "CMake 3.28 or newer is required; found $CMAKE_VERSION"
fi

echo "Building whisper.cpp $WHISPER_REVISION for macOS arm64 with embedded Metal shaders."
echo "Using $(xcodebuild -version | head -n 1) and CMake $CMAKE_VERSION."
echo "Runtime output: $XCFRAMEWORK_DIR"

# Every removed path is a fixed child of the dedicated runtime directory.
for generated_path in "$SOURCE_DIR" "$CMAKE_BUILD_DIR" "$PACKAGE_DIR" "$COMBINED_ARCHIVE" "$XCFRAMEWORK_DIR"; do
    [[ ! -L "$generated_path" ]] || fail "refusing to remove symlink $generated_path"
    rm -rf -- "$generated_path"
done

git init --quiet "$SOURCE_DIR"
git -C "$SOURCE_DIR" remote add origin "$WHISPER_REPOSITORY"
git -C "$SOURCE_DIR" -c advice.detachedHead=false fetch --quiet --depth=1 --no-tags origin "$WHISPER_REVISION"
git -C "$SOURCE_DIR" -c advice.detachedHead=false checkout --quiet --detach FETCH_HEAD

ACTUAL_REVISION="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
[[ "$ACTUAL_REVISION" == "$WHISPER_REVISION" ]] || fail "source checkout resolved to $ACTUAL_REVISION"
[[ -z "$(git -C "$SOURCE_DIR" status --porcelain)" ]] || fail "source checkout is not clean"
echo "Verified source commit $ACTUAL_REVISION (tree $(git -C "$SOURCE_DIR" rev-parse 'HEAD^{tree}'))."

# Propagate VAD graph failures instead of treating incomplete probabilities as silence.
git -C "$SOURCE_DIR" apply --check "$SCRIPT_DIR/whisper-vad-compute-error.patch"
git -C "$SOURCE_DIR" apply "$SCRIPT_DIR/whisper-vad-compute-error.patch"

cmake -S "$SOURCE_DIR" -B "$CMAKE_BUILD_DIR" -G Xcode \
    -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_SERVER=OFF \
    -DWHISPER_COREML=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_METAL_USE_BF16=ON \
    -DGGML_BLAS=ON \
    -DGGML_BLAS_VENDOR=Apple \
    -DGGML_ACCELERATE=ON \
    -DGGML_OPENMP=OFF \
    -DGGML_NATIVE=OFF \
    -DGGML_LLAMAFILE=OFF \
    -DGGML_BACKEND_DL=OFF \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MINIMUM" \
    -DCMAKE_OSX_SYSROOT=macosx \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO

cmake --build "$CMAKE_BUILD_DIR" --config Release --target whisper --parallel "$(sysctl -n hw.ncpu)"

LIBRARIES=(
    "$CMAKE_BUILD_DIR/src/Release/libwhisper.a"
    "$CMAKE_BUILD_DIR/ggml/src/Release/libggml.a"
    "$CMAKE_BUILD_DIR/ggml/src/Release/libggml-base.a"
    "$CMAKE_BUILD_DIR/ggml/src/Release/libggml-cpu.a"
    "$CMAKE_BUILD_DIR/ggml/src/ggml-metal/Release/libggml-metal.a"
    "$CMAKE_BUILD_DIR/ggml/src/ggml-blas/Release/libggml-blas.a"
)

for library in "${LIBRARIES[@]}"; do
    [[ -f "$library" ]] || fail "expected CMake output is missing: $library"
    ARCHITECTURES="$(lipo -archs "$library")"
    [[ "$ARCHITECTURES" == "arm64" ]] || fail "expected arm64-only library, got '$ARCHITECTURES' in $library"
done

libtool -static -o "$COMBINED_ARCHIVE" "${LIBRARIES[@]}"
[[ "$(lipo -archs "$COMBINED_ARCHIVE")" == "arm64" ]] || fail "combined archive is not arm64-only"

mkdir -p \
    "$FRAMEWORK_DIR/Versions/A/Headers" \
    "$FRAMEWORK_DIR/Versions/A/Modules" \
    "$FRAMEWORK_DIR/Versions/A/Resources"
ln -s A "$FRAMEWORK_DIR/Versions/Current"
ln -s Versions/Current/Headers "$FRAMEWORK_DIR/Headers"
ln -s Versions/Current/Modules "$FRAMEWORK_DIR/Modules"
ln -s Versions/Current/Resources "$FRAMEWORK_DIR/Resources"
ln -s Versions/Current/whisper "$FRAMEWORK_DIR/whisper"

HEADER_DIR="$FRAMEWORK_DIR/Versions/A/Headers"
cp "$SOURCE_DIR/include/whisper.h" "$HEADER_DIR/"
cp "$SOURCE_DIR/ggml/include/ggml.h" "$HEADER_DIR/"
cp "$SOURCE_DIR/ggml/include/ggml-alloc.h" "$HEADER_DIR/"
cp "$SOURCE_DIR/ggml/include/ggml-backend.h" "$HEADER_DIR/"
cp "$SOURCE_DIR/ggml/include/ggml-cpu.h" "$HEADER_DIR/"
cp "$SOURCE_DIR/LICENSE" "$FRAMEWORK_DIR/Versions/A/Resources/LICENSE"

cat > "$FRAMEWORK_DIR/Versions/A/Modules/module.modulemap" <<'MODULEMAP'
framework module whisper {
    header "whisper.h"
    header "ggml.h"
    header "ggml-alloc.h"
    header "ggml-backend.h"
    header "ggml-cpu.h"

    link "c++"
    link framework "Accelerate"
    link framework "Foundation"
    link framework "Metal"
    link framework "MetalKit"

    export *
}
MODULEMAP

cat > "$FRAMEWORK_DIR/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>whisper</string>
    <key>CFBundleIdentifier</key>
    <string>org.ggml.whisper</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>whisper</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>${MACOS_MINIMUM}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    <key>DTPlatformName</key>
    <string>macosx</string>
    <key>WhisperSourceRevision</key>
    <string>${WHISPER_REVISION}</string>
    <key>GGMLMetalEmbeddedLibrary</key>
    <true/>
</dict>
</plist>
PLIST

FRAMEWORK_BINARY="$FRAMEWORK_DIR/Versions/A/whisper"
xcrun --sdk macosx clang++ -dynamiclib \
    -arch arm64 \
    -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    "-mmacosx-version-min=$MACOS_MINIMUM" \
    "-Wl,-force_load,$COMBINED_ARCHIVE" \
    -framework Accelerate \
    -framework Foundation \
    -framework Metal \
    -framework MetalKit \
    -lc++ \
    -install_name @rpath/whisper.framework/Versions/Current/whisper \
    -o "$FRAMEWORK_BINARY"

FRAMEWORK_ARCHITECTURES="$(lipo -archs "$FRAMEWORK_BINARY")"
[[ "$FRAMEWORK_ARCHITECTURES" == "arm64" ]] || fail "framework contains unexpected architectures: $FRAMEWORK_ARCHITECTURES"

SYMBOLS="$(nm -g "$FRAMEWORK_BINARY")"
grep -q '_whisper_version$' <<<"$SYMBOLS" || fail "whisper C API symbol is missing from the framework"
grep -Eq '_ggml_metallib_.*_start$' <<<"$SYMBOLS" || fail "embedded Metal shader symbols are missing from the framework"

MODULE_PROBE="$RUNTIME_ROOT/module-probe.swift"
printf 'import whisper\n' > "$MODULE_PROBE"
xcrun --sdk macosx swiftc -F "$PACKAGE_DIR" -typecheck \
    -module-cache-path "$RUNTIME_ROOT/swift-module-cache" "$MODULE_PROBE"

xcodebuild -create-xcframework \
    -framework "$FRAMEWORK_DIR" \
    -output "$XCFRAMEWORK_DIR"

XCFRAMEWORK_INFO="$XCFRAMEWORK_DIR/Info.plist"
[[ -f "$XCFRAMEWORK_INFO" ]] || fail "Xcode did not create an XCFramework Info.plist"
PLATFORM="$(/usr/libexec/PlistBuddy -c 'Print :AvailableLibraries:0:SupportedPlatform' "$XCFRAMEWORK_INFO")"
[[ "$PLATFORM" == "macos" ]] || fail "unexpected XCFramework platform: $PLATFORM"
XCFRAMEWORK_ARCHITECTURES="$(/usr/libexec/PlistBuddy -c 'Print :AvailableLibraries:0:SupportedArchitectures:0' "$XCFRAMEWORK_INFO")"
[[ "$XCFRAMEWORK_ARCHITECTURES" == "arm64" ]] || fail "unexpected XCFramework architecture: $XCFRAMEWORK_ARCHITECTURES"

echo "Verified $WHISPER_REVISION, macOS arm64-only binary, embedded Metal shader symbols, and Swift module 'whisper'."
echo "XcodeGen will link, embed, and code-sign: $XCFRAMEWORK_DIR"
