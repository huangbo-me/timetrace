#!/bin/bash
set -euo pipefail
APPSTORE_PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1
exec /usr/bin/python3 "$APPSTORE_PROJECT_DIR/Scripts/appstore.py" "$@"
