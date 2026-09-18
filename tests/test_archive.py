import os
from pathlib import Path
import stat
import struct
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / 'build/resolve-archive'
ALIAS = ROOT / 'build/make-alias'


class ArchiveTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(ROOT / 'build/module-cache'),
                        str(ROOT / 'tests/make-alias.swift'), '-o', str(ALIAS)], check=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.source = self.base / '資料 folder'
        self.source.mkdir()
        self.external = self.base / 'outside'
        self.external.mkdir()
        (self.external / '内容.txt').write_text('外部の実体\n')
        self.output = self.base / 'result.zip'

    def alias(self, target, output):
        subprocess.run([str(ALIAS), str(target), str(output)], check=True)

    def archive(self, success=True, *extra):
        p = subprocess.run([str(BIN), '-o', str(self.output), *extra, '--', str(self.source)],
                           capture_output=True, text=True)
        self.assertEqual(p.returncode == 0, success, p.stderr)
        return p

    def test_mixed_links_aliases_hidden_empty_and_executable(self):
        (self.source / '.hidden').write_text('hidden')
        (self.source / 'empty').mkdir()
        executable = self.source / 'run'
        executable.write_text('#!/bin/sh\nexit 0\n')
        executable.chmod(0o755)
        (self.source / 'relative').symlink_to('../outside/内容.txt')
        (self.source / 'directory').symlink_to(self.external, target_is_directory=True)
        self.alias(self.external / '内容.txt', self.source / 'file alias')
        self.alias(self.external, self.source / 'directory alias')
        (self.source / 'mixed').symlink_to('file alias')
        self.archive()
        with zipfile.ZipFile(self.output) as z:
            prefix = self.source.name + '/'
            for name in ['relative', 'file alias', 'mixed', 'directory/内容.txt', 'directory alias/内容.txt']:
                self.assertEqual(z.read(prefix + name).decode(), '外部の実体\n')
                self.assertFalse(stat.S_ISLNK(z.getinfo(prefix + name).external_attr >> 16))
            self.assertEqual(z.read(prefix + '.hidden'), b'hidden')
            self.assertIn(prefix + 'empty/', z.namelist())
            self.assertTrue(z.getinfo(prefix + 'run').external_attr >> 16 & stat.S_IXUSR)
        self.assertTrue((self.source / 'relative').is_symlink())

    def test_symlink_cycle(self):
        (self.source / 'a').symlink_to('b')
        (self.source / 'b').symlink_to('a')
        self.archive(False)
        self.assertFalse(self.output.exists())

    def test_directory_cycle(self):
        (self.source / 'back').symlink_to(self.source, target_is_directory=True)
        self.archive(False)
        self.assertFalse(self.output.exists())

    def test_alias_directory_cycle(self):
        self.alias(self.source, self.source / 'back alias')
        self.archive(False)
        self.assertFalse(self.output.exists())

    def test_broken_symlink(self):
        (self.source / 'broken').symlink_to('missing')
        self.archive(False)
        self.assertFalse(self.output.exists())

    def test_broken_alias(self):
        target = self.external / '内容.txt'
        self.alias(target, self.source / 'broken alias')
        target.unlink()
        self.archive(False)
        self.assertFalse(self.output.exists())

    def test_existing_output(self):
        self.output.write_bytes(b'keep me')
        self.archive(False)
        self.assertEqual(self.output.read_bytes(), b'keep me')

    def test_output_symlink(self):
        self.output.symlink_to(self.base / 'missing')
        self.archive(False)
        self.assertTrue(self.output.is_symlink())

    def test_output_inside_source(self):
        self.output = self.source / 'bad.zip'
        self.archive(False)
        self.assertFalse(self.output.exists())

    def test_special_file(self):
        os.mkfifo(self.source / 'pipe')
        self.archive(False)
        self.assertFalse(self.output.exists())

    def test_default_output(self):
        subprocess.run([str(BIN), str(self.source)], check=True, capture_output=True)
        self.assertTrue(Path(str(self.source) + '.zip').is_file())

    def test_copy_output(self):
        (self.source / 'linked').symlink_to(self.external / '内容.txt')
        self.archive(True, '--copy-output')
        with zipfile.ZipFile(self.output) as z:
            self.assertIsNone(z.testzip())
            self.assertEqual(z.read(self.source.name + '/linked').decode(), '外部の実体\n')
        self.assertFalse(list(self.base.glob('.resolve-archive-*')))

    def test_utf8_headers_and_extraction(self):
        names = ['日本語.txt', '가나다.txt', '絵文字😀.txt', 'カ\u3099.txt']
        for name in names:
            (self.source / name).write_text(name, encoding='utf-8')
        self.archive()
        with zipfile.ZipFile(self.output) as z, self.output.open('rb') as raw:
            self.assertIsNone(z.testzip())
            for item in z.infolist():
                self.assertTrue(item.flag_bits & 0x800, item.filename)
                raw.seek(item.header_offset)
                header = raw.read(30)
                self.assertEqual(header[:4], b'PK\x03\x04')
                self.assertTrue(struct.unpack_from('<H', header, 6)[0] & 0x800)
                name_length = struct.unpack_from('<H', header, 26)[0]
                self.assertEqual(raw.read(name_length).decode('utf-8'), item.filename)
            extracted = self.base / 'extracted'
            z.extractall(extracted)
        for name in names:
            self.assertEqual((extracted / self.source.name / name).read_text(), name)
        mac_extracted = self.base / 'mac-extracted'
        subprocess.run(['/usr/bin/ditto', '-x', '-k', str(self.output), str(mac_extracted)], check=True)
        for name in names:
            self.assertEqual((mac_extracted / self.source.name / name).read_text(), name)

    def test_copy_output_existing(self):
        self.output.write_bytes(b'keep me')
        self.archive(False, '--copy-output')
        self.assertEqual(self.output.read_bytes(), b'keep me')

    def test_read_only_directory_cleanup(self):
        child = self.source / 'read-only'
        child.mkdir()
        (child / 'file').write_text('contents')
        child.chmod(0o555)
        try:
            result = self.archive()
            self.assertNotIn('temporary files remain', result.stderr)
            self.assertEqual(stat.S_IMODE(child.stat().st_mode), 0o555)
        finally:
            child.chmod(0o755)


if __name__ == '__main__':
    unittest.main(verbosity=2)
