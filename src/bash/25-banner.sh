# Completion output goes straight to the terminal, never through the log writer.
banner_row() {
    printf '  %s%-12s%s %s\n' "$BannerDim" "$1" "$BannerReset" "$2"
}
completion_banner() {
    local BannerAccent='' BannerSuccess='' BannerDim='' BannerReset='' BannerWarn=''
    if [[ -t 1 && ${TERM:-dumb} != dumb && ! ${NO_COLOR+x} ]]; then
        BannerAccent=$'\033[1;36m'; BannerSuccess=$'\033[1;32m'
        BannerDim=$'\033[2m'; BannerReset=$'\033[0m'; BannerWarn=$'\033[1;33m'
    fi
    local boot=BIOS target='' server='' root_size='available space'
    local network_sysfs=${NetworkSysfs:-/sys/class/net} mac4='' mac6='' iface6=${InstallerV6Interface:-$Interface}
    [[ ! -r $network_sysfs/$Interface/address ]] || mac4=$(<"$network_sysfs/$Interface/address")
    [[ ! -r $network_sysfs/$iface6/address ]] || mac6=$(<"$network_sysfs/$iface6/address")
    (( !EFI )) || boot=UEFI
    case $Suite in bookworm) target='Debian 12 (bookworm)';; trixie) target='Debian 13 (trixie)';; *) target="Debian $ReleaseNumber ($Suite)";; esac
    [[ -z $SystemSize ]] || root_size=$SystemSize
    printf '\n  %sreos%s  %sv%s%s\n' "$BannerAccent" "$BannerReset" "$BannerDim" "$PROGRAM_VERSION" "$BannerReset"
    printf '  %s------------------------------------------------------------%s\n' "$BannerDim" "$BannerReset"
    printf '  %sREADY TO REINSTALL%s\n' "$BannerSuccess" "$BannerReset"
    printf '  Preparation complete. Debian installation starts on reboot.\n\n'
    banner_row System "$target / $Arch"
    banner_row Disk "$Disk / ext4 / $boot"
    banner_row 'Root size' "$root_size"
    banner_row Hostname "$Hostname"
    banner_row Timezone "$Timezone"
    if (( ${#KeepPaths[@]} )); then banner_row Preserve "${KeepPaths[*]}"; fi
    printf '\n  %sACCESS%s\n' "$BannerAccent" "$BannerReset"
    banner_row User "$Username"
    banner_row 'SSH port' "$SSHPort"
    if [[ -n $AuthorizedKeys ]]; then
        banner_row Auth 'SSH public key (SSH password login disabled)'
    else
        banner_row Password "$Password"
        printf '  %sSave this password now; it is not written to the log.%s\n' "$BannerWarn" "$BannerReset"
    fi
    if [[ -n $IP ]]; then
        banner_row IPv4 "$IP"
        [[ -z $Gateway ]] || banner_row 'IPv4 gateway' "$Gateway"
        [[ -z $mac4 ]] || banner_row 'IPv4 MAC' "$mac4 ($Interface)"
        server=$IP
    fi
    if [[ -n $IPv6 ]]; then
        banner_row IPv6 "${IPv6%/*}"
        [[ -z $InstallerV6Gateway ]] || banner_row 'IPv6 gateway' "$InstallerV6Gateway"
        if [[ -n $mac6 ]]; then banner_row 'IPv6 MAC' "$mac6 ($iface6)"; fi
        [[ -n $server ]] || server=${IPv6%/*}
    fi
    if [[ -n $server ]]; then
        banner_row Connect "ssh -p $SSHPort $Username@$server"
        printf '  %sUses the configured address; keep any NAT/forwarding in mind.%s\n' "$BannerDim" "$BannerReset"
    else banner_row Connect "ssh -p $SSHPort $Username@SERVER_IP"; fi
    if (( InstallerSSH )); then
        banner_row Installer 'SSH enabled; same account and port'
        banner_row Progress 'tail -fn+1 /var/log/syslog (in installer SSH)'
    else banner_row Installer 'SSH disabled; use the server console'; fi
    printf '\n  %sNEXT%s\n' "$BannerAccent" "$BannerReset"
    if (( RebootNow )); then banner_row Action 'Rebooting automatically (--reboot-now)'
    else banner_row Start 'reboot'; banner_row Cancel 'reos reset (before reboot)'; fi
    printf '\n  %sThe next boot erases the current system on %s.%s\n' "$BannerWarn" "$Disk" "$BannerReset"
    printf '  %s------------------------------------------------------------%s\n\n' "$BannerDim" "$BannerReset"
}
