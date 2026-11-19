"""Build, audit and retain the focused compiled Haskell membership proof."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time


def audit(executable: Path) -> dict[str, object]:
    symbols = subprocess.check_output(['nm', '-a', str(executable)], text=True)
    helpers = [match.group(1) for line in symbols.splitlines()
               if (match := re.match(r'^[0-9a-f]+ [tT] (h_\S+)$', line))]
    if not {'h_start', 'h_clone'} <= {name.split('.')[0] for name in helpers}:
        raise AssertionError('compiled integration helper entries missing from audit')
    rejected = []
    for helper in helpers:
        text = subprocess.check_output(['objdump', '-d', '--disassemble=' + helper, str(executable)], text=True)
        for line in text.splitlines():
            branch = re.search(r'\b(?:call|jmp)\s+(.+)', line)
            if branch:
                target = re.search(r'<([^>]+)>', branch.group(1))
                if not target or not target.group(1).startswith('h_'):
                    rejected.append(f'{helper}: {line.strip()}')
            if '%fs:' in line or '%gs:' in line:
                rejected.append(f'{helper}: TLS {line.strip()}')
    if rejected:
        raise AssertionError(f'compiled helper escaped raw syscall discipline: {rejected}')
    return {'status': 'PASS', 'helpers': helpers, 'external_or_indirect_calls': [], 'tls_access': [],
            'source_sha256': hashlib.sha256(Path('test-support/guardian-native.c').read_bytes()).hexdigest(),
            'executable_sha256': hashlib.sha256(executable.read_bytes()).hexdigest()}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--pattern', default='/guardian process membership/')
    parser.add_argument('--capabilities', choices=['1', '2'], default='1')
    args = parser.parse_args()
    output = args.output or Path(tempfile.mkdtemp(prefix='haskell-membership-'))
    output.mkdir(exist_ok=True, parents=True)
    start = time.monotonic()
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-fsyntax-only',
                    'test-support/guardian-driver.c'], check=True)
    with (output / 'build.log').open('w') as log:
        build = subprocess.run(['cabal', 'build', 'integration', '--offline'], stdout=log, stderr=subprocess.STDOUT)
    if build.returncode:
        print((output / 'build.log').read_text()[-4000:], flush=True)
        raise SystemExit(build.returncode)
    executable = Path(subprocess.check_output(['cabal', 'list-bin', 'integration', '--offline'], text=True).strip())
    audited = audit(executable)
    (output / 'native-code-audit.json').write_text(json.dumps(audited, indent=2) + '\n')
    built = time.monotonic()
    command = [str(executable), '--pattern', args.pattern, '--num-threads', '1',
               '+RTS', '-N' + args.capabilities, '-RTS']
    environment = dict(os.environ, LIBTMUX_EXPECT_CAPABILITIES=args.capabilities)
    result = subprocess.run(command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (output / 'cases.log').write_text(result.stdout)
    receipt = {'scope': 'compiled focused Haskell process-owner experiment; public owned-server scope not executed',
               'returncode': result.returncode, 'build_audit_seconds': built-start,
               'test_seconds': time.monotonic()-built, 'wall_seconds': time.monotonic()-start,
               'command': command, 'tmux': os.environ.get('LIBTMUX_TEST_TMUX')}
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(result.stdout, flush=True)
    print(json.dumps(receipt), flush=True)
    raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
