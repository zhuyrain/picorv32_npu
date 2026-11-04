#!/usr/bin/env python3
"""Persist VPU JSON/HEX vectors and arbitrary-precision Python golden results.

Packed input, LSB first: acc lanes, mask, tag, error, residual_en, relu_en,
shift, main multiplier lanes, residual multiplier lanes. Expected LSB first:
INT8 result lanes, mask, tag, error. Residual data uses its own HEX stream.
No numpy/fixed-width arithmetic is used to compute the golden result.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import tempfile

PARAMS = dict(COLS=8, ACC_WIDTH=48, RES_WIDTH=8, MULT_WIDTH=32,
              SHIFT_WIDTH=7, TAG_WIDTH=8)
SEED = 0x5650552026
COUNT = 768


def golden(v):
    result = []
    for lane, acc in enumerate(v['acc']):
        total = acc * v['mul_main'][lane]
        if v['residual_en']:
            total += v['residual'][lane] * v['mul_res'][lane]
        shifted = total >> v['shift']  # Python negative >> is floor division.
        q = max(-127, min(127, shifted))
        if v['relu_en']:
            q = max(0, q)
        result.append(q if ((v['mask'] >> lane) & 1) and not v['error'] else 0)
    return result


def pack_lanes(values, width):
    return sum((v & ((1 << width)-1)) << (i*width) for i, v in enumerate(values))


def layout():
    p = PARAMS
    fields = [('acc', p['COLS']*p['ACC_WIDTH']), ('mask', p['COLS']),
              ('tag', p['TAG_WIDTH']), ('error', 2), ('residual_en', 1),
              ('relu_en', 1), ('shift', p['SHIFT_WIDTH']),
              ('mul_main', p['COLS']*p['MULT_WIDTH']),
              ('mul_res', p['COLS']*p['MULT_WIDTH'])]
    offset = 0
    result = []
    for name, width in fields:
        result.append(dict(name=name, lsb=offset, width=width))
        offset += width
    return result, offset


def validate(v):
    p = PARAMS
    for name, width in [('acc', p['ACC_WIDTH']), ('residual', p['RES_WIDTH']),
                        ('mul_main', p['MULT_WIDTH']), ('mul_res', p['MULT_WIDTH'])]:
        assert len(v[name]) == p['COLS']
        assert all(-(1 << (width-1)) <= x < (1 << (width-1)) for x in v[name]), name
    assert 0 <= v['shift'] < (1 << p['SHIFT_WIDTH'])
    assert 0 <= v['mask'] < (1 << p['COLS'])
    assert 0 <= v['error'] <= 3
    assert v['expected'] == golden(v)


def build_vectors():
    p = PARAMS
    c = p['COLS']
    vectors = []

    def add(name, acc, mul=1, residual=0, mul_res=0, residual_en=0,
            shift=0, relu=0, mask=None, error=0):
        def lanes(x):
            return list(x) if isinstance(x, (list, tuple)) else [x]*c
        v = dict(index=len(vectors), name=name, acc=lanes(acc),
                 residual=lanes(residual), mul_main=lanes(mul), mul_res=lanes(mul_res),
                 residual_en=int(residual_en), relu_en=int(relu), shift=shift,
                 mask=(1 << c)-1 if mask is None else mask, error=error,
                 tag=len(vectors) & ((1 << p['TAG_WIDTH'])-1))
        v['expected'] = golden(v)
        validate(v)
        vectors.append(v)

    # First three are also used for an explicit early residual rendezvous test.
    add('old_ppu_32769_times_65535', 32769, 65535)
    add('negative_floor_minus3_shift1', -3, shift=1)
    add('shared_shift_not_per_product', 1, residual=1, mul_res=1,
        residual_en=1, shift=1)
    for value in [-129, -128, -127, -126, -1, 0, 1, 126, 127, 128, 129]:
        for relu in [0, 1]:
            add('clip_{}_relu{}'.format(value, relu), value, relu=relu)
    add('negative_shared_shift', -3, residual=1, mul_res=1, residual_en=1, shift=1)
    for a in [-(1 << 47), (1 << 47)-1, -(1 << 46), (1 << 46)+17]:
        for m in [-(1 << 31), (1 << 31)-1]:
            for shift in [0, 31, 63, 65, 78, 80, 127]:
                add('wide_signed_product_a{}_m{}_shift{}'.format(a, m, shift),
                    a, m, shift=shift)
    for delta in [-3, -1, 0, 1, 3]:
        add('residual_large_cancel_{}'.format(delta), (1 << 33)+delta,
            residual=-128, mul_res=1 << 26, residual_en=1)
    add('min_res_min_coeff', 0, residual=-128, mul_res=-(1 << 31),
        residual_en=1, shift=31)
    add('all_masked_huge_products', -(1 << 47), -(1 << 31), mask=0)
    for error in [1, 2, 3]:
        add('error_passthrough_{}'.format(error), (1 << 47)-1, -(1 << 31),
            residual=-128, mul_res=-(1 << 31), residual_en=1, error=error)
    add('per_lane_dynamic_coefficients', [3, -3, 127, -128, 32769, -999, 1 << 40, -(1 << 40)],
        [1, 2, -3, -(1 << 31), 65535, 17, 1 << 20, -(1 << 20)],
        residual=[1, -2, -128, 127, 3, 4, -99, 100],
        mul_res=[3, -5, 1 << 26, -(1 << 25), 7, 11, -13, 17], residual_en=1,
        shift=31, mask=0xad)
    rng = random.Random(SEED)
    a_edges = [-(1 << 47), (1 << 47)-1, -(1 << 40), 1 << 40, -32769,
               32769, -128, -3, -1, 0, 1, 127, 128, 129]
    m_edges = [-(1 << 31), (1 << 31)-1, -65535, 65535, -3, -1, 0, 1, 3, 1 << 26]
    while len(vectors) < COUNT:
        i = len(vectors)
        acc = [rng.choice(a_edges) if rng.randrange(3) else rng.randrange(-(1 << 47), 1 << 47) for _ in range(c)]
        mul = [rng.choice(m_edges) if rng.randrange(3) else rng.randrange(-(1 << 31), 1 << 31) for _ in range(c)]
        residual = [rng.randrange(-128, 128) for _ in range(c)]
        mr = [rng.choice(m_edges) if rng.randrange(3) else rng.randrange(-(1 << 31), 1 << 31) for _ in range(c)]
        add('random_{:04d}'.format(i), acc, mul, residual=residual, mul_res=mr,
            residual_en=(i % 3 != 0), shift=rng.choice([0, 1, 7, 31, 63, 65, 78, 80, 127, rng.randrange(128)]),
            relu=i % 2, mask=(0 if i % 29 == 0 else rng.randrange(1 << c)),
            error=(i % 4 if i % 37 == 0 else 0))
    assert vectors[0]['expected'] == [127]*c
    assert vectors[1]['expected'] == [-2]*c
    assert vectors[2]['expected'] == [1]*c
    assert any(abs(v['acc'][0]*v['mul_main'][0]).bit_length() > 64 for v in vectors)
    assert any(v['name'] == 'residual_large_cancel_1' and v['expected'] == [1]*c for v in vectors)
    return vectors


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def packed_files(vectors):
    fields, in_width = layout()
    expected_width = PARAMS['COLS']*8+PARAMS['COLS']+PARAMS['TAG_WIDTH']+2
    inputs, residuals, expected = [], [], []
    for v in vectors:
        values = dict(v)
        values['acc'] = pack_lanes(v['acc'], PARAMS['ACC_WIDTH'])
        values['mul_main'] = pack_lanes(v['mul_main'], PARAMS['MULT_WIDTH'])
        values['mul_res'] = pack_lanes(v['mul_res'], PARAMS['MULT_WIDTH'])
        inputs.append(sum(values[f['name']] << f['lsb'] for f in fields))
        residuals.append(pack_lanes(v['residual'], PARAMS['RES_WIDTH']))
        e = pack_lanes(v['expected'], 8)
        e |= v['mask'] << (PARAMS['COLS']*8)
        e |= v['tag'] << (PARAMS['COLS']*9)
        e |= v['error'] << (PARAMS['COLS']*9+PARAMS['TAG_WIDTH'])
        expected.append(e)
    return [('input.hex', inputs, in_width),
            ('residual.hex', residuals, PARAMS['COLS']*PARAMS['RES_WIDTH']),
            ('expected.hex', expected, expected_width)]


def manifest_metadata(vectors):
    fields, in_width = layout()
    expected_width = PARAMS['COLS']*8+PARAMS['COLS']+PARAMS['TAG_WIDTH']+2
    return dict(parameters=PARAMS, count=len(vectors),
                residual_count=sum(v['residual_en'] for v in vectors), seed=SEED,
                input_width=in_width, expected_width=expected_width,
                input_layout_lsb_first=fields,
                expected_layout_lsb_first=[dict(name='data', lsb=0, width=PARAMS['COLS']*8),
                                          dict(name='mask', lsb=PARAMS['COLS']*8, width=PARAMS['COLS']),
                                          dict(name='tag', lsb=PARAMS['COLS']*9, width=PARAMS['TAG_WIDTH']),
                                          dict(name='error', lsb=PARAMS['COLS']*9+PARAMS['TAG_WIDTH'], width=2)])


def atomic_write(path, text):
    path = path.resolve()
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', newline='\n',
                                         prefix='.'+path.name+'.', suffix='.tmp',
                                         dir=str(path.parent), delete=False) as stream:
            temporary = Path(stream.name).resolve()
            assert temporary.parent == path.parent
            stream.write(text)
        os.replace(str(temporary), str(path))
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def verify_saved(out, here):
    # Deliberately READ ONLY. Default simulation never regenerates/sanitizes
    # preserved vectors; even a generator code edit must be explicitly published.
    manifest = json.loads((out/'manifest.json').read_text())
    assert manifest['generator_sha256'] == sha(here/'gen_vectors.py'), 'generator SHA mismatch; explicitly regenerate'
    names = ['vectors.json', 'input.hex', 'residual.hex', 'expected.hex']
    assert set(manifest['files']) == set(names), 'manifest file set mismatch'
    for name in names:
        record = manifest['files'][name]
        assert record['sha256'] == sha(out/name), 'saved SHA mismatch: '+name
        assert record['bytes'] == (out/name).stat().st_size, 'saved byte count mismatch: '+name
    document = json.loads((out/'vectors.json').read_text())
    assert document['parameters'] == PARAMS and document['seed'] == SEED, 'JSON parameters/seed mismatch'
    vectors = document['vectors']
    assert len(vectors) == COUNT, 'JSON vector count mismatch'
    for index, v in enumerate(vectors):
        assert v['index'] == index and v['tag'] == index % (1 << PARAMS['TAG_WIDTH']), 'JSON ordering/tag mismatch'
        assert v['residual_en'] in (0, 1) and v['relu_en'] in (0, 1), 'bad mode encoding'
        validate(v)  # Independent arbitrary-precision golden/range checks.
    metadata = manifest_metadata(vectors)
    for name, value in metadata.items():
        assert manifest[name] == value, 'manifest metadata mismatch: '+name
    for name, words, width in packed_files(vectors):
        lines = (out/name).read_text().splitlines()
        digits = (width+3)//4
        assert len(lines) == len(words), 'HEX length mismatch: '+name
        for index, (line, word) in enumerate(zip(lines, words)):
            assert len(line) == digits and all(x in '0123456789abcdef' for x in line), 'HEX format mismatch'
            assert int(line, 16) == word, 'JSON/HEX mismatch {} row {}'.format(name, index)
    print('PASS --check: saved SHA/layout/params and {} Python goldens/HEX rows; READ ONLY'.format(len(vectors)))
    return manifest


def main():
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='validate preserved files without writing anything')
    args = parser.parse_args()
    out = here/'vectors'
    if args.check:
        verify_saved(out, here)
        return
    out.mkdir(parents=True, exist_ok=True)
    vectors = build_vectors()
    atomic_write(out/'vectors.json', json.dumps(dict(parameters=PARAMS, seed=SEED,
                 arithmetic='Python integers; shared floor shift; clip[-127,127]; then ReLU',
                 vectors=vectors), indent=2)+'\n')
    for name, values, width in packed_files(vectors):
        atomic_write(out/name, ''.join('{:0{}x}\n'.format(x, (width+3)//4) for x in values))
    manifest = manifest_metadata(vectors)
    manifest['generator_sha256'] = sha(here/'gen_vectors.py')
    manifest['files'] = {}
    for name in ['vectors.json', 'input.hex', 'residual.hex', 'expected.hex']:
        manifest['files'][name] = dict(sha256=sha(out/name), bytes=(out/name).stat().st_size)
    # Publish manifest LAST, after complete same-directory atomic data writes.
    atomic_write(out/'manifest.json', json.dumps(manifest, indent=2)+'\n')
    verify_saved(out, here)
    print('PASS generate: {} vectors, {} residual transactions; input={} bits expected={} bits'.format(
        len(vectors), manifest['residual_count'], manifest['input_width'], manifest['expected_width']))
    print('Persistent vector files: {}'.format(out))


if __name__ == '__main__':
    main()
