#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/state"
cat > "$TMP_DIR/bin/systemctl" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "is-active" ]]; then
    exit 1
fi
exit 0
EOF
cat > "$TMP_DIR/bin/journalctl" << 'EOF'
#!/usr/bin/env bash
printf 'Failed password for invalid user\n'
printf 'authentication failure\n'
EOF
chmod 0755 "$TMP_DIR/bin/systemctl" "$TMP_DIR/bin/journalctl"
cat > "$TMP_DIR/bin/curl" << 'EOF'
#!/usr/bin/env bash
printf 'webhook-called\n' >> "$SYSMON_CURL_LOG"
EOF
chmod 0755 "$TMP_DIR/bin/curl"
printf 'https://example.invalid/hook\n' > "$TMP_DIR/webhook.url"
cat > "$TMP_DIR/config" << EOF
CHECK_INTERVAL=1
CPU_THRESHOLD=100
MEMORY_THRESHOLD=100
DISK_THRESHOLD=100
SSH_FAILURE_THRESHOLD=2
SSH_LOOKBACK='10 minutes ago'
ALERT_COOLDOWN=900
SERVICES=(mock-service)
WEBHOOK_URL=''
WEBHOOK_URL_FILE=$TMP_DIR/webhook.url
EOF

PATH="$TMP_DIR/bin:$PATH" SYSMON_LOG_FILE="$TMP_DIR/monitor.log" \
    SYSMON_CURL_LOG="$TMP_DIR/curl.log" \
    SYSMON_STATE_DIR="$TMP_DIR/state" \
    "$ROOT_DIR/bin/sysmon-sentinel.sh" --config "$TMP_DIR/config" --dry-run --once

PATH="$TMP_DIR/bin:$PATH" SYSMON_LOG_FILE="$TMP_DIR/monitor.log" \
    SYSMON_CURL_LOG="$TMP_DIR/curl.log" \
    SYSMON_STATE_DIR="$TMP_DIR/state" \
    "$ROOT_DIR/bin/sysmon-sentinel.sh" --config "$TMP_DIR/config" --dry-run --once

grep -q 'dry-run: would restart mock-service' "$TMP_DIR/monitor.log"
grep -q 'ssh_authentication_failures=2' "$TMP_DIR/monitor.log"
[[ "$(wc -l < "$TMP_DIR/curl.log")" -eq 1 ]]
grep -q 'alert suppressed by cooldown: event=ssh_bruteforce' "$TMP_DIR/monitor.log"
printf 'integration tests passed\n'
