#!/usr/bin/env python3
"""Checked VCS runner: zero-exit runtime fatal must not be a false PASS."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

MARKER = 'PASS tb_sa_vpu_joint:'


def failures(code, output):
    errors = []
    if code != 0:
        errors.append('simv exit code {}'.format(code))
    if re.search(r'^\s*(?:Fatal:|Error[-:])|\bfailed at\b',output,re.M|re.I):
        errors.append('VCS fatal/error/assertion failure')
    if MARKER not in output:
        errors.append('joint completion marker absent')
    return errors


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--top',choices=['tb_sa_vpu_joint','tb_sa_vpu_joint_fifo17'],default='tb_sa_vpu_joint')
    ap.add_argument('--seed',type=int,default=1)
    ap.add_argument('--vectors',type=Path)
    ap.add_argument('--coverage',action='store_true')
    ap.add_argument('--self-test',action='store_true')
    args = ap.parse_args()
    if args.self_test:
        assert not failures(0,MARKER)
        assert failures(0,'Fatal: error\n'+MARKER)
        assert failures(0,'assertion failed at 1ps\n'+MARKER)
        assert failures(0,'no completion')
        assert failures(1,MARKER)
        print('PASS joint runner self-test: false zero-exit successes rejected')
        return 0
    if args.vectors is None:
        ap.error('--vectors is required')
    command = ['./simv','-no_save','+ntb_random_seed={}'.format(args.seed),
               '+VECTOR_DIR={}'.format(args.vectors.resolve()),'-l','sim_seed{}.log'.format(args.seed)]
    if args.coverage:
        command += ['-cm','line+cond+branch+tgl','-cm_name','seed{}'.format(args.seed)]
    result = subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,universal_newlines=True)
    print(result.stdout,end='')
    errors = failures(result.returncode,result.stdout)
    status = dict(top=args.top,seed=args.seed,command=command,
                  simv_returncode=result.returncode,passed=not errors,failures=errors)
    Path('run_status_seed{}.json'.format(args.seed)).write_text(json.dumps(status,indent=2)+'\n')
    if errors:
        print('FAIL joint run: '+'; '.join(errors),file=sys.stderr)
        return 1
    print('PASS checked joint run: {} seed={}'.format(args.top,args.seed))
    return 0


if __name__ == '__main__':
    sys.exit(main())
