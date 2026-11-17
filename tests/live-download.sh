#!/usr/bin/env bash
# Opt-in integration check: real signed Debian downloads, temporary files only.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../reos.sh"
defaults
TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$TEST_ROOT/out/live-download"
export TMPDIR="$TEST_ROOT/out/live-download"
scratch
Suite=trixie
# Read by the sourced download and package-injection functions.
# shellcheck disable=SC2034
ReleaseNumber=13
SelectedMirror=https://deb.debian.org/debian
# shellcheck disable=SC2034
DownloadBases=("$SelectedMirror/dists/$Suite/main/installer-amd64/current/images/netboot/debian-installer/amd64")
installer_download_set "$WORK" linux initrd.gz
InitrdRoot=$WORK/initrd
mkdir "$InitrdRoot"
gzip -dc "$WORK/initrd.gz" > "$WORK/initrd.cpio"
(cd "$InitrdRoot"; cpio -idmu --quiet --no-preserve-owner --nonmatching 'dev/*' './dev/*' < "$WORK/initrd.cpio")
inject_udebs
[[ -x $InitrdRoot/usr/sbin/sshd ]]
[[ -x $InitrdRoot/usr/bin/screen || -x $InitrdRoot/bin/screen ]]
printf 'Signed Debian kernel, initrd, and installer SSH package injection passed.\n'
