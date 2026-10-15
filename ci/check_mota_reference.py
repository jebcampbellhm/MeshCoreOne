"""Check committed vectors against the pinned MeshCore Python BLE seeder.

Uses a local reference Git repository without changing its checkout. Compression
is deliberately unavailable: the initial Swift seeder does not advertise it.
"""
import argparse
import base64
from functools import reduce
from operator import xor
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
import types

REVISION = "656cb6924f01acaa1285c75aa3eda1e0151bcb80"


def main(repository, openssl):
    source = subprocess.check_output([
        "git", "-C", repository, "show", f"{REVISION}:tools/ble_mota/ble_mota_seeder.py"
    ], text=True)
    compression = types.ModuleType("zopfli_compress")
    compression.MAXIMUM_ITERATIONS = 1000

    def unsupported(*args, **kwargs):
        raise AssertionError("Compression is outside this fixture check")

    compression.raw_deflate_compress = unsupported
    sys.modules["zopfli_compress"] = compression
    reference = types.ModuleType("mota_reference")
    reference.__file__ = str(Path(repository) / "tools/ble_mota/ble_mota_seeder.py")
    sys.modules[reference.__name__] = reference
    exec(compile(source, reference.__file__, "exec"), reference.__dict__)
    fixture = (Path(__file__).resolve().parents[1] /
               "MeshCore/Tests/MeshCoreTests/Fixtures/MotaReferenceFixture.swift").read_text()
    encoded = fixture.split("static let container = Data(base64Encoded:", 1)[1].split(")!", 1)[0]
    container = base64.b64decode("".join(re.findall(r'"([A-Za-z0-9+/=]+)"', encoded)))
    descriptor = base64.b64decode(re.search(r'descriptor = Data\(base64Encoded: "([^"]+)"', fixture)[1])
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory)
        image = path / "fixture.mota"
        image.write_bytes(container)
        mota = reference.MotaFile.load(image)
        expected_descriptor = bytearray(mota.descriptor)
        expected_descriptor[35] = 0  # Swift baseline does not advertise DEFLATE_BLOCK.
        assert descriptor == expected_descriptor
        # Verify the independent OpenSSL signature, including a negative test.
        (path / "pub.der").write_bytes(bytes.fromhex("302a300506032b6570032100") + container[105:137])
        (path / "signature").write_bytes(container[137:201])
        (path / "manifest").write_bytes(container[8:137])
        command = [openssl, "pkeyutl", "-verify", "-rawin", "-pubin", "-keyform", "DER",
                   "-inkey", str(path / "pub.der"), "-sigfile", str(path / "signature"),
                   "-in", str(path / "manifest")]
        subprocess.run(command, check=True, capture_output=True)
        damaged = bytearray(container[8:137])
        damaged[7] ^= 1
        (path / "manifest").write_bytes(damaged)
        assert subprocess.run(command, capture_output=True).returncode != 0
        catalog = reference.Catalog([mota], False)

        def request(op, args=b""):
            return b"MS" + bytes([op]) + args + bytes([reduce(xor, args, op)])

        assert catalog.handle_request(request(1)) == bytes.fromhex("6d730100011e")
        restored = bytearray()
        for offset in range(0, len(container), 192):
            length = min(192, len(container) - offset)
            reply = catalog.handle_request(request(3, struct.pack("<BIH", 0, offset, length)))
            assert reply[:4] == b"ms\x03\x00" and len(reply) <= 197 and reduce(xor, reply) == 0
            restored += reply[4:-1]
        assert restored == container
        assert catalog.handle_request(request(3, struct.pack("<BIH", 0, 0xFFFFFFFF, 1)))[3] == 1
        assert catalog.handle_request(b"MS\x01\x00") is None
    print("PASS: pinned Python seeder descriptor, COUNT, full readback, bounds/checksum checks; OpenSSL signature positive/negative")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", required=True)
    parser.add_argument("--openssl", default="openssl")
    args = parser.parse_args()
    main(args.repository, args.openssl)
