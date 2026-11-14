import io
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('eylan-backup.sh').read_text(encoding='utf-8')
START = "python3 -I - \"$recovery\" 3<&0 <<'PY'\n"
extractor = SCRIPT.split(START, 1)[1].split('\nPY\n', 1)[0]
extractor = extractor.replace("os.fdopen(3, 'rb')", 'sys.stdin.buffer')
extractor = extractor.replace('os.O_NOFOLLOW', "getattr(os, 'O_NOFOLLOW', 0)")


def archive(entries):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode='w:gz') as tar:
        for name, content, kind in entries:
            info = tarfile.TarInfo(name)
            if kind == 'link':
                info.type = tarfile.SYMTYPE
                info.linkname = '../../outside'
                tar.addfile(info)
            else:
                info.size = len(content)
                tar.addfile(info, io.BytesIO(content))
    return output.getvalue()


def extract(entries, destination):
    return subprocess.run([sys.executable, '-I', '-c', extractor, destination],
                          input=archive(entries), capture_output=True, check=False)


class ArchiveTests(unittest.TestCase):
    def test_valid_backup_extracts_database_and_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            result = extract([('database.dump.gpg', b'database', 'file'),
                              ('files/root/settings.json', b'{}', 'file')], directory)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual((Path(directory) / 'database.dump.gpg').read_bytes(), b'database')
            self.assertEqual((Path(directory) / 'files/root/settings.json').read_bytes(), b'{}')

    def test_path_traversal_and_links_are_rejected(self):
        for name, kind in [('files/root/../../outside', 'file'),
                           ('files/root/settings.json', 'link')]:
            with self.subTest(name=name, kind=kind), tempfile.TemporaryDirectory() as directory:
                result = extract([('database.dump.gpg', b'db', 'file'),
                                  (name, b'data', kind)], directory)
                self.assertNotEqual(result.returncode, 0)
                expected = b'invalid or duplicate archive path' if kind == 'file' else b'links and special files forbidden'
                self.assertIn(expected, result.stderr)

    def test_missing_database_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertNotEqual(extract([('files/root/settings.json', b'{}', 'file')], directory).returncode, 0)


if __name__ == '__main__':
    unittest.main()
