#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../bench"
flutter pub get --enforce-lockfile
exec dart run bin/run.dart "$@"
