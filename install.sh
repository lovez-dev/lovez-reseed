#!/bin/sh
# Install the architecture-independent Bash script from the current main commit.
# Usage:
#   Install only:
#     curl -fsSL https://raw.githubusercontent.com/lovez-dev/reos/main/install.sh | sh
#   Install and run reos with the remaining arguments:
#     curl -fsSL .../install.sh | sudo bash -s -- --yes --user admin --password '...'
set -eu

REPO=lovez-dev/reos
PREFIX=/usr/local/bin

command -v curl >/dev/null 2>&1 || { echo "curl is required; install it first" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum (coreutils) is required" >&2; exit 1; }

if [ "$(uname -s)" = "Linux" ]; then
    :
else
    echo "reos supports Linux only" >&2
    exit 1
fi

DRY_RUN=0
for arg do
    case "$arg" in
        --dry-run | --dry-run=true | --dry-run=t | --dry-run=1) DRY_RUN=1 ;;
        --dry-run=false | --dry-run=f | --dry-run=0) DRY_RUN=0 ;;
    esac
done

if [ "$(id -u)" -eq 0 ]; then
    if [ ! -r /etc/os-release ]; then
        echo "Cannot identify the current operating system; Debian is required" >&2
        exit 1
    fi
    . /etc/os-release
    if [ "${ID:-}" != "debian" ]; then
        echo "Automatic dependency setup supports Debian only (detected: ${ID:-unknown})" >&2
        exit 1
    fi
    if [ "$DRY_RUN" -eq 0 ]; then
        echo "Updating Debian package indexes and installing reos dependencies ..."
        apt-get update
        apt-get install -y --no-install-recommends \
            bash ca-certificates coreutils cpio curl debian-archive-keyring debian-keyring \
            dpkg findutils gawk gpgv grep grub-common grub2-common gzip iproute2 openssh-client openssl sed util-linux
    fi
elif [ "$DRY_RUN" -eq 0 ]; then
    echo "Root privileges are required to prepare Debian dependencies" >&2
    exit 1
elif [ ! -w "$PREFIX" ]; then
    echo "Root privileges or write access to $PREFIX are required" >&2
    exit 1
fi

# Pin both files to one commit so a concurrent push cannot mix versions.
COMMIT=$(curl -fsSL --retry 3 --connect-timeout 15 \
    -H 'Accept: application/vnd.github.sha' "https://api.github.com/repos/$REPO/commits/main")
case "$COMMIT" in '' | *[!0-9a-f]*) echo "Cannot resolve main commit" >&2; exit 1 ;; esac
[ "${#COMMIT}" -eq 40 ] || { echo "Invalid main commit" >&2; exit 1; }
BASE="https://raw.githubusercontent.com/$REPO/$COMMIT"

INSTALL_TMP="$(mktemp -d)"
trap 'rm -rf "$INSTALL_TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Downloading $BASE/reos.sh ..."
curl -fL --retry 3 --connect-timeout 15 -o "$INSTALL_TMP/reos.sh" "$BASE/reos.sh"
curl -fL --retry 3 --connect-timeout 15 -o "$INSTALL_TMP/sha256sums.txt" "$BASE/sha256sums.txt"

line="$(grep -E ' [*]?reos\.sh$' "$INSTALL_TMP/sha256sums.txt" || true)"
if [ -z "$line" ]; then
    echo "reos.sh is missing from sha256sums.txt" >&2
    exit 1
fi
(
    cd "$INSTALL_TMP"
    printf '%s\n' "$line" | sha256sum -c -
)

bash -n "$INSTALL_TMP/reos.sh"
install -m 0755 "$INSTALL_TMP/reos.sh" "$PREFIX/reos"
echo "Installed: $PREFIX/reos"

# Run reos immediately when arguments are provided.
if [ "$#" -gt 0 ]; then
    "$PREFIX/reos" "$@"
    exit 0
fi

"$PREFIX/reos" -V
