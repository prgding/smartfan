#!/usr/bin/env python3
"""Keep the local app's macOS permission identity stable across builds."""
from pathlib import Path
import argparse
import re
import subprocess

IDENTIFIER = 'com.shuai.smartfan.menubar'
HELPER_IDENTIFIER = 'com.shuai.smartfan.helper'
# Public developer-team identifier, not a certificate or private key. Renewal
# within this team must not change the designated requirement stored by TCC.
TEAM = '89TZ36T2GT'


def run(*arguments):
    return subprocess.run(arguments, check=True, capture_output=True, text=True)


def requirement(identifier):
    if identifier not in (IDENTIFIER, HELPER_IDENTIFIER):
        raise ValueError('未知的签名应用标识。')
    return (f'identifier "{identifier}" and anchor apple generic '
            'and certificate 1[field.1.2.840.113635.100.6.2.1] exists '
            'and certificate leaf[field.1.2.840.113635.100.6.1.2] exists '
            f'and certificate leaf[subject.OU] = "{TEAM}"')


def select_identity():
    listing = run('/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning').stdout
    candidates = set(re.findall(r'^\s*\d+\) ([A-F0-9]{40}) "Apple Development: [^"\n]+"',
                                listing, re.MULTILINE))
    if candidates:
        certificates = run('/usr/bin/security', 'find-certificate', '-a', '-p').stdout
        for certificate in re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----',
                                      certificates, re.DOTALL):
            details = subprocess.run(
                ['/usr/bin/openssl', 'x509', '-noout', '-fingerprint', '-sha1',
                 '-subject', '-nameopt', 'RFC2253'], input=certificate,
                check=True, capture_output=True, text=True).stdout
            fingerprint = re.search(r'Fingerprint=([A-Fa-f0-9:]+)', details)
            subject = next((line for line in details.splitlines() if line.startswith('subject=')), '')
            if (fingerprint and fingerprint[1].replace(':', '').upper() in candidates
                    and re.search(r'(?:^|,)OU=' + re.escape(TEAM) + r'(?:,|$)', subject)):
                return fingerprint[1].replace(':', '').upper()
    raise RuntimeError('未找到本项目开发团队的有效 Apple Development 签名身份。'
                       '请解锁钥匙串或续期同一团队的证书；不会退回临时签名。')


def designated_requirement(path):
    result = run('/usr/bin/codesign', '--display', '--requirements', '-', str(path))
    for line in (result.stdout + '\n' + result.stderr).splitlines():
        if line.startswith('designated => '):
            return line.removeprefix('designated => ')
    raise RuntimeError('应用没有稳定的证书签名身份，已停止安装。')


def normalize(value):
    return ' '.join(value.replace('/* exists */', 'exists').split())


def verify_code(path, identifier):
    expected = requirement(identifier)
    run('/usr/bin/codesign', '--verify', '--strict', '--deep', '-R=' + expected, str(path))
    if normalize(designated_requirement(path)) != normalize(expected):
        raise RuntimeError('应用的更新身份规则发生变化，已停止安装。')


def verify_bundle(bundle):
    bundle = Path(bundle)
    verify_code(bundle, IDENTIFIER)
    verify_code(bundle / 'Contents/MacOS/SmartFanHelper', HELPER_IDENTIFIER)


def check_update(previous, candidate):
    """Allow the one-time legacy migration, then require mutual continuity."""
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(previous))
    details = run('/usr/bin/codesign', '--display', '--verbose=2', str(previous))
    if 'Signature=adhoc' in details.stderr.splitlines():
        return True
    for relative in ('', 'Contents/MacOS/SmartFanHelper'):
        old, new = Path(previous) / relative, Path(candidate) / relative
        run('/usr/bin/codesign', '--verify', '--strict',
            '-R=' + designated_requirement(old), str(new))
        run('/usr/bin/codesign', '--verify', '--strict',
            '-R=' + designated_requirement(new), str(old))
    return False


def sign(bundle, identity):
    if not re.fullmatch(r'[A-F0-9]{40}', identity):
        raise ValueError('签名必须使用有效证书，禁止临时签名。')
    bundle = Path(bundle)
    for path, identifier in ((bundle / 'Contents/MacOS/SmartFanHelper', HELPER_IDENTIFIER),
                             (bundle, IDENTIFIER)):
        run('/usr/bin/codesign', '--force', '--sign', identity, '--timestamp=none',
            '--options', 'runtime', '--identifier', identifier,
            '--requirements', '=designated => ' + requirement(identifier), str(path))
    verify_bundle(bundle)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('identity')
    signing = commands.add_parser('sign')
    signing.add_argument('bundle', type=Path)
    signing.add_argument('identity')
    verifying = commands.add_parser('verify')
    verifying.add_argument('bundle', type=Path)
    args = parser.parse_args()
    try:
        if args.command == 'identity':
            print(select_identity())
        elif args.command == 'sign':
            sign(args.bundle, args.identity)
        else:
            verify_bundle(args.bundle)
    except subprocess.CalledProcessError as error:
        parser.exit(1, f'签名检查失败：{error.stderr or error.stdout or error}\n')
    except (RuntimeError, ValueError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
