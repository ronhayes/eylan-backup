import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name('eylan-backup.sh')


def bash_path(path: Path) -> str:
    path = path.resolve()
    if os.name == 'nt':
        return f'/{path.drive[0].lower()}{path.as_posix()[2:]}'
    return path.as_posix()


class UpdateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix='update-test-', dir=SCRIPT.parent)
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.posix_root = bash_path(self.root)
        self.assertNotRegex(self.posix_root, r'\s', 'Test directory must not contain whitespace')
        for directory in ('bin', 'config', 'backups', 'sbin', 'systemd', 'lock'):
            (self.root / directory).mkdir()
        self.installed = self.root / 'sbin' / 'eylan-backup'
        self.service = self.root / 'systemd' / 'eylan-backup.service'
        self.timer = self.root / 'systemd' / 'eylan-backup.timer'
        self.key = self.root / 'config' / 'passphrase'
        self.credentials = self.root / 'config' / 'telegram'
        self.backup = self.root / 'backups' / 'existing.gpg'
        self.installed.write_text('#!/usr/bin/env bash\n# previous executable\n', encoding='utf-8')
        self.service.write_text(
            '[Unit]\nDescription=Encrypted Eylan panel backup\n[Service]\nType=oneshot\n'
            f'ExecStart={bash_path(self.installed)} --backup\n', encoding='utf-8', newline='\n')
        self.timer.write_text(
            '[Unit]\nDescription=Hourly Eylan backup\n[Timer]\nOnCalendar=hourly\n'
            'Persistent=true\nUnit=eylan-backup.service\n[Install]\nWantedBy=timers.target\n',
            encoding='utf-8', newline='\n')
        self.key.write_bytes(b'original-secret-key\n')
        self.credentials.write_bytes(b'123456:example_token\n-12345\n')
        self.backup.write_bytes(b'existing encrypted backup\n')
        self.original_executable = self.installed.read_bytes()
        self.original_timer = self.timer.read_bytes()
        self.protected = {path: path.read_bytes() for path in
                          (self.key, self.credentials, self.backup, self.service)}
        self.fake('stat', '''
path=${@: -1}
if [[ -d $path || $path == "$FAKE_SELF" ]]; then printf '0:700\\n'; else printf '0:600\\n'; fi
''')
        self.fake('flock', '''
printf '%s\\n' "$*" >> "$FAKE_ROOT/flock.log"
[[ ! -e $FAKE_ROOT/fail-flock ]]
''')
        self.fake('systemctl', '''
printf '%s\\n' "$*" >> "$FAKE_ROOT/systemctl.log"
case "$1" in
    show)
        case "$2" in
            *FragmentPath*) printf '%s/%s\\n' "$FAKE_ROOT/systemd" "${@: -1}" ;;
            *DropInPaths*) printf '\\n' ;;
            *ActiveState*)
                if [[ ${@: -1} == eylan-backup.timer ]]; then
                    /usr/bin/cat "$FAKE_ROOT/active"
                else
                    printf 'inactive\\n'
                fi ;;
            *) exit 1 ;;
        esac ;;
    is-active)
        [[ ${@: -1} == eylan-backup.timer && $(<"$FAKE_ROOT/active") == active ]] ;;
    is-enabled)
        [[ $(<"$FAKE_ROOT/enabled") == enabled ]] ;;
    stop)
        [[ $2 == eylan-backup.timer ]] || exit 1
        printf inactive > "$FAKE_ROOT/active" ;;
    start)
        [[ $2 == eylan-backup.timer ]] || exit 1
        if [[ -e $FAKE_ROOT/fail-start ]]; then
            /usr/bin/cp "$FAKE_SELF" "$FAKE_ROOT/executable-at-failure"
            /usr/bin/cp "$FAKE_ROOT/systemd/eylan-backup.timer" "$FAKE_ROOT/timer-at-failure"
            /usr/bin/rm -f "$FAKE_ROOT/fail-start"
            exit 1
        fi
        printf active > "$FAKE_ROOT/active" ;;
    enable)
        printf enabled > "$FAKE_ROOT/enabled"
        [[ " $* " != *' --now '* ]] || printf active > "$FAKE_ROOT/active" ;;
    disable)
        printf disabled > "$FAKE_ROOT/enabled"
        [[ " $* " != *' --now '* ]] || printf inactive > "$FAKE_ROOT/active" ;;
    daemon-reload)
        if [[ -e $FAKE_ROOT/fail-reload ]]; then
            /usr/bin/cp "$FAKE_SELF" "$FAKE_ROOT/executable-at-failure"
            /usr/bin/cp "$FAKE_ROOT/systemd/eylan-backup.timer" "$FAKE_ROOT/timer-at-failure"
            /usr/bin/rm -f "$FAKE_ROOT/fail-reload"
            exit 1
        elif [[ -e $FAKE_ROOT/fail-rollback-reload ]]; then
            exit 1
        fi ;;
    *) printf 'Unexpected systemctl call: %s\\n' "$*" >&2; exit 1 ;;
esac
''')
        for name in ('python3', 'curl', 'openssl', 'gpg', 'runuser', 'pg_dump', 'pg_restore',
                     'psql', 'createdb', 'sudo', 'su', 'reboot', 'shutdown'):
            self.fake(name, 'printf "Forbidden command: %s\\n" "$0" >&2; exit 97\n')

    def fake(self, name: str, body: str) -> None:
        path = self.root / 'bin' / name
        path.write_text('#!/usr/bin/env bash\n' + body, encoding='utf-8', newline='\n')
        path.chmod(0o755)

    def run_update(self, active: bool, fail_reload: bool = False,
                   fail_start: bool = False, fail_rollback: bool = False,
                   fail_flock: bool = False) -> subprocess.CompletedProcess:
        (self.root / 'active').write_text('active' if active else 'inactive', encoding='utf-8')
        (self.root / 'enabled').write_text('enabled', encoding='utf-8')
        for enabled, name in ((fail_reload, 'fail-reload'), (fail_start, 'fail-start'),
                              (fail_rollback, 'fail-rollback-reload'), (fail_flock, 'fail-flock')):
            if enabled:
                (self.root / name).touch()
        source = SCRIPT.read_text(encoding='utf-8')
        substitutions = {
            'export PATH=/usr/sbin:/usr/bin:/sbin:/bin':
                f'export PATH={shlex.quote(self.posix_root + "/bin")}:/usr/bin:/bin',
            '/var/backups/eylan-backup': self.posix_root + '/backups',
            '/etc/eylan-backup': self.posix_root + '/config',
            '/usr/local/sbin/eylan-backup': self.posix_root + '/sbin/eylan-backup',
            '/etc/systemd/system': self.posix_root + '/systemd',
            '/run/lock/eylan-backup.lock': self.posix_root + '/lock/eylan-backup.lock',
            "[[ $EUID -eq 0 ]] || fail 'This program must be run as root.'": ': # simulated root',
        }
        for original, replacement in substitutions.items():
            self.assertIn(original, source, f'Test transformation needs updating: {original}')
            source = source.replace(original, replacement)
        self.download = self.root / 'download.sh'
        self.download.write_text(source, encoding='utf-8', newline='\n')
        bash = shutil.which('bash')
        self.assertIsNotNone(bash, 'Git Bash must be available on PATH')
        env = os.environ.copy()
        env.update(FAKE_ROOT=self.posix_root, FAKE_SELF=bash_path(self.installed))
        return subprocess.run([bash, bash_path(self.download)], input=b'1\nYES\n',
                              capture_output=True, env=env, cwd=self.root, timeout=30)

    def assert_protected(self) -> None:
        for path, content in self.protected.items():
            self.assertEqual(path.read_bytes(), content, str(path))

    def test_active_timer_success_preserves_data(self) -> None:
        result = self.run_update(active=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.installed.read_bytes(), self.download.read_bytes())
        self.assertIn(b'OnUnitInactiveSec=1h', self.timer.read_bytes())
        self.assertEqual((self.root / 'active').read_text(), 'active')
        self.assert_protected()

    def test_inactive_timer_stays_inactive(self) -> None:
        result = self.run_update(active=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.installed.read_bytes(), self.download.read_bytes())
        self.assertEqual((self.root / 'active').read_text(), 'inactive')
        self.assert_protected()

    def assert_reload_failure_rolls_back(self, active: bool) -> None:
        result = self.run_update(active=active, fail_reload=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = (self.root / 'systemctl.log').read_text(encoding='utf-8')
        if active:
            self.assertIn('stop eylan-backup.timer', calls)
        self.assertGreaterEqual(calls.count('daemon-reload'), 2)
        self.assertEqual((self.root / 'executable-at-failure').read_bytes(),
                         self.download.read_bytes())
        self.assertIn(b'OnUnitInactiveSec=1h',
                      (self.root / 'timer-at-failure').read_bytes())
        self.assertEqual(self.installed.read_bytes(), self.original_executable)
        self.assertEqual(self.timer.read_bytes(), self.original_timer)
        self.assertEqual((self.root / 'active').read_text(),
                         'active' if active else 'inactive')
        self.assert_protected()

    def test_reload_failure_restores_active_timer(self) -> None:
        self.assert_reload_failure_rolls_back(active=True)

    def test_reload_failure_keeps_inactive_timer_inactive(self) -> None:
        self.assert_reload_failure_rolls_back(active=False)

    def test_start_failure_restores_files_and_active_timer(self) -> None:
        result = self.run_update(active=True, fail_start=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'previous files and timer state restored', result.stderr)
        calls = (self.root / 'systemctl.log').read_text(encoding='utf-8')
        self.assertEqual(calls.count('start eylan-backup.timer'), 2)
        self.assertEqual((self.root / 'executable-at-failure').read_bytes(),
                         self.download.read_bytes())
        self.assertIn(b'OnUnitInactiveSec=1h', (self.root / 'timer-at-failure').read_bytes())
        self.assertEqual(self.installed.read_bytes(), self.original_executable)
        self.assertEqual(self.timer.read_bytes(), self.original_timer)
        self.assertEqual((self.root / 'active').read_text(), 'active')
        self.assert_protected()

    def test_rollback_failure_reports_manual_intervention(self) -> None:
        result = self.run_update(active=True, fail_reload=True, fail_rollback=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'Rollback incomplete', result.stderr)
        self.assertIn(b'Restore the retained copies manually', result.stderr)
        self.assertGreaterEqual((self.root / 'systemctl.log').read_text().count('daemon-reload'), 2)
        self.assertEqual((self.root / 'executable-at-failure').read_bytes(),
                         self.download.read_bytes())
        self.assertEqual(self.installed.read_bytes(), self.original_executable)
        self.assertEqual(self.timer.read_bytes(), self.original_timer)
        self.assertEqual((self.root / 'active').read_text(), 'inactive')
        self.assert_protected()

    def test_lock_contention_aborts_without_changes(self) -> None:
        result = self.run_update(active=True, fail_flock=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'Another operation is running', result.stderr)
        self.assertTrue((self.root / 'flock.log').exists())
        self.assertFalse((self.root / 'systemctl.log').exists())
        self.assertEqual(self.installed.read_bytes(), self.original_executable)
        self.assertEqual(self.timer.read_bytes(), self.original_timer)
        self.assertEqual((self.root / 'active').read_text(), 'active')
        self.assert_protected()


if __name__ == '__main__':
    unittest.main()
