#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/bin/sysmon-sentinel.sh"

[[ -x "$SCRIPT" ]] || {
    echo "monitor script is not executable" >&2
    exit 1
}
[[ -s "$ROOT_DIR/config/logrotate.d/sysmon-sentinel" ]] || {
    echo "logrotate policy is missing" >&2
    exit 1
}
[[ -s "$ROOT_DIR/.github/workflows/lint.yml" ]] || {
    echo "lint workflow is missing" >&2
    exit 1
}

version="$($SCRIPT --version)"
[[ "$version" == "sysmon-sentinel 0.1.0" ]] || {
    echo "unexpected version: $version" >&2
    exit 1
}

help_output="$($SCRIPT --help)"
grep -q -- '--dry-run' <<< "$help_output"
grep -q -- '--once' <<< "$help_output"
grep -q -- '--config' <<< "$help_output"

bash -n "$SCRIPT"
bash -n "$ROOT_DIR/tests/smoke.sh"
printf 'smoke tests passed\n'
