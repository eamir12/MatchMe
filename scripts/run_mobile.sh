#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

echo "Starting MatchMe mobile debug run..."
exec flutter run \
  --no-enable-dart-profiling \
  --dart-define=flutter.flutter_map.unblockOSM=Our tile servers are not. \
  "$@"
