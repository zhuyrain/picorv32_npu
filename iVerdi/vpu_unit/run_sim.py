#!/usr/bin/env python3
"""Run VCS and reject runtime fatal/assertions even if simv returns zero."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

MARKERS = {
    'tb_vpu': 'PASS tb_vpu:',
    'tb_vpu_params': 'PASS all VPU parameter cases',
    'tb_vpu_fifo': 'PASS real SA FIFO -> VPU:',
}


def failures(returncode, output, marker):
    errors = []
    if returncode != 0:
        errors.append('simv exit code {}'.format(returncode))
    if re.search(r'^\s*(?:Fatal:|Error[-:])|\bfailed at\b', output, re.M | re.I):
        errors.append('VCS runtime fatal/error/assertion failure')
    if marker not in output:
        errors.append('required completion marker absent: ' + marker)
    return errors


def self_test():
    marker = MARKERS['tb_vpu']
    assert not failures(0, marker + ' vectors=1\n', marker)
    assert failures(0, 'Fatal: simulated zero-exit failure\n', marker)
    assert failures(0, 'Fatal: failure\n' + marker, marker)
    assert failures(0, 'assertion started at 1ps failed at 1ps\n' + marker, marker)
    assert failures(0, 'simulation ended without completion\n', marker)
    assert failures(1, marker, marker)
    print('PASS runner self-test: zero-exit fatal, assertion, missing PASS and nonzero exit rejected')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--top', choices=sorted(MARKERS), default='tb_vpu')
    parser.add_argument('--seed', type=int, default=1)
    parser.add_argument('--vectors', type=Path)
    parser.add_argument('--coverage', action='store_true')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.vectors is None:
        parser.error('--vectors is required for simulation')
    command = ['./simv', '-no_save', '+ntb_random_seed={}'.format(args.seed),
               '+VECTOR_DIR={}'.format(args.vectors.resolve()),
               '-l', 'sim_seed{}.log'.format(args.seed)]
    if args.coverage:
        command += ['-cm', 'line+cond+branch+tgl', '-cm_name', 'seed{}'.format(args.seed)]
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            universal_newlines=True)
    print(result.stdout, end='')
    errors = failures(result.returncode, result.stdout, MARKERS[args.top])
    status = dict(top=args.top, seed=args.seed, command=command,
                  simv_returncode=result.returncode, passed=not errors, failures=errors)
    Path('run_status_seed{}.json'.format(args.seed)).write_text(json.dumps(status, indent=2)+'\n')
    if errors:
        print('FAIL checked VCS run: ' + '; '.join(errors), file=sys.stderr)
        return 1
    print('PASS checked VCS run: {} seed={}'.format(args.top, args.seed))
    return 0


if __name__ == '__main__':
    sys.exit(main())
