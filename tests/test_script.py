#!/usr/bin/env python3
"""Safe regression tests: never write host boot configuration or reboot."""
import hashlib
import pathlib
import shlex
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'reos.sh'
TEST_TMP = ROOT / 'out' / 'tests'
TEST_TMP.mkdir(parents=True, exist_ok=True)
tempfile.tempdir = str(TEST_TMP)


def shell(code, ok=True):
    result = subprocess.run(['bash', '-c', 'source ' + shlex.quote(str(SCRIPT)) + '\ndefaults\n' + code], text=True, capture_output=True)
    if ok and result.returncode:
        raise AssertionError(f'{result.returncode}: {result.stderr}\n{result.stdout}')
    return result


class ScriptTests(unittest.TestCase):
    def test_silent_post_install_failure_retains_diagnostics(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / 'log').mkdir()
            (root / 'scripts').mkdir()
            script = shell('PostInstallB64=ZXhpdCA0Mg==; asset_firstboot_firstboot_sh_tmpl').stdout
            script = script.replace('/var/lib/reos', str(root / 'state'))
            script = script.replace('/var/log', str(root / 'log'))
            script = script.replace('/root/.reos', str(root / 'scripts'))
            script = 'systemctl() { :; }; getent() { :; };' + chr(10) + script
            result = subprocess.run(['sh', '-c', script], capture_output=True, text=True)
            self.assertEqual(result.returncode, 42)
            self.assertEqual((root / 'state/firstboot-status').read_text().strip(), 'failed: post-install (42)')
            self.assertIn('failed: post-install (42)', (root / 'log/reos-firstboot.log').read_text())
            self.assertTrue((root / 'scripts/post-install.sh').exists())

    def test_proxy_reaches_https_installer_and_normalizes_socks(self):
        for proxy, expected in [('http://proxy:8888', 'http://proxy:8888'), ('socks5://proxy:1080', 'socks5h://proxy:1080'), ('socks5h://proxy:1080', 'socks5h://proxy:1080')]:
            with self.subTest(proxy=proxy):
                rendered = shell('Proxy=' + shlex.quote(proxy) + '; configure_payload; asset_preseed_tmpl; asset_late_sh_tmpl').stdout
                self.assertIn('d-i mirror/http/proxy string ' + expected, rendered)
                self.assertIn('d-i mirror/https/proxy string ' + expected, rendered)
                self.assertIn('Acquire::https::Proxy ' + chr(34) + expected + chr(34), rendered)

    def test_hostname_is_forced_over_reverse_dns(self):
        rendered = shell('Hostname=reseed-selected; asset_preseed_tmpl; asset_late_sh_tmpl').stdout
        self.assertIn('d-i netcfg/hostname string reseed-selected', rendered)
        self.assertIn('\'reseed-selected\' > "$TARGET/etc/hostname"', rendered)
        self.assertIn('\'reseed-selected\' >> "$TARGET/etc/hosts"', rendered)

    def test_interface_rename_preserves_route_flags_and_ipv6_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            device = root / 'net/ens3'
            device.mkdir(parents=True)
            (device / 'address').write_text('02:00:00:00:00:01')
            interfaces = root / 'interfaces'
            original = '''auto lo
iface lo inet loopback
# mac 02:00:00:00:00:01
auto eth0
iface eth0 inet static
    post-up ip -4 route replace default via 192.0.2.1 dev eth0 onlink
iface eth0 inet6 static
    pre-up sysctl -w net.ipv6.conf.eth0.accept_ra=0
    pre-up sysctl -w net.ipv6.conf.eth0.autoconf=0
    post-up ip -6 route replace fe80::1/128 dev eth0
    post-up ip -6 route replace default via fe80::1 dev eth0 onlink
'''
            interfaces.write_text(original)
            script = (ROOT / 'src/assets/firstboot/fix-eth-name.sh').read_text()
            script = script.replace('IFACES=/etc/network/interfaces', 'IFACES=' + shlex.quote(str(interfaces)))
            script = script.replace('SYSFS=/sys/class/net', 'SYSFS=' + shlex.quote(str(root / 'net')))
            script = script.replace('sleep 1', ':')
            for source in [original, original.replace('eth0', 'ens3')]:
                interfaces.write_text(source)
                subprocess.run(['bash', '-c', script], check=True, capture_output=True)
                result = interfaces.read_text()
                self.assertEqual(result, original.replace('eth0', 'ens3').replace('# mac 02:00:00:00:00:01' + chr(10), ''))

    def test_completion_banner_password_and_connection(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        network = pathlib.Path(directory.name)
        (network / 'ens3').mkdir(parents=True, exist_ok=True)
        (network / 'ens3' / 'address').write_text('02:00:00:00:00:11')
        result = shell('''
Suite=trixie; Disk=/dev/vda; EFI=1; Hostname=web01; Interface=ens3; InstallerV6Interface=ens3
IP=192.0.2.10; Gateway=192.0.2.1; IPv6=2001:db8::10/64; InstallerV6Gateway=2001:db8::1
NetworkSysfs="'''+str(network.as_posix())+'''"
Username=admin; Password=unique-banner-secret; SSHPort=2222
message() { die 'Banner attempted to write to the log'; }
completion_banner
''')
        for expected in ['reos', 'READY TO REINSTALL',
                         'Debian installation starts on reboot.',
                         'Debian 13 (trixie) / amd64', '/dev/vda / ext4 / UEFI',
                         'web01', 'UTC', '192.0.2.10', '192.0.2.1', '2001:db8::10', '2001:db8::1',
                         '02:00:00:00:00:11 (ens3)',
                         'ssh -p 2222 admin@192.0.2.10',
                         'same account and port', 'tail -fn+1 /var/log/syslog',
                         'not written to the log', 'reboot',
                         'reos reset (before reboot)']:
            self.assertIn(expected, result.stdout)
        self.assertEqual(result.stdout.count('unique-banner-secret'), 1)
        self.assertNotIn(chr(27), result.stdout)

    def test_completion_banner_key_ipv6_preserve_and_reboot(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        network = pathlib.Path(directory.name)
        (network / 'ens3').mkdir(parents=True, exist_ok=True)
        (network / 'ens4').mkdir(parents=True, exist_ok=True)
        (network / 'ens3' / 'address').write_text('02:00:00:00:00:01')
        (network / 'ens4' / 'address').write_text('02:00:00:00:00:02')
        result = shell('''
Suite=bookworm; Disk=/dev/nvme0n1; Hostname=server; Interface=ens3; InstallerV6Interface=ens4
IPv6=2001:db8::10/64; InstallerV6Gateway=2001:db8::1; Password=hidden-banner-secret; AuthorizedKeys=ssh-ed25519
KeepPaths=(/dev/nvme0n1p3 /dev/nvme0n1p4); SystemSize=20G
InstallerSSH=0; RebootNow=1; NO_COLOR=1; NetworkSysfs="'''+str(network.as_posix())+'''"
completion_banner
''')
        for expected in ['Debian 12 (bookworm)', '/dev/nvme0n1 / ext4 / BIOS',
                         '20G', '/dev/nvme0n1p3 /dev/nvme0n1p4',
                         'SSH public key (SSH password login disabled)',
                         '02:00:00:00:00:02 (ens4)',
                         'ssh -p 22 root@2001:db8::10',
                         '2001:db8::10', '2001:db8::1',
                         'SSH disabled; use the server console',
                         'Rebooting automatically (--reboot-now)']:
            self.assertIn(expected, result.stdout)
        for absent in ['hidden-banner-secret', '2001:db8::10/64',
                       'tail -fn+1', 'reos reset', chr(27)]:
            self.assertNotIn(absent, result.stdout)

    def test_completion_banner_dynamic_release_and_unknown_address(self):
        result = shell('Suite=forky; ReleaseNumber=14; Disk=/dev/vda; completion_banner')
        self.assertIn('Debian 14 (forky)', result.stdout)
        self.assertIn('ssh -p 22 root@SERVER_IP', result.stdout)
        self.assertNotIn('Uses the configured address', result.stdout)

    def test_build_current_and_syntax(self):
        subprocess.run(['python3', str(ROOT / 'tools/build-script.py'), '--check'], check=True)
        subprocess.run(['bash', '-n', str(SCRIPT)], check=True)
        subprocess.run(['sh', '-n', str(ROOT / 'install.sh')], check=True)

    def test_preview_off_subnet_ipv6_and_secrets(self):
        result = subprocess.run(['bash', str(SCRIPT), '--dry-run', '--version', '13', '--disk', '/dev/vda', '--interface', 'eth0', '--ip', '192.0.2.10', '--netmask', '255.255.255.255', '--gateway', '198.51.100.1', '--ipv6', '2001:db8::10/128', '--ipv6-gateway', 'fe80::1', '--password', 'secret-value', '--system-size', '10G'], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for text in ['192.0.2.10/32', 'default via 198.51.100.1 dev eth0 onlink', '2001:db8::10/128', '10240 10240 10240']:
            self.assertIn(text, result.stdout)
        expected_boot = 'method{ efi }' if pathlib.Path('/sys/firmware/efi').is_dir() else 'method{ biosgrub }'
        self.assertIn(expected_boot, result.stdout)
        self.assertIn('d-i partman/default_filesystem string ext4', result.stdout)
        self.assertNotIn('secret-value', result.stdout)
        self.assertNotIn('{{', result.stdout)

    def test_validation(self):
        cases = [
            '--ssh-port 0', '--ssh-port 65536', '--esp 100', '--hold 0', '--hold 1', '--hold 2',
            '--hold 1 --installer-ssh=false', '--force-lowmem 0', '--force-lowmem 1', '--force-lowmem 2', '--force-lowmem 4', '--system-size 1G',
            '--upgrade none', '--upgrade safe', '--upgrade full',
            '--allow-unverified', '--allow-unverified=false',
            '--force', '--force=true', '--force=false',
            '--boot-mode auto', '--boot-mode bios', '--boot-mode efi',
            '--swap-size 1M', '--netmask 255.255.255.0', '--ip 999.1.1.1',
            '--ip 192.0.2.1 --netmask 255.0.255.0', '--ipv6 2001:::1',
            '--ipv6-gateway fe80::1', '--ipv6 ::1/129', '--user "root;id"',
            '--kernel linux-image-amd64', '--bpo-kernel',
            '--btrfs-compress zstd', '--filesystem ext4', '--filesystem xfs', '--filesystem btrfs',
            '--keep-data', '--verify-signatures=false', '--verify-signatures=true', '--verify-signatures',
            '--install "curl;id"', '--install "-o foo"', '--timezone ../etc/passwd',
            '--mirror "https://example.org/\"bad"', '--proxy "http://host/\"bad"',
            '--dns invalid', '--interface "eth0;id"', '--china', '--china=true', '--china=false', '--fail2ban', '--cidata /tmp/seed', '--apt-repo anything', '--unknown',
        ]
        for args in cases:
            with self.subTest(args=args):
                result = shell('parse ' + args + '\nvalidate\n', ok=False)
                self.assertNotEqual(result.returncode, 0)
        shell('parse --mirror https://example.org/debian --proxy socks5h://user:pass@host:1080 --dns "1.1.1.1 2606:4700:4700::1111" --ipv6 ::1/128\nvalidate')

    def test_extra_packages_defaults_overrides_and_dependencies(self):
        for args, expected, absent in [
            ('', ['ca-certificates', 'curl', 'ifupdown', 'unattended-upgrades'], ['sudo', 'wget', 'net-tools', 'unzip']),
            ('--install "git htop" --user admin', ['git', 'htop', 'ifupdown', 'sudo', 'unattended-upgrades'], ['curl', 'ca-certificates']),
            ('--install "" --unattended=false', ['ifupdown'], ['curl', 'sudo', 'unattended-upgrades']),
        ]:
            with self.subTest(args=args):
                result = shell(f'parse {args}\nvalidate\nconfigure_payload\nprintf "%s" "$Install"')
                packages = result.stdout.split()
                self.assertCountEqual(packages, expected)
                for name in absent:
                    self.assertNotIn(name, packages)

    def test_timezone_default_and_override(self):
        for args, expected in [('', 'UTC'), ('--timezone Europe/Berlin', 'Europe/Berlin')]:
            with self.subTest(args=args):
                result = shell(f'parse {args}\nvalidate\nasset_preseed_tmpl')
                self.assertIn('d-i time/zone string ' + expected, result.stdout)

    def test_default_and_cloud_kernel_selection(self):
        for arch in ['amd64', 'arm64']:
            for flag, prefix in [('', 'linux-image-'), ('--cloud-kernel', 'linux-image-cloud-')]:
                with self.subTest(arch=arch, flag=flag):
                    output = shell(f'''
dpkg() {{ printf '%s' {arch}; }}
parse --version 13 {flag}
validate
resolve_suite
detect_arch
asset_preseed_tmpl
''').stdout
                    self.assertIn('d-i base-installer/kernel/image string ' + prefix + arch, output)
                    self.assertNotIn('backports', output)
        result = shell('''
dpkg() { printf arm64; }
parse --version 11 --cloud-kernel
validate
resolve_suite
detect_arch
''', ok=False)
        self.assertNotEqual(result.returncode, 0)

    def test_manual_mirror_and_generic_network_defaults(self):
        shell('''
curl() { die 'Mirror selection attempted a speed test'; }
validate
[[ $NTP == time.cloudflare.com ]]
mirrors
[[ ${Mirrors[0]} == https://deb.debian.org/debian ]]
defaults
parse --mirror https://mirror.example/debian/ --dns '9.9.9.9' --ntp ntp.example
validate
mirrors
[[ ${Mirrors[0]} == https://mirror.example/debian && $DNS == 9.9.9.9 && $NTP == ntp.example ]]
defaults
ip() { :; }
awk() {
    case "$*" in *'/etc/resolv.conf'*) return 0;; *) command awk "$@";; esac
}
Interface=eth0
detect_network
[[ $DNS == '1.1.1.1 8.8.8.8' ]]
''')

    def test_supported_releases_and_dynamic_stable(self):
        for value, suite, number in [('12', 'bookworm', 12), ('bookworm', 'bookworm', 12), ('13', 'trixie', 13), ('TRIXIE', 'trixie', 13)]:
            shell(f'parse --version {value}; validate; resolve_suite; [[ $Suite == {suite} && $ReleaseNumber == {number} ]]')
        for value in ['11', 'bullseye', '14', 'forky', 'testing', 'sid', 'unstable', 'oldstable', 'oldoldstable']:
            with self.subTest(value=value):
                self.assertNotEqual(shell(f'parse --version {value}; validate; resolve_suite', ok=False).returncode, 0)
        for suite, version in [('bookworm', '12.9'), ('trixie', '13.2'), ('forky', '14.1')]:
            with self.subTest(dynamic=suite), tempfile.TemporaryDirectory() as temp:
                shell(f'''
WORK={shlex.quote(temp)}; Mirrors=(https://mirror.example/debian)
release_file() {{ [[ $2 == stable ]]; printf 'Codename: {suite}\nVersion: {version}\n' > "$3"; }}
resolve_suite
[[ $Suite == {suite} && $ReleaseNumber == {version.split('.')[0]} ]]
''')
        for metadata in ['Codename: sid\nVersion: 99', 'Codename: bullseye\nVersion: 11.9', 'Codename: trixie', 'Codename: trixie\nVersion: invalid']:
            with self.subTest(metadata=metadata), tempfile.TemporaryDirectory() as temp:
                result = shell(f'''
WORK={shlex.quote(temp)}; Mirrors=(https://mirror.example/debian)
release_file() {{ printf '%s\n' {shlex.quote(metadata)} > "$3"; }}
resolve_suite
''', ok=False)
                self.assertNotEqual(result.returncode, 0)
        shell("DryRun=1; fetch() { die 'Unexpected network access'; }; resolve_suite; [[ $Suite == trixie && $ReleaseNumber == 13 ]]")

    def test_template_branches_and_script_syntax(self):
        variants = [
            '',
            'EFI=1; Username=admin; SystemSizeMB=10240; InstallerSSH=1; Optimize=1; InstallerOnlink=1; IP=192.0.2.10; Gateway=198.51.100.1; InstallerV6Address=2001:db8::1; InstallerV6Gateway=fe80::1; InstallerV6Interface=eth0',
            'EFI=1; KeepParts=(3); KeepFstab=("1234-abcd|/data|ext4|2"); AuthorizedKeys=key; KeysB64=a2V5; PostInstallB64=ZWNobyBoaQ==; Swap=1; Proxy=http://proxy:8080',
            'SystemSizeMB=2048; Username=admin; AuthorizedKeys=key; KeysB64=a2V5',
        ]
        for variant in variants:
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as temp:
                code = f'''Interface=eth0; Disk=/dev/vda; PasswordHash='$6$salt$hash'; Hostname=example; Kernel=linux-image-amd64
{variant}
configure_payload
{variant}
write_payload {shlex.quote(temp)}/payload
'''
                shell(code)
                payload = pathlib.Path(temp) / 'payload'
                self.assertEqual(payload.stat().st_mode & 0o777, 0o755)
                for path in payload.rglob('*.sh'):
                    result = subprocess.run(['bash' if path.name == 'fix-eth-name.sh' else 'sh', '-n', str(path)], capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, str(path) + ': ' + result.stderr)
                for path in payload.rglob('*'):
                    if path.is_file():
                        self.assertNotIn('{{', path.read_text(), str(path))
                late = (payload / 'reos-assets/late.sh').read_text()
                firstboot = (payload / 'reos-assets/firstboot.sh').read_text()
                preseed = (payload / 'preseed.cfg').read_text()
                self.assertIn('d-i pkgsel/upgrade select full-upgrade', preseed)
                self.assertIn('method{ efi }' if 'EFI=1' in variant else 'method{ biosgrub }', preseed)
                self.assertTrue((payload / 'reos-assets/cleanup.sh').exists())
                self.assertNotIn('cloud-init', late)
                self.assertIn('WantedBy=multi-user.target', late)
                self.assertIn('APT::Periodic::Unattended-Upgrade', late)
                self.assertTrue((payload / 'reos-assets/optimize/10-sysctl.sh').exists())
                self.assertNotIn('reos-extra.list', late)
                self.assertNotIn('apt-get install', firstboot)
                self.assertNotIn('extra-repositories', firstboot)
                self.assertNotIn('btrfs', firstboot)
                self.assertNotIn('compress=', late)
                self.assertNotIn('wait.sh', late)
                self.assertFalse((payload / 'reos-assets/wait.sh').exists())
                self.assertFalse((payload / 'reos-assets/hold-before').exists())
                self.assertTrue((payload / 'reos-assets/installer-ssh.sh').exists())
                if 'KeysB64=a2V5' in variant:
                    self.assertIn('echo a2V5 | base64 -d', late)
                if 'InstallerV6Address=' in variant:
                    self.assertIn('2001:db8::1/64', (payload / 'var/lib/dpkg/info/netcfg.postinst').read_text())
                if 'KeepFstab=' in variant:
                    self.assertIn('PARTUUID=1234-abcd /data ext4 defaults,nofail 0 2', late)
                    self.assertIn('echo ZWNobyBoaQ== | base64 -d', firstboot)

    def test_authorized_keys_validation(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = pathlib.Path(temp)
            subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(directory / 'key')], check=True)
            key = (directory / 'key.pub').read_text().strip()
            setup = f'''WORK={shlex.quote(temp)}; AuthorizedKeysURL=https://keys.example/user
fetch() {{ cp "$WORK/input" "$2"; }}
'''
            for contents in [key, '# comment\r\n\r\n' + key + '\r\n', key + '\n' + key]:
                (directory / 'input').write_bytes(contents.encode())
                result = shell(setup + 'prepare_keys; printf "%s" "$AuthorizedKeys"')
                self.assertIn(key, result.stdout)
                self.assertNotIn(b'\r', (directory / 'keys').read_bytes())
            for contents in ['', ' \n# only comments\n', '<html>profile</html>', 'ssh-ed25519 invalid', key + '\n<html>error</html>', 'host.example ' + key, 'restrict ' + key]:
                with self.subTest(contents=contents):
                    (directory / 'input').write_text(contents)
                    self.assertNotEqual(shell(setup + 'prepare_keys', ok=False).returncode, 0)

    def test_security_repository_is_independent_of_package_mirror(self):
        for base in ['https://mirror.example/debian/packages', 'http://mirror.example/debian', 'https://deb.debian.org/debian']:
            result = shell('Suite=trixie; SelectedMirror=' + shlex.quote(base) + '; configure_payload; asset_preseed_tmpl; asset_installer_post_base_installer_sh_tmpl')
            self.assertIn('https://deb.debian.org/debian-security trixie-security main', result.stdout)
            self.assertNotIn('packages-security', result.stdout)

    def test_installer_pair_retries_both_files_from_one_manifest(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = pathlib.Path(temp)
            for mirror in ['a', 'b']:
                manifest = ''
                for name in ['linux', 'initrd.gz']:
                    data = (mirror + '-' + name).encode()
                    (directory / (mirror + '-' + name)).write_bytes(data)
                    manifest += hashlib.sha256(data).hexdigest() + '  ' + name + '\n'
                (directory / (mirror + '-sums')).write_text(manifest)
            setup = f'''WORK={shlex.quote(temp)}; DownloadBases=(https://a https://b)
fetch() {{
    local mirror=${{1#https://}}; mirror=${{mirror%%/*}}; local name=${{1##*/}}
    [[ $1 != https://a/initrd.gz ]] || return 1
    if [[ $name == SHA256SUMS ]]; then
        printf '%s\\n' "$1" >> "$WORK/manifests"
        cp "$WORK/$mirror-sums" "$2"
    else cp "$WORK/$mirror-$name" "$2"; fi
}}
authenticate() {{ return 0; }}
'''
            shell(setup + 'installer_download_set "$WORK/output" linux initrd.gz; [[ $DownloadMirror == https://b ]]')
            self.assertEqual((directory / 'output/linux').read_text(), 'b-linux')
            self.assertEqual((directory / 'output/initrd.gz').read_text(), 'b-initrd.gz')
            self.assertEqual((directory / 'manifests').read_text().splitlines(), ['https://a/SHA256SUMS', 'https://b/SHA256SUMS'])
            # An incomplete manifest cannot supply just one member of the pair.
            (directory / 'b-sums').write_text((directory / 'b-sums').read_text().splitlines()[0] + '\n')
            self.assertNotEqual(shell(setup + 'installer_download_set "$WORK/incomplete" linux initrd.gz', ok=False).returncode, 0)
            self.assertFalse((directory / 'incomplete/linux').exists())
            # Corruption fails immediately instead of selecting a different mirror.
            (directory / 'a-linux').write_text('corrupt')
            result = shell(setup + 'installer_download_set "$WORK/corrupt" linux initrd.gz', ok=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('SHA-256 mismatch: linux', result.stderr)

    def test_sha256_and_metadata_duplicates(self):
        with tempfile.TemporaryDirectory() as temp:
            p = pathlib.Path(temp)
            (p / 'file').write_bytes(b'abc')
            digest = hashlib.sha256(b'abc').hexdigest()
            meta = f'Codename: trixie\nMD5Sum:\n bad 3 file\nSHA256:\n {digest} 3 file\nSHA512:\n ignored 3 file\n'
            (p / 'Release').write_text(meta)
            result = shell(f'release_digest {shlex.quote(str(p / "Release"))} file')
            self.assertEqual(result.stdout.strip(), digest + ' 3')
            shell(f'check_digest {shlex.quote(str(p / "file"))} {digest} 3')
            self.assertNotEqual(shell(f'check_digest {shlex.quote(str(p / "file"))} {digest} 4', ok=False).returncode, 0)
            (p / 'Release').write_text(meta.replace('SHA512:', f' {digest} 3 file\nSHA512:'))
            self.assertNotEqual(shell(f'release_digest {shlex.quote(str(p / "Release"))} file', ok=False).returncode, 0)

    def test_download_trust_fail_closed_and_fallback(self):
        with tempfile.TemporaryDirectory() as temp:
            digest = hashlib.sha256(b'abc').hexdigest()
            prefix = f'''WORK={shlex.quote(temp)}; DownloadBases=(https://bad https://good)
fetch() {{ case $1 in https://bad/*) return 1;; */SHA256SUMS) printf '%s  linux\\n' {digest} > "$2";; *) printf abc > "$2";; esac; }}
authenticate() {{ return 0; }}
'''
            shell(prefix + 'installer_download linux "$WORK/output"; [[ $(cat "$WORK/output") == abc && $DownloadMirror == https://good ]]')
            self.assertNotEqual(shell(prefix + 'authenticate() { return 1; }; installer_download linux "$WORK/output"', ok=False).returncode, 0)
            for checksum in ['', 'invalid', '0' * 63]:
                with self.subTest(checksum=checksum):
                    missing = prefix.replace(digest, shlex.quote(checksum))
                    self.assertNotEqual(shell(missing + 'installer_download linux "$WORK/output"', ok=False).returncode, 0)
            bad = prefix.replace('printf abc', 'printf corrupt')
            self.assertNotEqual(shell(bad + 'installer_download linux "$WORK/output"', ok=False).returncode, 0)

    def test_signature_required_for_release_and_firmware(self):
        with tempfile.TemporaryDirectory() as temp:
            setup = f'''WORK={shlex.quote(temp)}; Keyring=/tmp/local-trust.gpg
fetch() {{ printf 'Codename: trixie\n' > "$2"; }}
'''
            shell(setup + '''
gpgv() {
  [[ $* == *'/tmp/local-trust.gpg'* ]] || return 1
  while (( $# )); do
    if [[ $1 == --output ]]; then cp "${@: -1}" "$2"; return; fi
    shift
  done
}
release_file https://mirror.example/debian trixie "$WORK/release"
''')
            for operation in ['release_file https://mirror.example/debian trixie "$WORK/release"', 'authenticate https://firmware.example/SHA256SUMS "$WORK/sums"']:
                result = shell(setup + 'gpgv() { return 1; }; ' + operation, ok=False)
                self.assertNotEqual(result.returncode, 0)
            fallback = setup + '''
fetch() {
  case $1 in */InRelease) return 1;; esac
  printf 'Codename: trixie\n' > "$2"
}
gpgv() { printf 'called' > "$WORK/gpg-called"; return 1; }
release_file https://mirror.example/debian trixie "$WORK/release"
'''
            self.assertNotEqual(shell(fallback, ok=False).returncode, 0)
            self.assertEqual((pathlib.Path(temp) / 'gpg-called').read_text(), 'called')

    def test_ipv6_and_size_parsing(self):
        for value in ['::', '::1', 'fe80::1', '2001:db8::10', '1:2:3:4:5:6:7:8']:
            shell('valid_ipv6 ' + shlex.quote(value))
        for value in [':::1', '1::2::3', '1:2:3', '1:2:3:4:5:6:7:', ':1:2:3:4:5:6:7', '::ffff:999.1.1.1']:
            self.assertNotEqual(shell('valid_ipv6 ' + shlex.quote(value), ok=False).returncode, 0, value)
        self.assertEqual(shell('size_mb 2GB').stdout, '2048')
        self.assertEqual(shell('mask_prefix 255.255.255.255').stdout, '32')
        self.assertEqual(shell('prefix_mask 0').stdout, '0.0.0.0')

    def test_post_install_file_symlink_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            p = pathlib.Path(temp)
            (p / 'real').write_text('echo test')
            (p / 'link').symlink_to(p / 'real')
            self.assertNotEqual(shell(f'read_local {shlex.quote(str(p / "link"))}', ok=False).returncode, 0)

    def test_grub_block_preserves_unrelated_entries(self):
        with tempfile.NamedTemporaryFile(mode='w') as f:
            f.write('before\n### BEGIN reos ###\nold entry\n### END reos ###\nafter\n'); f.flush()
            self.assertEqual(shell('strip_grub ' + shlex.quote(f.name)).stdout, 'before\nafter\n')

    def test_detect_network_preserves_dhcp_and_separate_ipv6_interface(self):
        mock = r'''
ip() {
    case "$*" in
      '-4 route show default') echo 'default via 192.0.2.1 dev eth0 proto dhcp';;
      '-6 route show default') echo 'default via fe80::1 dev eth1 proto static';;
      '-o -4 addr show dev eth0 scope global') echo '2: eth0 inet 192.0.2.10/24 brd 192.0.2.255 scope global dynamic eth0';;
      '-o -6 addr show dev eth1 scope global') echo '3: eth1 inet6 2001:db8::10/64 scope global';;
    esac
}
Interface=auto; DNS=1.1.1.1; DNSExplicit=1
detect_network
printf '%s' "$Interfaces"
'''
        output = shell(mock).stdout
        self.assertIn('iface eth0 inet dhcp', output)
        self.assertIn('auto eth1', output)
        self.assertIn('iface eth1 inet6 static', output)
        self.assertIn('default via fe80::1 dev eth1 onlink', output)
        self.assertNotIn('iface eth0 inet6', output)

    def test_explicit_ipv4_inherits_only_selected_interface_gateway(self):
        setup = r'''
ip() {
    case "$*" in
      '-4 route show default') echo 'default via 192.0.2.1 dev eth0 proto static';;
      '-o -4 addr show dev eth0 scope global') echo '2: eth0 inet 192.0.2.10/24 scope global eth0';;
    esac
}
ifquery() { :; }
'''
        for args, expected in [
            ('--ip 192.0.2.20 --interface eth0', '    gateway 192.0.2.1'),
            ('--ip 192.0.2.20 --interface eth0 --gateway 192.0.2.254', '    gateway 192.0.2.254'),
            ('--ip 198.51.100.20 --netmask 255.255.255.255 --interface eth0', 'default via 192.0.2.1 dev eth0 onlink'),
        ]:
            with self.subTest(args=args):
                result = shell(setup + 'parse ' + args + '; validate; detect_network; printf "%s" "$Interfaces"; asset_preseed_tmpl')
                self.assertIn(expected, result.stdout)
                self.assertIn('d-i netcfg/get_gateway string 192.0.2.', result.stdout)
        result = shell(setup + 'parse --ip 198.51.100.20 --interface eth1; validate; detect_network; [[ -z $Gateway ]]; printf "%s" "$Interfaces"')
        self.assertNotIn('gateway ', result.stdout)
        second_route = setup.replace("'-4 route show default')", "'-4 route show default dev eth1') echo 'default via 198.51.100.1 dev eth1';;\n      '-4 route show default')")
        result = shell(second_route + 'parse --ip 198.51.100.20 --interface eth1; validate; detect_network; printf "%s" "$Interfaces"')
        self.assertIn('    gateway 198.51.100.1', result.stdout)

    def test_preservation_requires_explicit_selection_and_rejects_root_ancestor(self):
        mock = r'''
Disk=/dev/vda; RootDevice=/dev/mapper/root
lsblk() {
  case "$*" in
    '-sprno NAME /dev/mapper/root') printf '/dev/mapper/root\n/dev/vda1\n/dev/vda\n';;
    '-prno NAME,TYPE /dev/vda') printf '/dev/vda1 part\n/dev/vda2 part\n/dev/vda3 part\n';;
    '-dnro FSTYPE /dev/vda1') echo LVM2_member;;
    '-dnro FSTYPE '*) echo ext4;;
    '-dnro PARTUUID '*) echo 1234-abcd;;
    '-dnro MOUNTPOINT '*) echo '';;
  esac
}
'''
        shell(mock + 'preserve_partitions; (( ${#KeepParts[@]} == 0 && ${#KeepFstab[@]} == 0 ))')
        self.assertNotEqual(shell(mock + 'KeepPaths=(/dev/vda1); preserve_partitions', ok=False).returncode, 0)
        result = shell(mock + 'KeepPaths=(/dev/vda3); preserve_partitions; declare -p KeepParts KeepFstab')
        self.assertIn('[0]="3"', result.stdout)
        self.assertIn('1234-abcd|/data|ext4|2', result.stdout)
        for filesystem, pass_number in [('xfs', 2), ('btrfs', 0)]:
            with self.subTest(filesystem=filesystem):
                variant = mock.replace('echo ext4', 'echo ' + filesystem)
                result = shell(variant + 'KeepPaths=(/dev/vda3); preserve_partitions; declare -p KeepFstab')
                self.assertIn(f'1234-abcd|/data|{filesystem}|{pass_number}', result.stdout)
        self.assertNotEqual(shell(mock + 'KeepPaths=(/dev/vdb3); preserve_partitions', ok=False).returncode, 0)

    def test_preview_does_not_use_network_or_mutate_boot(self):
        shell(r'''
fetch() { die 'Preview attempted a download'; }
commit_boot() { die 'Preview attempted boot changes'; }
scratch() { die 'Preview created a staging directory'; }
parse --dry-run --version 13 --disk /dev/vda --interface eth0
validate
preview >/dev/null
''')

    def test_first_run_grub_paths_use_existing_boot_directory(self):
        for boot_path in ['/', '/boot']:
            result = shell(f'''
grub-probe() {{ printf '1234-abcd'; }}
grub-mkrelpath() {{ [[ $1 == /boot ]] || die 'probed missing installer file'; printf '%s' {shlex.quote(boot_path)}; }}
cp() {{ printf 'PATHS=%s %s\\nARGS=%s\\n' "$linux_path" "$initrd_path" "$args"; die 'stopped before writes'; }}
commit_boot
''', ok=False)
            self.assertIn('stopped before writes', result.stderr)
            self.assertIn('ARGS=auto=true priority=critical preseed/file=/preseed.cfg', result.stdout)
            self.assertNotIn('lowmem', result.stdout)
            self.assertIn(f'PATHS={boot_path.rstrip("/")}/reos/linux {boot_path.rstrip("/")}/reos/initrd.gz', result.stdout)


if __name__ == '__main__':
    unittest.main()
