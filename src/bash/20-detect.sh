detect_arch() {
    Arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
    case $Arch in x86_64|amd64) Arch=amd64;; aarch64|arm64) Arch=arm64;; *) die "Unsupported architecture: $Arch";; esac
    if (( CloudKernel )); then Kernel=linux-image-cloud-$Arch; else Kernel=linux-image-$Arch; fi
}
detect_disk() {
    local candidates=() dev type label
    RootDevice=$(findmnt -nro SOURCE / 2>/dev/null || true); RootDevice=${RootDevice%%\[*}
    if [[ -z $Disk ]]; then
        while read -r dev type; do [[ $type != disk ]] || candidates+=("$dev"); done < <(lsblk -sprno NAME,TYPE "$RootDevice" 2>/dev/null | sort -u)
        if (( ${#candidates[@]} == 1 )); then Disk=${candidates[0]}
        elif (( DryRun )); then Disk='/dev/sda'; message 'Preview: disk detection unavailable; /dev/sda is an example'
        else die 'Cannot identify one root disk; specify --disk'; fi
    fi
    [[ $Disk =~ ^/dev/[a-zA-Z0-9_./-]+$ ]] || die 'Invalid detected disk'
    if (( !DryRun )); then
        [[ -b $Disk ]] || die "Not a block device: $Disk"
        [[ $(lsblk -dnro TYPE "$Disk") == disk ]] || die '--disk must name a whole physical or virtual disk'
    fi
    label=$(lsblk -dnro PTTYPE "$Disk" 2>/dev/null || true)
    case $label in dos|msdos) DiskLabel=msdos;; gpt|'') DiskLabel=gpt;; *) die "Unsupported partition table: $label";; esac
    EFI=0
    if [[ -d /sys/firmware/efi ]]; then EFI=1; fi
    if (( EFI )) && [[ $DiskLabel != gpt ]]; then
        (( ${#KeepPaths[@]} == 0 )) || die 'UEFI partition preservation requires GPT'
        DiskLabel=gpt
    fi
    DiskID=$(lsblk -dnro PTUUID "$Disk" 2>/dev/null | tr 'A-F' 'a-f' | tr -d '{} ' || true); DiskID=${DiskID#0x}
    RootPartUUID=$(lsblk -rno TYPE,PARTUUID "$Disk" 2>/dev/null | awk '$1=="part" && NF==2 {print $2; exit}' || true)
    [[ -z $DiskID || $DiskID =~ ^[a-f0-9-]+$ ]] || die 'Invalid disk identifier'
    [[ -z $RootPartUUID || $RootPartUUID =~ ^[a-fA-F0-9-]+$ ]] || die 'Invalid partition identifier'
    if (( SystemSizeMB && !DryRun )); then
        local bytes overhead=5
        (( !EFI )) || overhead=$((ESPSize+4))
        bytes=$(lsblk -bdnro SIZE "$Disk")
        (( bytes >= (SystemSizeMB+overhead)*1000000 )) || die '--system-size exceeds disk capacity'
    fi
}
preserve_partitions() {
    (( ${#KeepPaths[@]} > 0 )) || return 0
    local dev type fs uuid mount num data_index=0 pass path found row
    local rows=() root_chain
    root_chain=$(lsblk -sprno NAME "$RootDevice" 2>/dev/null || true)
    while read -r dev type fs uuid mount; do
        [[ $type == part ]] || continue
        # Read columns independently so missing values cannot shift fields.
        fs=$(lsblk -dnro FSTYPE "$dev"); uuid=$(lsblk -dnro PARTUUID "$dev"); mount=$(lsblk -dnro MOUNTPOINT "$dev")
        rows+=("$dev|$fs|$uuid|$mount")
    done < <(lsblk -prno NAME,TYPE "$Disk")
    for path in "${KeepPaths[@]}"; do
        found=0
        for row in "${rows[@]}"; do
            IFS='|' read -r dev fs uuid mount <<< "$row"
            [[ $dev == "$path" ]] || continue
            found=1
            [[ $dev != "$RootDevice" && -n $fs && $fs != swap ]] || die "Cannot preserve root/swap/unknown filesystem: $dev"
            ! grep -Fxq "$dev" <<< "$root_chain" || die "Cannot preserve a root filesystem ancestor: $dev"
            case $mount in /|/boot|/boot/efi|/usr|/var|/etc|/tmp) die "Cannot preserve system mount: $dev ($mount)";; esac
            num=${dev##*[!0-9]}; [[ $num =~ ^[0-9]+$ ]] || die "Unknown partition number: $dev"
            [[ $DiskLabel != msdos || $num -le 4 ]] || die 'Cannot preserve logical partitions on an msdos disk'
            KeepParts+=("$num")
            case $fs in
                ext2|ext3|ext4|xfs|btrfs)
                    [[ $uuid =~ ^[a-fA-F0-9-]+$ ]] || die "Missing PARTUUID: $dev"
                    ((data_index+=1)); mount=/data; (( data_index == 1 )) || mount=/data$data_index
                    pass=2; [[ $fs != btrfs ]] || pass=0
                    KeepFstab+=("$uuid|$mount|$fs|$pass");;
            esac
            message "Preserve $dev ($fs)"; break
        done
        (( found )) || die "Partition $path does not belong to $Disk"
    done
    message 'Preservation uses the largest free region; all unpreserved partitions may be deleted.'
}

route_field() { awk -v name="$1" '{for(i=1;i<NF;i++) if($i==name) {print $(i+1); exit}}'; }
read_system_dns() {
    awk '$1=="nameserver" {
        address=tolower($2)
        if (address !~ /^127\./ && address != "::1" && address != "100.100.100.100" && address != "fd7a:115c:a1e0::53") printf "%s ", $2
    }' "${1:-/etc/resolv.conf}" 2>/dev/null || true
}
detect_network() {
    local route4 route6 addr4 addr6 dynamic4=0 dynamic6=0 configured='' detected_gateway dns v6_mode=auto
    route4=$(ip -4 route show default 2>/dev/null | head -n1 || true)
    route6=$(ip -6 route show default 2>/dev/null | head -n1 || true)
    if [[ $Interface == auto ]]; then
        Interface=$(printf '%s\n%s\n' "$route4" "$route6" | route_field dev)
        [[ -n $Interface ]] || Interface=$(ip -o link show up 2>/dev/null | awk -F': ' '$2!="lo" {sub(/@.*/,"",$2); print $2; exit}' || true)
    fi
    if [[ -z $Interface ]]; then
        (( DryRun )) || die 'Cannot detect network interface; specify --interface'
        Interface=eth0; message 'Preview: network detection unavailable; eth0 is an example'
    fi
    [[ $Interface =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]] || die 'Invalid detected interface name'
    if [[ $(printf '%s\n' "$route4" | route_field dev) != "$Interface" ]]; then
        route4=$(ip -4 route show default dev "$Interface" 2>/dev/null | head -n1 || true)
    fi
    addr4=$(ip -o -4 addr show dev "$Interface" scope global 2>/dev/null | head -n1 || true)
    local v6_interface
    v6_interface=$(printf '%s\n' "$route6" | route_field dev)
    v6_interface=${v6_interface:-$Interface}
    [[ -z $IPv6 ]] || v6_interface=$Interface
    [[ $v6_interface =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]] || die 'Invalid detected IPv6 interface'
    addr6=$(ip -o -6 addr show dev "$v6_interface" scope global 2>/dev/null | awk '!/ temporary / && !/ tentative / && !/ deprecated / {print; exit}' || true)
    [[ $addr4 != *' dynamic '* && $route4 != *' proto dhcp '* ]] || dynamic4=1
    [[ $addr6 != *' dynamic '* && $addr6 != *' mngtmpaddr '* && $route6 != *' proto ra '* ]] || dynamic6=1
    # ifupdown can retain a DHCP lease without the kernel dynamic flag.
    if command -v ifquery >/dev/null 2>&1; then configured=$(ifquery "$Interface" 2>/dev/null || true); fi
    [[ $configured != *'inet dhcp'* ]] || dynamic4=1
    if [[ $configured == *'inet6 dhcp'* ]] && (( ReleaseNumber < 13 )); then v6_mode=dhcp; fi
    detected_gateway=
    if [[ $(printf '%s\n' "$route4" | route_field dev) == "$Interface" ]]; then
        detected_gateway=$(printf '%s\n' "$route4" | route_field via)
    fi
    if [[ -n $IP ]]; then
        Static=1; [[ -n $Netmask ]] || Netmask=255.255.255.0; IPPrefix=$(mask_prefix "$Netmask")
    elif [[ -n $addr4 ]]; then
        IP=$(awk '{print $4}' <<< "$addr4"); IPPrefix=${IP#*/}; IP=${IP%/*}
        (( dynamic4 )) || Static=1
        Netmask=$(prefix_mask "$IPPrefix")
    fi
    [[ -n $Gateway ]] || Gateway=$detected_gateway
    [[ -n $IP ]] || Static=0
    if [[ -n $IPv6 ]]; then
        InstallerV6Address=${IPv6%/*}; InstallerV6Prefix=64
        [[ $IPv6 != */* ]] || InstallerV6Prefix=$((10#${IPv6##*/}))
        InstallerV6Interface=$Interface
    elif [[ -n $addr6 && $dynamic6 == 0 ]]; then
        IPv6=$(awk '{print $4}' <<< "$addr6"); InstallerV6Address=${IPv6%/*}; InstallerV6Prefix=${IPv6#*/}; InstallerV6Interface=$v6_interface
    fi
    InstallerV6Gateway=${IPv6Gateway:-$(printf '%s\n' "$route6" | route_field via)}
    InstallerV6Gateway=${InstallerV6Gateway%%%*}
    if (( !DNSExplicit )); then
        DNS=$(read_system_dns /etc/resolv.conf)
        if [[ -z $DNS ]]; then
            DNS='1.1.1.1 8.8.8.8'
        fi
    fi
    DNS="${DNS}${IPv6DNS:+ $IPv6DNS}"
    if [[ -z $IP && -n $IPv6 && $DNSExplicit == 0 && -z $IPv6DNS ]]; then DNS='2606:4700:4700::1111 2001:4860:4860::8888'; fi
    for dns in $DNS; do ipv4_number "$dns" >/dev/null || valid_ipv6 "$dns" || die "Invalid detected DNS: $dns"; done
    if (( Static )); then
        ipv4_number "$IP" >/dev/null || die 'Invalid detected IPv4'
        if [[ -n $Gateway ]]; then
            local ipnum gatewaynum mask
            ipnum=$(ipv4_number "$IP"); gatewaynum=$(ipv4_number "$Gateway") || die 'Invalid detected gateway'; mask=$(ipv4_number "$Netmask")
            (( (ipnum & mask) == (gatewaynum & mask) )) || InstallerOnlink=1
        fi
    fi
    [[ -n $IP || -z $InstallerV6Address ]] || InstallerOnlink=1
    if [[ -n $InstallerV6Address ]]; then
        valid_ipv6 "$InstallerV6Address" || die 'Invalid detected IPv6'
        [[ -z $InstallerV6Gateway ]] || valid_ipv6 "$InstallerV6Gateway" || die 'Invalid detected IPv6 gateway'
    fi
    Hostname=$(printf '%s' "${Hostname:-$(hostname)}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g;s/^-*//;s/-*$//' | cut -c1-63)
    Hostname=${Hostname:-localhost}
    Interfaces=$(render_interfaces)$'\n'
    ResolvConf=$(for dns in $DNS; do printf 'nameserver %s\n' "$dns"; done)$'\n'
}
render_interfaces() {
    printf 'source /etc/network/interfaces.d/*\nauto lo\niface lo inet loopback\n\n'
    local mac='' v6_iface=${InstallerV6Interface:-${v6_interface:-$Interface}}
    [[ ! -r /sys/class/net/$Interface/address ]] || mac=$(cat "/sys/class/net/$Interface/address")
    [[ -z $mac ]] || printf '# mac %s\n' "$mac"
    printf 'auto %s\n' "$Interface"
    if [[ -n $IP ]]; then
        if (( Static )); then
            printf 'iface %s inet static\n    address %s/%s\n' "$Interface" "$IP" "$IPPrefix"
            if [[ -n $Gateway ]]; then
                if (( InstallerOnlink )); then
                    printf '    post-up ip -4 route replace %s/32 dev %s\n    post-up ip -4 route replace default via %s dev %s onlink\n' "$Gateway" "$Interface" "$Gateway" "$Interface"
                else printf '    gateway %s\n' "$Gateway"; fi
            fi
        else printf 'iface %s inet dhcp\n' "$Interface"; fi
    fi
    [[ -z $DNS || -z $IP ]] || printf '    dns-nameservers %s\n' "$DNS"
    if [[ $v6_iface != "$Interface" && ( -n $InstallerV6Address || -n ${addr6:-} ) ]]; then
        mac=
        [[ ! -r /sys/class/net/$v6_iface/address ]] || mac=$(cat "/sys/class/net/$v6_iface/address")
        [[ -z $mac ]] || printf '\n# mac %s\n' "$mac"
        printf 'auto %s\n' "$v6_iface"
    fi
    if [[ -n $InstallerV6Address ]]; then
        printf '\niface %s inet6 static\n    address %s/%s\n    pre-up sysctl -w net.ipv6.conf.%s.accept_ra=0\n    pre-up sysctl -w net.ipv6.conf.%s.autoconf=0\n' "$v6_iface" "$InstallerV6Address" "$InstallerV6Prefix" "$v6_iface" "$v6_iface"
        if [[ -n $InstallerV6Gateway ]]; then
            printf '    post-up ip -6 route replace %s/128 dev %s\n    post-up ip -6 route replace default via %s dev %s onlink\n' "$InstallerV6Gateway" "$v6_iface" "$InstallerV6Gateway" "$v6_iface"
        fi
    elif [[ -n ${addr6:-} ]]; then
        printf '\niface %s inet6 %s\n    accept_ra 2\n' "$v6_iface" "${v6_mode:-auto}"
    fi
    if [[ -n $InstallerV6Address || -n ${addr6:-} ]]; then [[ -z $DNS ]] || printf '    dns-nameservers %s\n' "$DNS"; fi
}

environment_check() {
    (( EUID == 0 )) || die 'Root privileges required'
    [[ $(uname -s) == Linux ]] || die 'Preparation requires Linux'
    [[ -f /etc/debian_version ]] || die 'Preparation requires Debian'
    [[ -f /etc/grub.d/40_custom ]] || die 'GRUB2 /etc/grub.d/40_custom not found'
    local virt=none code=0 secure mem tool
    if command -v systemd-detect-virt >/dev/null 2>&1; then virt=$(systemd-detect-virt) || code=$?; fi
    if (( Firmware )); then
        need systemd-detect-virt
        [[ $virt == none && $code == 1 ]] || die '--firmware requires confirmed physical hardware'
    fi
    [[ ! -e /.dockerenv && ! -e /run/.containerenv ]] || die 'Cannot prepare a container'
    case $virt in docker|lxc*|podman|systemd-nspawn|openvz) die 'Cannot prepare a container';; esac
    ! grep -qi microsoft /proc/version || die 'WSL preparation is unsupported'
    for secure in /sys/firmware/efi/efivars/SecureBoot-*; do
        [[ -f $secure ]] || continue
        [[ $(od -An -tu1 -j4 -N1 "$secure" | tr -d ' ') != 1 ]] || die 'Disable Secure Boot before preparing'
    done
    mem=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)
    (( mem >= 384 )) || die 'At least 384 MB RAM required'
    for tool in curl gzip cpio dpkg-deb ip lsblk findmnt blkid sha256sum openssl awk sed find sort stat flock grub-mkrelpath grub-probe grub-reboot update-grub; do need "$tool"; done
    need gpgv; [[ -r ${Keyring:-/usr/share/keyrings/debian-archive-keyring.gpg} ]] || die 'Trusted Debian keyring missing'
    [[ -z $AuthorizedKeysURL ]] || need ssh-keygen
    if (( Firmware )) && [[ -z $Keyring ]]; then [[ -r /usr/share/keyrings/debian-role-keys.gpg ]] || die 'Firmware verification needs debian-keyring'; fi
}
