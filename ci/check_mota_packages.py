"""Cross-check every fixture with pinned upstream Python validators and BLE seeder."""
import argparse
import importlib.util
from functools import reduce
from operator import xor
from pathlib import Path
import struct
import subprocess
import sys
import types

REVISION = '656cb6924f01acaa1285c75aa3eda1e0151bcb80'


def load(repository, relative, name):
    source = subprocess.check_output(['git', '-C', repository, 'show', f'{REVISION}:{relative}'], text=True)
    module = types.ModuleType(name)
    module.__file__ = str(Path(repository) / relative)
    sys.modules[name] = module
    exec(compile(source, module.__file__, 'exec'), module.__dict__)
    return module


def main(repository):
    compression = types.ModuleType('zopfli_compress')
    compression.MAXIMUM_ITERATIONS = 1000
    compression.raw_deflate_compress = lambda *_args, **_kwargs: (_ for _ in ()).throw(AssertionError('No compression'))
    sys.modules['zopfli_compress'] = compression
    library = load(repository, 'tools/mota/motalib.py', 'reference_motalib')
    ble = load(repository, 'tools/ble_mota/ble_mota_seeder.py', 'reference_ble')
    fixtures = Path(__file__).resolve().parents[1] / 'MeshCore/Tests/MeshCoreTestSupport/Fixtures'
    for name in ['full', 'delta', 'bootloader']:
        path = fixtures / (name + '.mota')
        blob = path.read_bytes()
        parsed = library.parse_container(blob)
        problems = library.verify(parsed, base_image=(fixtures / 'base.bin').read_bytes() if name == 'delta' else None)
        assert not problems, (name, problems)
        if name == 'delta':
            assert library._apply_detools_delta(2, parsed.payload, (fixtures / 'base.bin').read_bytes()) == (fixtures / 'target.bin').read_bytes()
        mota = ble.MotaFile.load(path)
        descriptor = bytearray(mota.descriptor)
        descriptor[35] = 0
        assert descriptor == (fixtures / (name + '.descriptor')).read_bytes()
        catalog = ble.Catalog([mota], False)
        restored = bytearray()
        for offset in range(0, len(blob), 192):
            length = min(192, len(blob) - offset)
            args = struct.pack('<BIH', 0, offset, length)
            request = b'MS\x03' + args + bytes([reduce(xor, args, 3)])
            response = catalog.handle_request(request)
            assert response[:4] == b'ms\x03\x00' and reduce(xor, response) == 0
            restored += response[4:-1]
        assert restored == blob
        print(f'PASS {name}: signature, payload contract, descriptor, complete BLE readback' + (' and real detools reconstruction' if name == 'delta' else ''))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--repository', required=True)
    main(parser.parse_args().repository)
