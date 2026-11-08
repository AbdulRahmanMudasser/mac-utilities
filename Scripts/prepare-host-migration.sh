#!/bin/bash
set -euo pipefail
SCRIPT_ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_ROOT/.." && pwd)"
MIGRATION_BUILD="$(mktemp -d /tmp/mac-utilities-migration.XXXXXX)"
trap 'rm -rf "$MIGRATION_BUILD"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$PROJECT_ROOT"
xcrun swiftc -parse-as-library -O -o "$MIGRATION_BUILD/preflight" \
  Scripts/Storage/HostMigrationPreflight.swift \
  MacUtilities/Platform/Storage/HostMigration{Files,Preferences,Validation}.swift \
  MacUtilities/Platform/Storage/HostStorageMigration.swift \
  MacUtilities/Platform/Storage/Usage{WriterLease,StateStore}.swift \
  MacUtilities/Platform/Speech/{TranscriptionStoragePaths,SpeechModelMetadata,SpeechModelStore}.swift \
  MacUtilities/Features/Speech/TranscriptionHistoryStore.swift \
  MacUtilities/Features/KeepAwake/KeepAwakeModels.swift \
  Shared/Usage/{UsageBytes,UsageHistory,UsageWidgetSnapshot}.swift \
  MacUtilities/Features/Usage/UsageSnapshotPublisher.swift \
  Shared/Storage/UsageStorageLimits.swift
"$MIGRATION_BUILD/preflight" "$@"
