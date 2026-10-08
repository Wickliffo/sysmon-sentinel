#!/usr/bin/env bash

set -Eeuo pipefail

PREFIX=${PREFIX:-/usr/local}
SYSCONFDIR=${SYSCONFDIR:-/etc/sysmon-sentinel}
SYSTEMD_DIR=${SYSTEMD_DIR:-/etc/systemd/system}
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

((EUID == 0)) || {
    echo "install.sh must be run as root (try: sudo ./install.sh)" >&2
    exit 1
}

install -Dm0755 "$ROOT_DIR/bin/sysmon-sentinel.sh" "$PREFIX/sbin/sysmon-sentinel"
install -Dm0644 "$ROOT_DIR/config/sysmon-sentinel.conf" "$SYSCONFDIR/sysmon-sentinel.conf"
install -Dm0644 "$ROOT_DIR/config/logrotate.d/sysmon-sentinel" /etc/logrotate.d/sysmon-sentinel
install -Dm0644 "$ROOT_DIR/config/systemd/sysmon-sentinel.service" "$SYSTEMD_DIR/sysmon-sentinel.service"
install -Dm0600 /dev/null "$SYSCONFDIR/sysmon-sentinel.env"
install -Dm0600 /dev/null "$SYSCONFDIR/webhook.url"

systemctl daemon-reload
systemctl enable --now sysmon-sentinel.service
printf 'sysmon-sentinel installed and started.\n'
printf 'Edit %s and %s to configure notifications.\n' \
    "$SYSCONFDIR/sysmon-sentinel.conf" "$SYSCONFDIR/webhook.url"
