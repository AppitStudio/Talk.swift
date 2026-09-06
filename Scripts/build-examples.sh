#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$TASK_ROOT/Scripts/build-examples.py" "$@"
