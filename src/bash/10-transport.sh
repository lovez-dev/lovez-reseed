fetch() {
    local url=$1 dest=$2 limit=${3:-67108864}
    local protocols=http,https
    official_debian_mirror "$url" && protocols=https
    local args=(--silent --show-error --fail --location --retry 2 --connect-timeout 15 --max-time 1800 --max-filesize "$limit" --proto "=$protocols" --proto-redir "=$protocols")
    [[ -z $Proxy ]] || args+=(--proxy "$Proxy")
    curl "${args[@]}" --output "$dest" --url "$url" || return 1
    [[ $(stat -c %s "$dest") -le $limit ]]
}
keyring_args() {
    KeyringArgs=(--homedir "$WORK" --keyring "${Keyring:-/usr/share/keyrings/debian-archive-keyring.gpg}")
    if [[ -z $Keyring && -f /usr/share/keyrings/debian-role-keys.gpg ]]; then KeyringArgs+=(--keyring /usr/share/keyrings/debian-role-keys.gpg); fi
}
release_file() {
    local base=$1 suite=$2 out=$3
    keyring_args
    if fetch "$base/dists/$suite/InRelease" "$out.signed" 16777216; then
        gpgv "${KeyringArgs[@]}" --output "$out" "$out.signed" 2>"$WORK/gpg-error" || return 1
    else
        fetch "$base/dists/$suite/Release" "$out" 16777216 || return 1
        fetch "$base/dists/$suite/Release.gpg" "$out.sig" 1048576 || return 1
        gpgv "${KeyringArgs[@]}" "$out.sig" "$out" 2>"$WORK/gpg-error" || return 1
    fi
    local code
    code=$(sed -n 's/^Codename: *//p' "$out")
    case $suite in stable) [[ $code =~ ^[a-z]+$ ]];; *) [[ $code == "$suite" ]];; esac
}
release_digest() {
    # Only SHA256 entries count; reject duplicate paths and malformed entries.
    awk -v path="$2" '
      /^SHA256:$/ {active=1; next}
      /^[^ \t]/ {active=0}
      active && $3 == path {count++; hash=$1; size=$2; fields=NF}
      END {if(count != 1 || fields != 3 || length(hash) != 64 || hash ~ /[^0-9a-fA-F]/ || size !~ /^[0-9]+$/) exit 1; print tolower(hash),size}
    ' "$1"
}
check_digest() {
    local file=$1 hash=$2 size=${3:-}
    [[ $hash =~ ^[0-9a-fA-F]{64}$ ]] || return 1
    [[ -z $size || $(stat -c %s "$file") == "$size" ]] || return 1
    [[ $(sha256sum "$file" | cut -d' ' -f1) == "${hash,,}" ]]
}
authenticate() {
    local url=$1 file=$2 rest base suite path digest hash size
    : > "$WORK/gpg-error"
    if [[ $url == */dists/* ]]; then
        base=${url%%/dists/*}; rest=${url#*/dists/}; suite=${rest%%/*}; path=${rest#*/}
        release_file "$base" "$suite" "$WORK/auth-release" || return 1
        digest=$(release_digest "$WORK/auth-release" "$path") || return 1
        read -r hash size <<< "$digest"
        check_digest "$file" "$hash" "$size"
    else
        fetch "$url.sign" "$WORK/detached.sig" 1048576 || fetch "$url.gpg" "$WORK/detached.sig" 1048576 || return 1
        keyring_args
        gpgv "${KeyringArgs[@]}" "$WORK/detached.sig" "$file" 2>"$WORK/gpg-error"
    fi
}
official_debian_mirror() {
    case $1 in
        https://deb.debian.org/debian/*|https://cdn-aws.deb.debian.org/debian/*|https://ftp.debian.org/debian/*|https://archive.debian.org/debian/*) return 0;;
        *) return 1;;
    esac
}
missing_archive_key() {
    [[ -s $WORK/gpg-error ]] || return 1
    grep -Eiq 'NO_PUBKEY|no public key|public key not found' "$WORK/gpg-error"
}
mirrors() {
    Mirrors=()
    [[ -z $Mirror ]] || Mirrors+=("${Mirror%/}")
    Mirrors+=(https://deb.debian.org/debian https://cdn-aws.deb.debian.org/debian https://ftp.debian.org/debian https://archive.debian.org/debian)
}
resolve_suite() {
    local base code version input=${Suite,,}
    if [[ -z $input || $input == stable ]]; then
        if (( DryRun )); then input=13
        else
            for base in "${Mirrors[@]}"; do
                if release_file "$base" stable "$WORK/stable-release"; then
                    code=$(sed -n 's/^Codename: *//p' "$WORK/stable-release")
                    version=$(sed -n 's/^Version: *//p' "$WORK/stable-release"); version=${version%%.*}
                    [[ $code =~ ^[a-z]{3,20}$ && $version =~ ^[0-9]{1,3}$ ]] || continue
                    case $code in stable|testing|unstable|sid|bullseye) continue;; esac
                    (( 10#$version >= 12 )) || continue
                    Suite=$code; ReleaseNumber=$((10#$version))
                    return 0
                fi
            done
            die 'Cannot authenticate and resolve stable metadata; specify --version 12 or 13, or update the keyring'
        fi
    fi
    case $input in
        12|bookworm) Suite=bookworm; ReleaseNumber=12;;
        13|trixie) Suite=trixie; ReleaseNumber=13;;
        *) die "Unsupported Debian release: $input (use 12, 13 or stable)";;
    esac
}
installer_download_set() {
    local directory=$1
    shift
    local base parent url prefix name entry hash index complete found=0 authenticated
    local names=("$@") urls=() hashes=()
    mkdir -p -- "$directory"
    for base in "${DownloadBases[@]}"; do
        urls=(); prefix=; authenticated=0
        if [[ $base == */netboot/* ]]; then
            parent=${base%%/netboot/*}; prefix=${base#"$parent"/}
            urls+=("$parent/SHA256SUMS")
        else
            urls+=("$base/SHA256SUMS")
        fi
        hashes=()
        for url in "${urls[@]}"; do
            fetch "$url" "$WORK/SHA256SUMS" 1048576 || continue
            if authenticate "$url" "$WORK/SHA256SUMS"; then
                authenticated=1
            elif official_debian_mirror "$base" && missing_archive_key; then
                message "Archive signing key is unavailable; using HTTPS SHA-256 manifest from $url"
            else
                continue
            fi
            hashes=()
            for name in "${names[@]}"; do
                entry=$name
                [[ $url == "$base/SHA256SUMS" ]] || entry=$prefix/$name
                hash=$(awk -v want="$entry" '{p=$2; sub(/^\*/,"",p); sub(/^\.\//,"",p); if(p==want) {n++; h=$1}} END {if(n==1 && length(h)==64 && h !~ /[^a-fA-F0-9]/) print tolower(h)}' "$WORK/SHA256SUMS")
                [[ -n $hash ]] || break
                hashes+=("$hash")
            done
            (( ${#hashes[@]} != ${#names[@]} )) || break
        done
        if (( ${#hashes[@]} != ${#names[@]} )); then
            message "No complete SHA-256 set at $base; trying next mirror"; continue
        fi
        (( authenticated )) || message 'Warning: installer manifest was not GPG-authenticated; HTTPS and per-file SHA-256 checks passed.'
        # Read one manifest before downloading; retry the whole set on a new mirror.
        complete=1
        for index in "${!names[@]}"; do
            name=${names[index]}
            if ! fetch "$base/$name" "$directory/$name.part" 536870912; then complete=0; break; fi
            check_digest "$directory/$name.part" "${hashes[index]}" || die "SHA-256 mismatch: $name"
        done
        (( complete )) || continue
        for name in "${names[@]}"; do mv -f -- "$directory/$name.part" "$directory/$name"; done
        DownloadMirror=$base; found=1; break
    done
    (( found )) || die "No usable mirror for ${names[*]}"
}
installer_download() {
    local name=$1 output=$2
    installer_download_set "$WORK/download" "$name"
    mv -f -- "$WORK/download/$name" "$output"
}

inject_udebs() {
    local base path="main/debian-installer/binary-$Arch/Packages.gz" index_ok=0
    for base in "$SelectedMirror" https://deb.debian.org/debian; do
        fetch "$base/dists/$Suite/$path" "$WORK/Packages.gz" || continue
        authenticate "$base/dists/$Suite/$path" "$WORK/Packages.gz" || continue
        gzip -dc "$WORK/Packages.gz" > "$WORK/Packages" || continue
        index_ok=1; break
    done
    (( index_ok )) || die 'Cannot authenticate the installer package index'
    # Produce a dependency closure, selecting the first available alternative.
    awk '
      BEGIN {RS=""; FS="\n"}
      {name=""; file=""; hash=""; deps=""; field=""
       for(i=1;i<=NF;i++) {
         line=$i
         if(line ~ /^[ \t]/) {if(field=="Depends") deps=deps " " line; continue}
         split(line,x,": "); field=x[1]; sub(/^[^:]+: */,"",line)
         if(field=="Package") name=line
         if(field=="Filename") file=line
         if(field=="SHA256") hash=line
         if(field=="Depends") deps=line
       }
       if(name!="" && file!="") {files[name]=file; hashes[name]=hash; depends[name]=deps}}
      END {
       queue[1]="openssh-server-udeb"; queue[2]="screen-udeb"; end=2
       for(q=1;q<=end;q++) {
         p=queue[q]; if(seen[p]++) continue
         if(!(p in files)) {if(q<=2) exit 1; continue}
         print p "\t" files[p] "\t" hashes[p]
         n=split(depends[p],groups,",")
         for(i=1;i<=n;i++) {m=split(groups[i],alts,"|")
           for(j=1;j<=m;j++) {a=alts[j]; sub(/^[ \t]+/,"",a); sub(/[ (:].*$/,"",a)
             if(a in files) {queue[++end]=a; break}}}
       }
      }' "$WORK/Packages" > "$WORK/closure" || die 'Installer SSH packages unavailable'
    local package filename hash entry target
    mkdir -p "$WORK/udeb"
    while IFS=$'\t' read -r package filename hash; do
        [[ $filename == pool/* && $filename != *..* ]] || die 'Invalid installer package path'
        [[ $hash =~ ^[0-9a-fA-F]{64}$ ]] || die "Missing or invalid package checksum: $package"
        fetch "$base/$filename" "$WORK/package.udeb" || die "Cannot download $package"
        check_digest "$WORK/package.udeb" "$hash" || die "Package checksum mismatch: $package"
        # Extract in isolation, then merge only names absent from the original initrd.
        rm -rf -- "$WORK/udeb"; mkdir "$WORK/udeb"
        dpkg-deb -x "$WORK/package.udeb" "$WORK/udeb"
        while IFS= read -r -d '' entry; do
            target=$InitrdRoot/${entry#"$WORK/udeb/"}
            [[ ! -e $target && ! -L $target ]] || continue
            # Follow merged-/usr links only when they stay inside the unpacked initrd.
            target=$(realpath -m -- "$target")
            [[ $target == "$InitrdRoot/"* ]] || die "Symlink escapes installer payload: $target"
            if [[ -d $entry && ! -L $entry ]]; then mkdir -p -- "$target"; chmod --reference="$entry" "$target"
            else mkdir -p -- "${target%/*}"; cp -a -- "$entry" "$target"; fi
        done < <(find "$WORK/udeb" -mindepth 1 -print0 | sort -z)
    done < "$WORK/closure"
}
