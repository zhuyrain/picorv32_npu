#!/usr/bin/env python3
"""Parse the frozen C vectors, validate with Python integers, emit readmemh files."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile


def parse_vectors(source):
    text = re.sub(r"/\*.*?\*/|//[^\n]*", "", source, flags=re.S)
    cases = []
    for case in range(1, 6):
        dims = {}
        for dim in "MKN":
            match = re.search(rf"#define\s+HWC_IM2COL_CASE{case}_{dim}\s+(\d+)\b", text)
            if not match:
                raise ValueError(f"case {case}: missing {dim}")
            dims[dim] = int(match[1])
        arrays = {}
        for name, size, bits in (("input", dims['M'] * dims['K'], 8),
                                 ("weight", dims['K'] * dims['N'], 8),
                                 ("expected", dims['M'] * dims['N'], 64)):
            match = re.search(rf"static\s+const\s+int{bits}_t\s+hwc_im2col_case{case}_{name}\[(\d+)\]\s*=\s*\{{(.*?)\}}\s*;", text, re.S)
            if not match:
                raise ValueError(f"case {case}: missing {name}")
            body = match[2]
            if re.sub(r"[-+]?\d+|[\s,]", "", body):
                raise ValueError(f"case {case}: nonliteral {name} initializer")
            values = [int(v) for v in re.findall(r"[-+]?\d+", body)]
            if int(match[1]) != size or len(values) != size:
                raise ValueError(f"case {case}: {name} shape/length mismatch")
            if any(not -(1 << (bits - 1)) <= v < (1 << (bits - 1)) for v in values):
                raise ValueError(f"case {case}: {name} signed range mismatch")
            arrays[name] = values
        m, k, n = (dims[d] for d in 'MKN')
        if case >= 3 and any(v != 1 for v in arrays['input']):
            raise ValueError(f"case {case}: K=8 synthetic activations must be ONES")
        # Deliberately no numpy, int8 dot, saturation, or fixed-width intermediate.
        actual = [sum(arrays['input'][row*k+t] * arrays['weight'][t*n+col]
                      for t in range(k)) for row in range(m) for col in range(n)]
        for index, (got, want) in enumerate(zip(actual, arrays['expected'])):
            if got != want:
                raise ValueError(f"case {case} C[{index//n},{index%n}]: Python {got} != header {want}")
        cases.append(dict(case=case, **dims, **arrays))
    return cases


def atomic_write_text(path, content):
    """Publish a complete file, never a truncated file, to parallel readers."""
    path = Path(path).resolve()
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', newline='\n',
                                         dir=path.parent, prefix=f'.{path.name}.',
                                         suffix='.tmp', delete=False) as stream:
            temporary = Path(stream.name).resolve()
            if temporary.parent != path.parent:
                raise ValueError('temporary output escaped destination directory')
            stream.write(content)
        # Close before rename; same-directory replace is atomic on this filesystem.
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def write_hex(path, values, bits):
    atomic_write_text(path, ''.join(f'{v & ((1 << bits)-1):0{(bits+3)//4}x}\n' for v in values))


def main():
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=here/'reference/test_vector_hwc_im2col_tiles.h')
    parser.add_argument('--out', type=Path, default=here/'build/hex')
    parser.add_argument('--manifest', type=Path, default=here/'reference/manifest.json',
                        help='pinned source manifest with files[name].sha256')
    args = parser.parse_args()
    raw = args.source.read_bytes()
    source_sha256 = hashlib.sha256(raw).hexdigest()
    pinned = json.loads(args.manifest.read_text())['files'][args.source.name]['sha256']
    if source_sha256 != pinned:
        raise ValueError(f"source SHA256 mismatch: {source_sha256} != manifest {pinned}")
    cases = parse_vectors(raw.decode())
    args.out.mkdir(parents=True, exist_ok=True)
    manifest = {'source_sha256': source_sha256, 'cases': []}
    for item in cases:
        number = item['case']
        for field, bits in (('input', 8), ('weight', 8), ('expected', 64)):
            write_hex(args.out/f'case{number}_{field}.hex', item[field], bits)
        manifest['cases'].append({key: item[key] for key in ('case', 'M', 'K', 'N')})
        print(f"case {number}: M={item['M']} K={item['K']} N={item['N']}; {len(item['expected'])} expected elements independently verified")
    atomic_write_text(args.out/'manifest.json', json.dumps(manifest, indent=2)+'\n')
    print(f"PASS: Python integer GEMM validates all five cases; hex -> {args.out}")


if __name__ == '__main__':
    main()
