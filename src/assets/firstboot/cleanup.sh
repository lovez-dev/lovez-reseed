#!/bin/sh
set -u
mkdir -p /var/lib/reos
LOG=/var/log/reos-cleanup.log
exec >>"$LOG" 2>&1
export DEBIAN_FRONTEND=noninteractive
fail() {
    printf 'failed: cleanup (%s)\n' "$1" > /var/lib/reos/cleanup-status
    systemctl disable reos-cleanup.service 2>/dev/null || true
    exit "$1"
}
apt-get autoremove --purge -y || fail $?
apt-get clean || fail $?
printf 'complete\n' > /var/lib/reos/cleanup-status
systemctl disable reos-cleanup.service 2>/dev/null || true
rm -f /etc/systemd/system/reos-cleanup.service /etc/systemd/system/multi-user.target.wants/reos-cleanup.service
rm -rf /root/.reos
systemctl daemon-reload 2>/dev/null || true
rm -f "$LOG"
