# reos

Reinstall Debian over the network by preparing the installer and a one-time GRUB boot entry.

**Warning:** reinstallation repartitions the target disk and erases the current system. Keep backups and console or provider recovery access before proceeding.

## Quick start

On an existing Debian system with root access, GRUB2 and Secure Boot disabled, run as root:

```sh
curl -fL https://raw.githubusercontent.com/lovez-dev/reos/main/reos.sh -o reos.sh
chmod +x reos.sh
sudo ./reos.sh --yes --reboot-now --user admin --password 'YOUR_STRONG_PASSWORD'
```

The script updates Debian package indexes, installs its host dependencies, verifies the downloaded installer files, prepares the installer files and a one-time GRUB entry, skips confirmation, and reboots into the reinstallation. The login password is shown once after preparation; save it before the machine reboots.

Stable release detection, kernel/initrd downloads, and the installer SSH package index use Debian's signed release metadata. If the default Debian keyring lacks an archive key, `reos` can use official Debian HTTPS metadata over TLS and prints a warning; downloaded installer files and the package index are still checked against SHA-256 digests in that metadata. Custom mirrors and an explicitly selected keyring do not use this fallback.

To preview the configuration without downloading installer files or changing boot configuration:

```sh
sudo ./reos.sh --dry-run --version 13
```

## Managing a prepared installation

After preparation and before reboot, the `reos` command inspects or cancels the pending reinstallation:

```sh
reos status          # Installer files, GRUB entry and lifecycle status.
reos logs            # Preparation log (also: logs firstboot|cleanup|all).
reos reset           # Cancel: remove the GRUB entry and installer files.
```

`reos` persists on the running system only until reboot. These commands are unavailable in the newly installed system.

## Options

`--version` selects the Debian release (12, 13, or the dynamically resolved `stable`); `-V` / `--program-version` prints the reos version. Boolean options accept `=true` or `=false`. Run `reos --help` for the built-in reference.

| Option | Behavior |
| --- | --- |
| `--version VERSION` | Debian 12/13 or their codenames; defaults to `stable`. |
| `--mirror URL` | Debian mirror; defaults to `https://deb.debian.org/debian`. |
| `--proxy URL` | Proxy for downloads, installation and target APT; accepts HTTP, HTTPS, SOCKS5 and SOCKS5h. |
| `--ip ADDR`, `--netmask MASK`, `--gateway ADDR` | Static IPv4 configuration; an omitted gateway is inherited from the selected interface's default route. |
| `--ipv6 ADDR[/PREFIX]` | Static IPv6 address; retains the detected gateway unless overridden. |
| `--ipv6-gateway ADDR` | Explicit IPv6 gateway; requires `--ipv6`. |
| `--dns "ADDR ..."`, `--ipv6-dns "ADDR ..."` | DNS overrides; otherwise retain detected DNS with public fallback. |
| `--hostname NAME` | Hostname; defaults to the current hostname. |
| `--interface NAME` | Network interface; auto-detected from the default route. |
| `--user NAME` | Login account; defaults to `root`. |
| `--password PASS` | Login password; generated and shown once if omitted. |
| `--ssh-port N` | SSH port for installer and target system; defaults to 22. |
| `--authorized-keys-url URL` | Install SSH public keys and disable password authentication; keys are validated before boot changes. |
| `--disk /dev/vda` | Target disk; defaults to the disk holding the current root filesystem. |
| `--esp MB` | EFI system partition size; minimum and default 106 MB. |
| `--system-size SIZE` | Cap the root partition, e.g. `10G`; minimum 2G. Remaining space stays unallocated. |
| `--keep-part /dev/vda3` | Preserve an explicitly named partition; repeatable. |
| `--install "PKG ..."` | Add packages to the default `ca-certificates curl` set. |
| `--post-install PATH\|URL` | First-boot script; local file or HTTP(S) URL, up to 1 MiB. |
| `--firmware` | Include non-free firmware; physical machines only. |
| `--swap-size SIZE` | Swapfile size, e.g. `512M`, `2G`, `2048MB`; range 64M to 1T. |
| `--timezone ZONE` | Time zone; defaults to `UTC`. |
| `--ntp HOST` | NTP server; defaults to `time.cloudflare.com`. |
| `--cloud-kernel` | Use `linux-image-cloud-ARCH` instead of `linux-image-ARCH`. |
| `--optimize=false` | Disable first-boot tuning. |
| `--unattended=false` | Disable automatic security updates. |
| `--installer-ssh=false` | Disable installer SSH. |
| `--keyring PATH` | Local trusted GPG keyring override. |
| `--dry-run` | Preview configuration without preparing an installation. |
| `--yes` | Skip confirmation. |
| `--reboot-now` | Reboot immediately after preparation. |
| `-V`, `--program-version` | Display the reos version. |

## License

[MIT](LICENSE)
