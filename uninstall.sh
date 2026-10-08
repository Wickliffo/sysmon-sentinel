#!/usr/bin/env bash

set -Eeuo pipefail

PREFIX=${PREFIX:-/usr/local}
SYSCONFDIR=${SYSCONFDIR:-/etc/sysmon-sentinel}
SYSTEMD_DIR=${SYSTEMD_DIR:-/etc/systemd/system}

((EUID == 0)) || {
    echo "uninstall.sh must be run as root (try: sudo ./uninstall.sh)" >&2
    exit 1
}

systemctl disable --now sysmon-sentinel.service 2> /dev/null || true
rm -f "$PREFIX/sbin/sysmon-sentinel" /etc/logrotate.d/sysmon-sentinel "$SYSTEMD_DIR/sysmon-sentinel.service"
systemctl daemon-reload
printf 'sysmon-sentinel binaries and service removed.\n'
printf 'Configuration retained at %s; remove it manually if desired.\n' "$SYSCONFDIR"
