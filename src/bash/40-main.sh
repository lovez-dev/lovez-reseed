status() {
    printf 'reos %s\n' "$PROGRAM_VERSION"
    local path env
    for path in /boot/reos/linux /boot/reos/initrd.gz /boot/reos/firmware.cpio.gz; do
        [[ ! -f $path ]] || printf 'Installer: %s (%s bytes)\n' "$path" "$(stat -c %s "$path")"
    done
    if grep -q '^### BEGIN reos ###$' /etc/grub.d/40_custom 2>/dev/null; then printf 'GRUB entry: installed\n'; else printf 'GRUB entry: not installed\n'; fi
    for env in /boot/grub/grubenv /boot/grub2/grubenv; do [[ ! -f $env ]] || grub-editenv "$env" list 2>/dev/null || true; done
    for path in /var/lib/reos/firstboot-status /var/lib/reos/cleanup-status; do [[ ! -f $path ]] || { printf '%s: ' "$path"; cat "$path"; }; done
}
logs() {
    local kind=${1:-reos} path paths=()
    case $kind in
        reos) paths=(/var/log/reos.log);;
        firstboot) paths=(/var/log/reos-firstboot.log);;
        cleanup) paths=(/var/log/reos-cleanup.log);;
        all) paths=(/var/log/reos.log /var/log/reos-firstboot.log /var/log/reos-cleanup.log);;
        *) die 'Unknown log type (reos/firstboot/cleanup/all)';;
    esac
    for path in "${paths[@]}"; do [[ ! -f $path ]] || { printf '==> %s <==\n' "$path"; tail -n80 "$path"; }; done
}
reset() {
    (( EUID == 0 )) || die 'Root privileges required'
    need update-grub; need grub-editenv; need flock
    exec 9>/run/lock/reos.lock; flock -n 9 || die 'Another reos process is running'
    scratch
    [[ ! -L /boot/reos ]] || die 'Refusing a symlink installer directory'
    if [[ -f /etc/grub.d/40_custom ]]; then
        strip_grub /etc/grub.d/40_custom > "$WORK/custom"
        install -m755 "$WORK/custom" /etc/grub.d/40_custom
    fi
    rm -f /etc/default/grub.d/zz-reos.cfg
    local env next
    for env in /boot/grub/grubenv /boot/grub2/grubenv; do
        [[ -f $env ]] || continue
        next=$(grub-editenv "$env" list | sed -n 's/^next_entry=//p')
        case $next in reos|'Debian Installer (reos)') grub-editenv "$env" unset next_entry;; esac
    done
    update-grub
    rm -rf /boot/reos
    message 'Reinstallation canceled; installer entry and files removed.'
}
main() {
    (( BASH_VERSINFO[0] >= 4 )) || die 'Bash 4 or newer required'
    defaults
    case ${1:-} in
        status) (( $# == 1 )) || die 'status takes no arguments'; status; return;;
        logs) (( $# <= 2 )) || die 'logs accepts one log type'; logs "${2:-reos}"; return;;
        reset) (( $# == 1 )) || die 'reset takes no arguments'; reset; return;;
    esac
    parse "$@"
    validate
    if (( DryRun )); then preview; else prepare; fi
}
