import io
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / 'build/zip-encoding-runner'


def fixture(zip64=False):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w', compression=zipfile.ZIP_DEFLATED) as z:
        entry = zipfile.ZipInfo('資料😀.txt')
        entry.comment = '注釈'.encode()
        z.writestr(entry, b'payload PK\x03\x04 remains unchanged')
    data = bytearray(buffer.getvalue())
    end = len(data) - 22
    central = struct.unpack_from('<I', data, end + 16)[0]
    struct.pack_into('<H', data, 6, 0)
    struct.pack_into('<H', data, central + 8, 0)
    if zip64:
        compressed, uncompressed = struct.unpack_from('<II', data, central + 20)
        name_length = struct.unpack_from('<H', data, central + 28)[0]
        extra = struct.pack('<HHQQQ', 1, 24, uncompressed, compressed, 0)
        struct.pack_into('<II', data, central + 20, 0xffffffff, 0xffffffff)
        struct.pack_into('<H', data, central + 30, len(extra))
        struct.pack_into('<I', data, central + 42, 0xffffffff)
        at = central + 46 + name_length
        data[at:at] = extra
        end += len(extra)
        del data[end:]
        data += struct.pack('<IQHHIIQQQQ', 0x06064b50, 44, 45, 45, 0, 0, 1, 1, end - central, central)
        data += struct.pack('<IIQI', 0x07064b50, 0, end, 1)
        data += struct.pack('<IHHHHIIH', 0x06054b50, 0, 0, 0xffff, 0xffff, 0xffffffff, 0xffffffff, 0)
    return data, central


class EncodingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(ROOT / 'build/module-cache'),
                        str(ROOT / 'Sources/ZIPEncoding.swift'),
                        str(ROOT / 'tests/zip-encoding-runner.swift'), '-o', str(RUNNER)], check=True)

    def run_fixture(self, data, success=True):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'test.zip'
            path.write_bytes(data)
            result = subprocess.run([str(RUNNER), str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode == 0, success, result.stderr)
            return path.read_bytes()

    def test_only_flags_change_in_zip_and_zip64(self):
        for zip64 in [False, True]:
            with self.subTest(zip64=zip64):
                original, central = fixture(zip64)
                actual = self.run_fixture(original)
                expected = bytearray(original)
                struct.pack_into('<H', expected, 6, 0x800)
                struct.pack_into('<H', expected, central + 8, 0x800)
                self.assertEqual(actual, expected)
                self.assertEqual(self.run_fixture(actual), actual)
                with zipfile.ZipFile(io.BytesIO(actual)) as z:
                    self.assertIsNone(z.testzip())
                    self.assertEqual(z.read('資料😀.txt'), b'payload PK\x03\x04 remains unchanged')

    def test_invalid_utf8_rejected(self):
        data, central = fixture()
        data[30] = 0xff
        data[central + 46] = 0xff
        self.run_fixture(data, False)

    def test_truncated_archive_rejected(self):
        data, _ = fixture(True)
        self.run_fixture(data[:-5], False)

    def test_bad_zip64_offset_rejected(self):
        data, _ = fixture(True)
        struct.pack_into('<Q', data, len(data) - 22 - 20 + 8, 0xffffffffffffffff)
        self.run_fixture(data, False)


if __name__ == '__main__':
    unittest.main(verbosity=2)
