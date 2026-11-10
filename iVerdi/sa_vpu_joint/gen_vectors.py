#!/usr/bin/env python3
"""Generate/check persistent real-im2col + random identity integration vectors."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import random
import sys
import tempfile

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SOURCE = HERE.parent/'sa_unit/reference/test_vector_hwc_im2col_tiles.h'
SOURCE_MANIFEST = HERE.parent/'sa_unit/reference/manifest.json'
PARSER = HERE.parent/'sa_unit/gen_vectors.py'
SEED = 0x5341565055323036
SHIFT = 16
MAIN_TARGET = 80
MULT_IDENTITY = 1 << 15
CONFIG_LAYOUT = [dict(name=n, lsb=l, width=w) for n,l,w in
                 [('mult_main',0,32),('mult_identity',32,32),('shift',64,7),
                  ('M',71,16),('K',87,16),('N',103,16)]]


def sha_bytes(data):
    return hashlib.sha256(data).hexdigest()


def text_json(value):
    return json.dumps(value, indent=2, sort_keys=True)+'\n'


def hex_text(values, bits):
    mask = (1 << bits)-1
    return ''.join('{:0{}x}\n'.format(v & mask, (bits+3)//4) for v in values)


def clip(value):
    return max(-127, min(127, value))


def build():
    source = SOURCE.read_bytes()
    pinned = json.loads(SOURCE_MANIFEST.read_text())
    if sha_bytes(source) != pinned['files'][SOURCE.name]['sha256']:
        raise ValueError('Frozen im2col source SHA does not match original manifest')
    spec = importlib.util.spec_from_file_location('frozen_im2col_parser', str(PARSER))
    parser = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(parser)
    parsed = parser.parse_vectors(source.decode())  # Recomputes INT64 header goldens with Python ints.
    records, files, configs = [], {}, []
    for item in parsed:
        number,m,k,n = (item[name] for name in ('case','M','K','N'))
        # Independent recomputation also documents exactly what enters the SA.
        mac = [sum(item['input'][row*k+t]*item['weight'][t*n+col] for t in range(k))
               for row in range(m) for col in range(n)]
        if mac != item['expected']:
            raise ValueError('case {} MAC differs from header'.format(number))
        peak = max(abs(x) for x in mac)
        mult_main = max(1, (MAIN_TARGET*(1 << SHIFT)+peak//2)//peak) if peak else 1
        if not 0 < mult_main < (1 << 31):
            raise ValueError('Selected main multiplier is not positive INT32')
        rng = random.Random(SEED + number)
        identity = [rng.randrange(-127,128) for _ in range(m*n)]
        raw_normal = [(x*mult_main) >> SHIFT for x in mac]
        raw_fused = [(x*mult_main+r*MULT_IDENTITY) >> SHIFT for x,r in zip(mac,identity)]
        normal = [clip(x) for x in raw_normal]
        fused = [clip(x) for x in raw_fused]
        relu = [max(0,x) for x in fused]
        config = dict(mult_main=mult_main, mult_identity=MULT_IDENTITY, shift=SHIFT,
                      M=m,K=k,N=n)
        record = dict(case=number,M=m,K=k,N=n,identity_seed=SEED+number,
                      config=config,input=item['input'],weight=item['weight'],mac=mac,
                      identity=identity,normal_expected=normal,fused_expected=fused,
                      relu_expected=relu,
                      statistics=dict(mac_min=min(mac),mac_max=max(mac),mac_abs_peak=peak,
                          identity_min=min(identity),identity_max=max(identity),
                          main_quant_min=min(normal),main_quant_max=max(normal),
                          fused_min=min(fused),fused_max=max(fused),
                          fused_saturated=sum(x < -127 or x > 127 for x in raw_fused),
                          fused_negative=sum(x < 0 for x in fused),
                          relu_zero=sum(x == 0 for x in relu)))
        records.append(record)
        prefix = 'case{}'.format(number)
        for suffix,values,bits in [('a',item['input'],8),('b',item['weight'],8),('mac',mac,64),
                                  ('identity',identity,8),('normal',normal,8),('fused',fused,8),('relu',relu,8)]:
            files[prefix+'_'+suffix+'.hex'] = hex_text(values,bits)
        configs.append(sum(config[field['name']] << field['lsb'] for field in CONFIG_LAYOUT))
    files['params.hex'] = hex_text(configs,119)
    payload = dict(source=str(SOURCE.relative_to(ROOT)),source_sha256=sha_bytes(source),
                   seed=SEED,rounding='floor, no rounding bias',clip=[-127,127],
                   identity_kind='synthetic signed INT8 random residual, not identity operator',
                   layer_quantization=True,cases=records)
    files['vectors.json'] = text_json(payload)
    if sum(r['statistics']['fused_saturated'] for r in records) == 0:
        raise ValueError('Selected test calibration does not exercise saturation')
    if sum(r['statistics']['fused_negative'] for r in records) == 0:
        raise ValueError('Selected test calibration does not exercise optional ReLU')
    return records,files,pinned


def atomic_write(path, content):
    path = path.resolve()
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', newline='\n',
                                         dir=str(path.parent), prefix='.'+path.name+'.',
                                         suffix='.tmp', delete=False) as stream:
            temporary = Path(stream.name).resolve()
            if temporary.parent != path.parent:
                raise ValueError('Temporary file escaped output directory')
            stream.write(content)
        os.replace(str(temporary),str(path))
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--check',action='store_true',help='read-only integrity and math check')
    ap.add_argument('--out',type=Path,default=HERE/'vectors')
    args = ap.parse_args()
    records,files,pinned = build()
    manifest = dict(generator_sha256=sha_bytes(Path(__file__).read_bytes()),
                    parser_sha256=sha_bytes(PARSER.read_bytes()),
                    source_sha256=sha_bytes(SOURCE.read_bytes()),
                    source_commit=pinned['commit'],seed=SEED,params_width=119,
                    params_layout_lsb_first=CONFIG_LAYOUT,
                    clip=[-127,127],bias=0,physical_rows=8,physical_cols=8,
                    profiles=['normal','fused','fused_relu'],
                    case_count=len(records),mac_elements=sum(len(r['mac']) for r in records),
                    profiles_elements=3*sum(len(r['mac']) for r in records),
                    cases=[dict(case=r['case'],M=r['M'],K=r['K'],N=r['N'],
                                config=r['config'],statistics=r['statistics']) for r in records],
                    files={name:dict(sha256=sha_bytes(content.encode()),bytes=len(content.encode()))
                           for name,content in files.items()})
    if args.check:
        actual = json.loads((args.out/'manifest.json').read_text())
        if actual != manifest:
            raise ValueError('Saved joint vector manifest/parameters/SHA mismatch; do not regenerate implicitly')
        for name,content in files.items():
            if (args.out/name).read_bytes() != content.encode():
                raise ValueError('Saved vector or golden mismatch: '+name)
        print('PASS --check: frozen header, random identities, layer scales, all HEX/JSON goldens; READ ONLY')
    else:
        args.out.mkdir(parents=True,exist_ok=True)
        for name,content in files.items():
            atomic_write(args.out/name,content)
        atomic_write(args.out/'manifest.json',text_json(manifest))
        print('PASS generated persistent joint vectors at {}'.format(args.out))
    for r in records:
        cfg,stats = r['config'],r['statistics']
        print('case{} {}x{}x{}: MULT_MAIN={} MULT_ID={} SHIFT={} MAC_peak={} fused_sat={}'.format(
            r['case'],r['M'],r['K'],r['N'],cfg['mult_main'],cfg['mult_identity'],cfg['shift'],
            stats['mac_abs_peak'],stats['fused_saturated']))
    print('PASS joint goldens: {} MAC/identity elements; {} post-op elements across 3 profiles'.format(
        manifest['mac_elements'],manifest['profiles_elements']))


if __name__ == '__main__':
    main()
