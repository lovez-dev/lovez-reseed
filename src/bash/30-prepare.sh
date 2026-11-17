read_local() {
    [[ -f $1 && ! -L $1 ]] || die "Expected a regular file without a symlink: $1"
    [[ $(stat -c %s "$1") -le 1048576 ]] || die "File exceeds 1 MiB: $1"
    cat -- "$1"
}
prepare_keys() {
    local line count=0
    fetch "$AuthorizedKeysURL" "$WORK/keys.download" 1048576 || die 'Cannot download authorized keys'
    sed 's/\r$//' "$WORK/keys.download" > "$WORK/keys"
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        [[ $line =~ ^[[:space:]]*(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]] ]] || die 'Expected an OpenSSH public key without authorized_keys options'
        printf '%s\n' "$line" > "$WORK/key-line"
        ssh-keygen -l -f "$WORK/key-line" >/dev/null 2>&1 || die 'Invalid SSH public key in authorized keys'
        ((count+=1))
    done < "$WORK/keys"
    (( count )) || die 'Authorized keys contain no SSH public keys'
    AuthorizedKeys=$(cat "$WORK/keys")
    KeysB64=$(base64 -w0 "$WORK/keys")
}
configure_payload() {
    local base=${SelectedMirror:-${Mirror:-https://deb.debian.org/debian}} rest
    AptProxy=$Proxy
    # APT only supports SOCKS with remote name resolution.
    [[ $AptProxy != socks5://* ]] || AptProxy=socks5h://${AptProxy#socks5://}
    MirrorProtocol=${base%%://*}; rest=${base#*://}; MirrorHost=${rest%%/*}
    MirrorDir=/${rest#*/}; [[ $rest == */* ]] || MirrorDir=/debian
    # Debian security archives have an independent layout from package mirrors.
    SecurityRepo=https://deb.debian.org/debian-security
    SecuritySuite=$Suite-security
    Install="$Install ifupdown"
    [[ $Username == root ]] || Install+=' sudo'
    (( !Unattended )) || Install+=' unattended-upgrades'
    Home=/root; [[ $Username == root ]] || Home=/home/$Username
    local mem
    mem=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || true)
    if [[ -n $mem ]] && (( mem > 0 && mem < 1024 )); then Swap=1; fi
    [[ -n $SwapSize ]] || { SwapSize=1G; SwapMB=1024; }
}
write_payload() {
    local dir=$1
    mkdir -p "$dir/reos-assets" "$dir/configs"
    # The archive includes '.', which becomes / in the installer.
    # Keep it traversable for the configured non-root SSH account.
    chmod 755 "$dir"
    local assets=$dir/reos-assets
    asset_preseed_tmpl > "$dir/preseed.cfg"
    asset_late_sh_tmpl > "$assets/late.sh"
    asset_firstboot_firstboot_sh_tmpl > "$assets/firstboot.sh"
    asset_firstboot_fix_eth_name_sh > "$assets/fix-eth-name.sh"
    asset_firstboot_fix_eth_name_service > "$assets/fix-eth-name.service"
    asset_installer_early_sh > "$assets/early.sh"
    asset_partman_partman_early_sh > "$assets/partman-early.sh"
    if (( InstallerOnlink )); then
        mkdir -p "$dir/var/lib/dpkg/info"
        asset_installer_netcfg_onlink_sh_tmpl > "$dir/var/lib/dpkg/info/netcfg.postinst"
        chmod 755 "$dir/var/lib/dpkg/info/netcfg.postinst"
    fi
    (( !SystemSizeMB )) || : > "$assets/system-size"
    if [[ -n $SecurityRepo ]]; then asset_installer_post_base_installer_sh_tmpl > "$assets/post-base-installer.sh"; fi
    asset_firstboot_cleanup_sh > "$assets/cleanup.sh"
    if (( InstallerSSH )); then
        asset_installer_ssh_installer_ssh_sh_tmpl > "$assets/installer-ssh.sh"
        printf '%s\n' "$PasswordHash" > "$dir/configs/reos-installer-pass"
        [[ -z $AuthorizedKeys ]] || printf '%s\n' "$AuthorizedKeys" > "$dir/configs/reos-installer-keys"
    fi
    if (( Optimize )); then
        mkdir -p "$assets/optimize"
        asset_optimize_10_sysctl_sh > "$assets/optimize/10-sysctl.sh"
        asset_optimize_20_limits_sh > "$assets/optimize/20-limits.sh"
        asset_optimize_30_journald_sh > "$assets/optimize/30-journald.sh"
        asset_optimize_40_logrotate_sh > "$assets/optimize/40-logrotate.sh"
    fi
    find "$assets" -name '*.sh' -exec chmod 755 {} +
    chmod 644 "$assets/fix-eth-name.service" "$dir/preseed.cfg"
}
summary() {
    message "reos $PROGRAM_VERSION — Debian $Suite ($Arch)"
    message "Disk: $Disk; label: $DiskLabel; filesystem: ext4; EFI: $EFI"
    message "Network: $Interface; IPv4: ${IP:-none}; static: $Static; IPv6: ${IPv6:-auto/none}"
    message "Hostname: $Hostname; timezone: $Timezone; kernel: $Kernel"
    message "Login: $Username; SSH port: $SSHPort; installer SSH: $InstallerSSH"
    [[ -z $SystemSize ]] || message "Root size cap: $SystemSize"
    if (( ${#KeepParts[@]} )); then message "Preserved partitions: ${KeepParts[*]}"; fi
}
preview() {
    resolve_suite
    detect_arch
    detect_disk
    detect_network
    preserve_partitions
    configure_payload
    summary
    printf '\n# Target /etc/network/interfaces\n%s\n' "$Interfaces"
    printf '# Preseed preview (password hash omitted)\n'
    PasswordHash='!'
    asset_preseed_tmpl
    message 'Preview only: no downloads, dependency installation, or boot changes.'
}

strip_grub() { sed '/^### BEGIN reos ###$/,/^### END reos ###$/d' "$1"; }
COMMIT_STARTED=0
COMMITTED=0
BOOT_BACKUP=
BOOT_MOVED=0
commit_cleanup() {
    local code=$?
    if (( COMMIT_STARTED && !COMMITTED )); then
        printf 'reos: restoring previous boot configuration after preparation failure\n' >&2
        cp -p -- "$WORK/40_custom.backup" /etc/grub.d/40_custom || true
        if [[ -e $WORK/default.backup ]]; then cp -p -- "$WORK/default.backup" /etc/default/grub.d/zz-reos.cfg || true
        else rm -f /etc/default/grub.d/zz-reos.cfg; fi
        if (( BOOT_MOVED )); then
            rm -rf /boot/reos
            mv -- "$BOOT_BACKUP" /boot/reos || true
        elif [[ -f $WORK/no-previous-boot ]]; then rm -rf /boot/reos; fi
        local env
        for env in grub grub2; do
            [[ ! -f $WORK/$env.grubenv ]] || cp -p -- "$WORK/$env.grubenv" "/boot/$env/grubenv" || true
        done
        update-grub >/dev/null 2>&1 || true
    fi
    cleanup
    return "$code"
}
commit_boot() {
    local uuid boot_path linux_path initrd_path firmware_path='' env args keep
    uuid=$(grub-probe --target=fs_uuid /boot)
    [[ $uuid =~ ^[a-zA-Z0-9-]+$ ]] || die 'Cannot identify /boot filesystem for GRUB'
    # Probe the existing directory; installer files do not exist on the first run.
    boot_path=$(grub-mkrelpath /boot)
    linux_path=${boot_path%/}/reos/linux
    initrd_path=${boot_path%/}/reos/initrd.gz
    (( !Firmware )) || firmware_path=${boot_path%/}/reos/firmware.cpio.gz
    [[ $linux_path =~ ^/[a-zA-Z0-9/._-]+$ && $initrd_path =~ ^/[a-zA-Z0-9/._-]+$ ]] || die 'Invalid GRUB file paths'
    args="auto=true priority=critical preseed/file=/preseed.cfg reos_disk=$Disk"
    [[ -z $DiskID ]] || args+=" reos_disk_id=$DiskID"
    [[ -z $RootPartUUID ]] || args+=" reos_root_partuuid=$RootPartUUID"
    if (( ${#KeepParts[@]} )); then keep=$(IFS=,; printf '%s' "${KeepParts[*]}"); args+=" reos_keep=$keep"; fi
    cp -p /etc/grub.d/40_custom "$WORK/40_custom.backup"
    [[ ! -e /etc/default/grub.d/zz-reos.cfg ]] || cp -p /etc/default/grub.d/zz-reos.cfg "$WORK/default.backup"
    for env in grub grub2; do [[ ! -f /boot/$env/grubenv ]] || cp -p "/boot/$env/grubenv" "$WORK/$env.grubenv"; done
    strip_grub /etc/grub.d/40_custom > "$WORK/40_custom.new"
    cat >> "$WORK/40_custom.new" <<GRUB
### BEGIN reos ###
menuentry 'Debian Installer (reos)' --id reos {
    insmod part_msdos
    insmod part_gpt
    insmod ext2
    insmod xfs
    insmod btrfs
    search --no-floppy --fs-uuid --set=root $uuid
    linux $linux_path $args
    initrd $initrd_path $firmware_path
}
### END reos ###
GRUB
    trap commit_cleanup EXIT
    COMMIT_STARTED=1
    if [[ -e /boot/reos ]]; then
        BOOT_BACKUP=$(mktemp -d /boot/.reos-backup.XXXXXXXX)
        rmdir "$BOOT_BACKUP"
        mv /boot/reos "$BOOT_BACKUP"
        BOOT_MOVED=1
    else : > "$WORK/no-previous-boot"; fi
    mkdir -m700 /boot/reos
    install -m600 "$WORK/linux" /boot/reos/linux
    install -m600 "$WORK/final-initrd.gz" /boot/reos/initrd.gz
    (( !Firmware )) || install -m600 "$WORK/firmware.cpio.gz" /boot/reos/firmware.cpio.gz
    mkdir -p /etc/default/grub.d
    printf '# Added by reos\nGRUB_DEFAULT=saved\nGRUB_TIMEOUT=5\nGRUB_TIMEOUT_STYLE=menu\n' > /etc/default/grub.d/zz-reos.cfg
    chmod 644 /etc/default/grub.d/zz-reos.cfg
    install -m755 "$WORK/40_custom.new" /etc/grub.d/40_custom
    update-grub
    grub-reboot reos
    COMMITTED=1
    [[ -z $BOOT_BACKUP ]] || rm -rf -- "$BOOT_BACKUP"
}
prepare() {
    environment_check
    [[ ! -L /boot/reos ]] || die 'Refusing a symlink installer directory'
    exec 9>/run/lock/reos.lock
    flock -n 9 || die 'Another reos process is running'
    scratch
    [[ ! -L /var/log/reos.log ]] || die 'Refusing a symlink preparation log'
    touch /var/log/reos.log; chmod 600 /var/log/reos.log; LOG_ACTIVE=1
    mirrors
    resolve_suite
    detect_arch
    detect_disk
    detect_network
    preserve_partitions
    Password=${Password:-$(openssl rand -hex 12)}
    PasswordHash=$(printf '%s\n' "$Password" | openssl passwd -6 -stdin)
    if [[ -n $AuthorizedKeysURL ]]; then
        prepare_keys
    fi
    if [[ -n $PostInstall ]]; then
        case $PostInstall in
            http://*|https://*) fetch "$PostInstall" "$WORK/post-install" 1048576 || die 'Cannot fetch post-install script';;
            *) read_local "$PostInstall" > "$WORK/post-install";;
        esac
        PostInstallB64=$(base64 -w0 "$WORK/post-install")
    fi
    local base
    DownloadBases=()
    for base in "${Mirrors[@]}"; do DownloadBases+=("$base/dists/$Suite/main/installer-$Arch/current/images/netboot/debian-installer/$Arch"); done
    SelectedMirror=${Mirrors[0]}
    message 'Downloading and verifying installer kernel and initrd ...'
    installer_download_set "$WORK" linux initrd.gz
    # Use the authenticated installer mirror for the target package repository.
    SelectedMirror=${DownloadMirror%%/dists/*}
    if (( Firmware )); then
        local saved_bases=("${DownloadBases[@]}")
        DownloadBases=("https://cdimage.debian.org/cdimage/unofficial/non-free/firmware/$Suite/current")
        installer_download firmware.cpio.gz "$WORK/firmware.cpio.gz"
        DownloadBases=("${saved_bases[@]}")
    fi
    configure_payload
    InitrdRoot=$WORK/initrd
    mkdir "$InitrdRoot"
    # Signed Debian initrds contain relative archive names. Validate before extraction.
    gzip -dc "$WORK/initrd.gz" > "$WORK/initrd.cpio"
    cpio -it --quiet < "$WORK/initrd.cpio" > "$WORK/initrd.names"
    if grep -Eq '(^/|(^|/)\.\.(/|$))' "$WORK/initrd.names"; then die 'Unsafe path in installer initrd'; fi
    (cd "$InitrdRoot"; cpio -idmu --quiet --no-absolute-filenames < "$WORK/initrd.cpio")
    if (( InstallerSSH )); then message 'Preparing installer SSH components ...'; inject_udebs; fi
    # Payload lives in a separate archive appended after the original initrd.
    mkdir "$WORK/payload"
    write_payload "$WORK/payload"
    (cd "$InitrdRoot"; find . -print0 | cpio --null -o -H newc --quiet | gzip -1) > "$WORK/final-initrd.gz"
    (cd "$WORK/payload"; find . -print0 | cpio --null -o -H newc --quiet | gzip -1) >> "$WORK/final-initrd.gz"
    local needed available
    needed=$(du -ck "$WORK/linux" "$WORK/final-initrd.gz" "$WORK"/firmware.cpio.gz 2>/dev/null | tail -n1 | awk '{print $1}' || true)
    available=$(df -Pk /boot | awk 'END {print $4}')
    (( available > needed+10240 )) || die 'Insufficient free space in /boot'
    summary
    if (( !Yes )); then
        local answer=
        printf '\nNext boot will repartition %s and erase the current system. Continue? [y/N]: ' "$Disk"
        if ! read -r answer < /dev/tty; then die 'Confirmation needs a terminal; use --yes for unattended execution'; fi
        case ${answer,,} in y|yes) ;; *) message 'Canceled; boot configuration unchanged.'; return 0;; esac
    fi
    commit_boot
    message 'Preparation complete; one-time Debian installer boot configured.'
    completion_banner
    if (( RebootNow )); then sync; reboot; fi
}
