"""Generate synthetic signed full/delta/bootloader fixtures; NEVER FLASH THESE.

The fixed PUBLIC test seed is bytes 00..1f. Signatures are made by OpenSSL,
independent of Swift. The literal-only in-place detools patch is intentionally
not size-efficient; CI decodes it with detools and checks the target image.
"""
import argparse
import hashlib
from pathlib import Path
import struct
import subprocess
import tempfile
import zlib
from generate_mota_fixture import root


def sha(data):
    return hashlib.sha256(data).digest()


def pack(value, bits=6):
    out = bytearray()
    byte, value = value & ((1 << bits) - 1), value >> bits
    while value:
        out.append(byte | 128)
        byte, value = value & 127, value >> 7
    return bytes(out + bytes([byte]))


def application(version, fill):
    body = bytes((i * 17 + fill) % 256 for i in range(41))
    return (body + b'EndF' + struct.pack('<I', len(body)) + sha(body)[:8]
            + struct.pack('<II', version, 0x0A9DBBF0) + b'Heltec_tower_v2'.ljust(32, b'\0'))


def bootloader():
    image = bytearray(b'\xff' * 40960)
    struct.pack_into('<II', image, 0, 0x20040000, 0xF4101)
    image[128:144] = b'MOTABLDR' + struct.pack('<HHB3x', 3, 5, 9)
    pos = 0x9FB4
    image[pos:pos + 44] = (b'BLMFCRC1' + struct.pack('<HHIII', 1, 44, 0xF4000, 40960, 0x239A0071)
                          + b'TOWER_V2_OTA'.ljust(16, b'\0') + bytes(4))
    image[pos + 44:] = b'BLM2SOFT' + struct.pack('<HHIHHIHHI', 2, 32, 0x020406FF, 140, 0xB6, 0x26000, 1, 0, 0)
    struct.pack_into('<I', image, pos + 40, zlib.crc32(image))
    return bytes(image)


def package(openssl, payload, image, fmt, flags, codec, target, version, hw, base, log2):
    leaves = [sha(payload[i:i + (1 << log2)])[:4] for i in range(0, len(payload), 1 << log2)]
    manifest = bytearray([fmt, flags, 0x12]) + struct.pack('<IIII', target, version, len(image), len(payload))
    manifest += bytes([log2]) + root(leaves) + sha(image) + bytes([codec]) + hw.ljust(32, b'\0') + base
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory)
        key = path / 'public-test-key.der'
        key.write_bytes(bytes.fromhex('302e020100300506032b657004220420') + bytes(range(32)))
        manifest += subprocess.check_output([openssl, 'pkey', '-inform', 'DER', '-in', str(key), '-pubout', '-outform', 'DER'])[-32:]
        (path / 'manifest').write_bytes(manifest)
        signature = subprocess.check_output([openssl, 'pkeyutl', '-sign', '-rawin', '-keyform', 'DER', '-inkey', str(key), '-in', str(path / 'manifest')])
    manifest += signature + b'\xff' * 4
    total = 8 + len(manifest) + 4 * len(leaves) + len(payload) + 5
    return b'mOTA' + struct.pack('<I', total) + manifest + b''.join(leaves) + payload + b'vk496'


def main(openssl):
    destination = Path(__file__).resolve().parents[1] / 'MeshCore/Tests/MeshCoreTestSupport/Fixtures'
    destination.mkdir(parents=True, exist_ok=True)
    base, target = application(0x01120100, 3), application(0x01120200, 4)
    # data-format=none; diff=0; entire target as literal extra; seek=0.
    body = pack(0) + pack(0) + pack(len(target)) + target + pack(0)
    patch = bytes([0x12]) + b''.join(pack(v) for v in [0x98000, 4096, 0x97000, len(base), len(target)])
    patch += b'\0' + pack(len(body), 7) + body
    boot = bootloader()
    for name, payload, image, fmt, flags, codec, tid, ver, hw, bh, log2 in [
        ('full', target, target, 2, 3, 0, 0x0A9DBBF0, 0x01120200, b'Heltec_tower_v2', bytes(8), 5),
        ('delta', patch, target, 2, 2, 2, 0x0A9DBBF0, 0x01120200, b'Heltec_tower_v2', sha(base[:-56])[:8], 5),
        ('bootloader', boot, boot, 3, 7, 0, 0x1150F50E, 0x020406FF, b'NRF_BL_239A0071_TOWER_V2_OTA', bytes(8), 10),
    ]:
        data = package(openssl, payload, image, fmt, flags, codec, tid, ver, hw, bh, log2)
        (destination / (name + '.mota')).write_bytes(data)
        count = (len(payload) + (1 << log2) - 1) // (1 << log2)
        descriptor = data[28:32] + struct.pack('<II', tid, ver) + bytes([codec, flags])
        descriptor += struct.pack('<IIIII', len(data), 205, count, 205 + count * 4, len(payload)) + bytes([log2, 0, 0, 0])
        (destination / (name + '.descriptor')).write_bytes(descriptor)
        print(f'{name}: {len(data)} bytes, SHA256 {sha(data).hex()}')
    (destination / 'base.bin').write_bytes(base)
    (destination / 'target.bin').write_bytes(target)
    (destination / 'delta.patch').write_bytes(patch)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--openssl', default='openssl')
    main(parser.parse_args().openssl)
