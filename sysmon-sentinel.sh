#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_NAME="sysmon-sentinel"
readonly SCRIPT_VERSION="0.1.0"
readonly DEFAULT_CONFIG="/etc/sysmon-sentinel/sysmon-sentinel.conf"
readonly DEFAULT_LOG_FILE="/var/log/sysmon-sentinel.log"
readonly LOCK_FILE="/run/lock/sysmon-sentinel.lock"
readonly DEFAULT_STATE_DIR="/var/lib/sysmon-sentinel"

CONFIG_FILE="${SYSMON_CONFIG_FILE:-$DEFAULT_CONFIG}"
LOG_FILE="${SYSMON_LOG_FILE:-$DEFAULT_LOG_FILE}"
STATE_DIR="${SYSMON_STATE_DIR:-$DEFAULT_STATE_DIR}"
DRY_RUN=false
RUN_ONCE=false

# Defaults; configuration may override these values.
CHECK_INTERVAL=60
CPU_THRESHOLD=90
MEMORY_THRESHOLD=90
DISK_THRESHOLD=90
SSH_FAILURE_THRESHOLD=20
SSH_LOOKBACK="10 minutes ago"
ALERT_COOLDOWN=900
SERVICES=(nginx docker postgresql sshd)
WEBHOOK_URL=""
WEBHOOK_URL_FILE=""

log() {
    local level="$1"
    shift
    local message
    message="$(date -u '+%Y-%m-%dT%H:%M:%SZ') [$level] $*"
    printf '%s\n' "$message" >> "$LOG_FILE"
}

usage() {
    cat << EOF
Usage: $SCRIPT_NAME [options]

Options:
  -c, --config FILE   Configuration file (default: $CONFIG_FILE)
  -n, --dry-run       Report actions without restarting services
      --once          Run checks once and exit
  -v, --version       Print version
  -h, --help          Show this help
EOF
}

fatal() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" > /dev/null 2>&1 || fatal "required command not found: $1"
}

load_config() {
    [[ -r "$CONFIG_FILE" ]] || fatal "configuration file is not readable: $CONFIG_FILE"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    [[ "$CHECK_INTERVAL" =~ ^[1-9][0-9]*$ ]] || fatal "CHECK_INTERVAL must be a positive integer"
    [[ "$CPU_THRESHOLD" =~ ^[0-9]+$ && "$CPU_THRESHOLD" -le 100 ]] || fatal "CPU_THRESHOLD must be 0-100"
    [[ "$MEMORY_THRESHOLD" =~ ^[0-9]+$ && "$MEMORY_THRESHOLD" -le 100 ]] || fatal "MEMORY_THRESHOLD must be 0-100"
    [[ "$DISK_THRESHOLD" =~ ^[0-9]+$ && "$DISK_THRESHOLD" -le 100 ]] || fatal "DISK_THRESHOLD must be 0-100"
    [[ "$ALERT_COOLDOWN" =~ ^[0-9]+$ ]] || fatal "ALERT_COOLDOWN must be a non-negative integer"
}

load_webhook_secret() {
    [[ -n "$WEBHOOK_URL_FILE" ]] || return 0
    [[ -r "$WEBHOOK_URL_FILE" ]] || fatal "webhook URL file is not readable: $WEBHOOK_URL_FILE"
    WEBHOOK_URL="$(< "$WEBHOOK_URL_FILE")"
    WEBHOOK_URL="${WEBHOOK_URL//$'\n'/}"
    WEBHOOK_URL="${WEBHOOK_URL//$'\r'/}"
}

ensure_log_file() {
    local log_dir
    log_dir="$(dirname "$LOG_FILE")"
    mkdir -p "$log_dir"
    touch "$LOG_FILE"
    chmod 0640 "$LOG_FILE"
}

ensure_state_dir() {
    mkdir -p "$STATE_DIR"
    chmod 0750 "$STATE_DIR"
}

alert_allowed() {
    local event="$1"
    local state_file="$STATE_DIR/$event.last"
    local now last
    [[ "$ALERT_COOLDOWN" -eq 0 ]] && return 0
    now="$(date +%s)"
    if [[ -r "$state_file" ]]; then
        last="$(< "$state_file")"
        if [[ "$last" =~ ^[0-9]+$ ]] && ((now - last < ALERT_COOLDOWN)); then
            log INFO "alert suppressed by cooldown: event=$event"
            return 1
        fi
    fi
    printf '%s\n' "$now" > "$state_file"
    chmod 0640 "$state_file"
    return 0
}

send_alert() {
    local event="$1"
    local details="$2"
    local payload
    [[ -n "$WEBHOOK_URL" ]] || return 0
    alert_allowed "$event" || return 0

    payload=$(printf '{"source":"%s","event":"%s","details":"%s"}' \
        "$SCRIPT_NAME" "$event" "${details//\"/\\\"}")
    curl --fail --silent --show-error --max-time 10 \
        --header 'Content-Type: application/json' \
        --data "$payload" "$WEBHOOK_URL" > /dev/null 2>&1 ||
        log WARN "webhook delivery failed for event=$event"
}

read_cpu_usage() {
    local user nice system idle iowait irq softirq steal idle_total total
    read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
    idle_total=$((idle + iowait))
    total=$((user + nice + system + idle + iowait + irq + softirq + steal))
    sleep 1
    read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
    local idle_total2 total2
    idle_total2=$((idle + iowait))
    total2=$((user + nice + system + idle + iowait + irq + softirq + steal))
    printf '%s\n' $((100 * (total2 - total - idle_total2 + idle_total) / (total2 - total)))
}

check_resources() {
    local cpu_usage memory_usage disk_usage
    cpu_usage="$(read_cpu_usage)"
    memory_usage="$(awk '/MemTotal:/ { total=$2 } /MemAvailable:/ { available=$2 } END { printf "%d", (100 * (total - available) / total) }' /proc/meminfo)"
    disk_usage="$(df -P / | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }')"
    log INFO "resources cpu=${cpu_usage}% memory=${memory_usage}% disk_root=${disk_usage}%"

    if ((cpu_usage >= CPU_THRESHOLD)); then
        log WARN "CPU usage threshold exceeded: ${cpu_usage}%"
        send_alert "resource_threshold" "CPU usage is ${cpu_usage}%"
    fi
    if ((memory_usage >= MEMORY_THRESHOLD)); then
        log WARN "memory usage threshold exceeded: ${memory_usage}%"
        send_alert "resource_threshold" "Memory usage is ${memory_usage}%"
    fi
    if ((disk_usage >= DISK_THRESHOLD)); then
        log WARN "root filesystem threshold exceeded: ${disk_usage}%"
        send_alert "resource_threshold" "Root filesystem usage is ${disk_usage}%"
    fi
}

check_services() {
    local service
    for service in "${SERVICES[@]}"; do
        if ! systemctl is-active --quiet "$service"; then
            log WARN "service is inactive: $service"
            if [[ "$DRY_RUN" == true ]]; then
                log INFO "dry-run: would restart $service"
            else
                if systemctl restart "$service"; then
                    log INFO "service restarted: $service"
                    send_alert "service_restarted" "$service was restarted"
                else
                    log ERROR "service restart failed: $service"
                    send_alert "service_restart_failed" "Failed to restart $service"
                fi
            fi
        fi
    done
}

check_ssh_failures() {
    local failures
    command -v journalctl > /dev/null 2>&1 || return 0
    failures="$(journalctl --since "$SSH_LOOKBACK" --no-pager -q 2> /dev/null |
        grep -Eic '((failed|invalid) password|authentication failure|failed publickey)' || true)"
    log INFO "ssh_authentication_failures=${failures} lookback=\"$SSH_LOOKBACK\""
    if ((failures >= SSH_FAILURE_THRESHOLD)); then
        log WARN "SSH authentication failure threshold exceeded: ${failures}"
        send_alert "ssh_bruteforce" "${failures} SSH authentication failures in ${SSH_LOOKBACK}"
    fi
}

run_once() {
    check_resources
    check_services
    check_ssh_failures
}

main() {
    while (($# > 0)); do
        case "$1" in
            -c | --config)
                (($# >= 2)) || fatal "missing argument for $1"
                CONFIG_FILE="$2"
                shift 2
                ;;
            -n | --dry-run)
                DRY_RUN=true
                shift
                ;;
            --once)
                RUN_ONCE=true
                shift
                ;;
            -v | --version)
                printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
                return 0
                ;;
            -h | --help)
                usage
                return 0
                ;;
            *)
                fatal "unknown option: $1"
                ;;
        esac
    done

    require_command awk
    require_command curl
    require_command df
    require_command flock
    require_command systemctl
    load_config
    load_webhook_secret
    ensure_log_file
    ensure_state_dir

    exec 200> "$LOCK_FILE"
    if ! flock -n 200; then
        log INFO "another instance is already running"
        return 0
    fi

    log INFO "starting $SCRIPT_NAME version=$SCRIPT_VERSION interval=${CHECK_INTERVAL}s"
    if [[ "$RUN_ONCE" == true ]]; then
        run_once
        return 0
    fi

    while true; do
        run_once
        sleep "$CHECK_INTERVAL"
    done
}

main "$@"
