#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

BASE=/var/backups/eylan-backup
CONFIG=/etc/eylan-backup
KEY=$CONFIG/passphrase
CREDS=$CONFIG/telegram
SELF=/usr/local/sbin/eylan-backup
SERVICE=openvpn_manager.service
DB=eylan_panel
ROLE=eylan_user
MAX_UPLOAD=49000000

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
need() { local x; for x in "$@"; do command -v "$x" >/dev/null || fail "Required program is not installed: $x"; done; }
confirm() { local answer; read -r -p 'Enter YES to continue: ' answer; [[ $answer == YES ]] || fail 'Operation cancelled.'; }
lock() { exec 9>/run/lock/eylan-backup.lock; flock -n 9 || fail 'Another operation is running.'; }
check_key() {
    [[ -f $KEY && ! -L $KEY ]] || fail 'Local key is missing; restore it separately.'
    [[ $(stat -c '%u:%a' "$KEY") == 0:600 ]] || fail 'The key must be owned by root and have permissions 600.'
}
gpg_encrypt() { gpg --no-options --batch --yes --pinentry-mode loopback --passphrase-file "$KEY" --symmetric --cipher-algo AES256 --output "$1"; }
gpg_decrypt() { gpg --no-options --batch --yes --pinentry-mode loopback --passphrase-file "$KEY" --decrypt "$1"; }

setup() {
    need systemctl install openssl gpg python3 curl runuser pg_dump pg_restore psql createdb flock stat mktemp tar
    [[ ! -e $SELF && ! -e /etc/systemd/system/eylan-backup.service && ! -e /etc/systemd/system/eylan-backup.timer && ! -e $CREDS ]] || fail 'A previous installation or file with the same name exists; no automatic overwrite will occur.'
    printf '%s\n' 'An hourly timer will be installed, the token saved, and a local key created.'
    printf '%s\n' 'Keep the token and key separately and securely. No existing files will be overwritten.'
    local token chat
    read -r -s -p 'Telegram bot token: ' token; printf '\n'
    read -r -p 'Telegram numeric chat ID: ' chat
    [[ $token =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || fail 'Invalid token format.'
    [[ $chat =~ ^-?[0-9]+$ ]] || fail 'The chat ID must be numeric.'
    confirm
    lock
    install -d -m 700 "$CONFIG" "$BASE"
    if [[ -e $KEY || -L $KEY ]]; then check_key; else (set -o noclobber; openssl rand -base64 48 > "$KEY"); chmod 600 "$KEY"; fi
    (set -o noclobber; printf '%s\n%s\n' "$token" "$chat" > "$CREDS")
    unset token chat
    install -m 700 -- "$0" "$SELF"
    (set -o noclobber; printf '%s\n' '[Unit]' 'Description=Encrypted Eylan panel backup' '[Service]' 'Type=oneshot' "ExecStart=$SELF --backup" > /etc/systemd/system/eylan-backup.service)
    (set -o noclobber; printf '%s\n' '[Unit]' 'Description=Hourly Eylan backup' '[Timer]' 'OnCalendar=hourly' 'Persistent=true' 'Unit=eylan-backup.service' '[Install]' 'WantedBy=timers.target' > /etc/systemd/system/eylan-backup.timer)
    systemctl daemon-reload
    systemctl enable --now eylan-backup.timer
    printf '%s\n' 'Timer enabled. Back up the key /etc/eylan-backup/passphrase separately and securely.'
}

backup() {
    need gpg python3 curl runuser pg_dump flock stat mktemp
    lock
    check_key
    [[ -f $CREDS && ! -L $CREDS && $(stat -c '%u:%a' "$CREDS") == 0:600 ]] || fail 'The Telegram credentials file is invalid.'
    local token chat work archive size status
    mapfile -t credentials < "$CREDS"
    [[ ${#credentials[@]} == 2 && ${credentials[0]} =~ ^[0-9]+:[A-Za-z0-9_-]+$ && ${credentials[1]} =~ ^-?[0-9]+$ ]] || fail 'Telegram credentials are invalid.'
    token=${credentials[0]}; chat=${credentials[1]}; unset credentials
    install -d -m 700 "$BASE"
    local -a existing
    shopt -s nullglob
    existing=("$BASE"/eylan-*.tar.gz.gpg)
    shopt -u nullglob
    (( ${#existing[@]} < 48 )) || fail 'There are 48 local backups; free up space after manual review.'
    work=$(mktemp -d "$BASE/.work.XXXXXXXX")
    trap 'rm -rf -- "$work"' EXIT
    runuser -u postgres -- pg_dump --format=custom --no-owner --no-privileges "$DB" | gpg_encrypt "$work/database.dump.gpg"
    archive=$(mktemp "$BASE/eylan-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXXXX.tar.gz.gpg")
    if ! python3 -I - "$work/database.dump.gpg" <<'PY' | gpg_encrypt "$work/archive.gpg"
import os, sys, tarfile
paths = ('/root/settings.json', '/root/.secret_key', '/root/license.key', '/root/instance', '/root/ovpnfiles', '/root/.acme.sh', '/etc/openvpn', '/etc/ocserv', '/etc/ipsec.conf', '/etc/ipsec.secrets', '/etc/wireguard', '/etc/eylan-singbox', '/etc/letsencrypt', '/etc/ipsec.d', '/etc/strongswan.conf', '/etc/strongswan.d', '/etc/xl2tpd', '/etc/ppp', '/etc/sysctl.d', '/etc/ssl/openvpn_manager', '/etc/systemd/system/openvpn_manager.service', '/etc/systemd/system/openvpn_manager.service.d', '/etc/iptables/rules.v4', '/etc/iptables/rules.v6')
def safe(info):
    if info.isfile() or info.isdir():
        return info
    print('Skipping link or special file: ' + info.name, file=sys.stderr)
    return None
with tarfile.open(fileobj=sys.stdout.buffer, mode='w|gz', dereference=False) as t:
    t.add(sys.argv[1], arcname='database.dump.gpg', recursive=False)
    for path in paths:
        if os.path.lexists(path):
            t.add(path, arcname='files/' + path.lstrip('/'), filter=safe)
        else:
            print('Missing: ' + path, file=sys.stderr)
PY
    then rm -f -- "$archive"; fail 'Archive creation failed.'; fi
    mv -f -- "$work/archive.gpg" "$archive"
    size=$(stat -c %s "$archive")
    printf 'Local encrypted backup: %s (%s bytes)\n' "$archive" "$size"
    (( size <= MAX_UPLOAD )) || fail 'The file is too large for the Telegram Bot API; the local backup was retained.'
    # URL containing the token is passed through stdin, never argv or logs.
    if ! status=$(printf 'url = "https://api.telegram.org/bot%s/sendDocument"\n' "$token" | curl --config - --silent --output "$work/response" --write-out '%{http_code}' --connect-timeout 15 --max-time 300 --proto '=https' --form-string "chat_id=$chat" --form "document=@$archive;type=application/octet-stream"); then
        fail 'Upload failed; the local backup was retained.'
    fi
    unset token chat
    [[ $status == 200 ]] || fail 'Telegram did not return a successful HTTP response; the local backup was retained.'
    python3 -I - "$work/response" <<'PY' || fail 'The Telegram response indicated failure or was invalid; the local backup was retained.'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    result = json.load(f)
if not isinstance(result, dict) or result.get('ok') is not True:
    raise SystemExit(1)
PY
    printf '%s\n' 'Upload to Telegram confirmed.'
    rm -rf -- "$work"
    trap - EXIT
}

restore() {
    need gpg python3 openssl runuser pg_dump pg_restore psql createdb systemctl flock stat mktemp install
    check_key
    local file recovery stamp staged saved pre active=0 stopped=0 switched=0
    printf '%s\n' 'Only the database will be replaced; files will be placed in the recovery directory for manual review.'
    printf '%s\n' 'Restoring a dump can execute arbitrary SQL; select only a trusted, reviewed backup.'
    printf '%s\n' 'The old database will not be deleted. Only the panel service will be stopped; stop other writers yourself.'
    printf '%s\n' 'This is experimental; test the restore on a test server before using it on the production server.'
    read -r -p 'Full path to local archive: ' file
    [[ -f $file && ! -L $file ]] || fail 'The archive is not a regular file.'
    confirm
    lock
    install -d -m 700 "$BASE"
    recovery=$(mktemp -d /root/eylan-recovery-XXXXXXXX)
    printf 'Recovery directory: %s\n' "$recovery"
    # Only extract regular files and directories under the fixed allowlist, without links.
    if ! gpg_decrypt "$file" | { python3 -I - "$recovery" 3<&0 <<'PY'
import os, sys, tarfile
from pathlib import PurePosixPath
root = sys.argv[1]
allowed = ('root/settings.json', 'root/.secret_key', 'root/license.key', 'root/instance', 'root/ovpnfiles', 'root/.acme.sh', 'etc/openvpn', 'etc/ocserv', 'etc/ipsec.conf', 'etc/ipsec.secrets', 'etc/wireguard', 'etc/eylan-singbox', 'etc/letsencrypt', 'etc/ipsec.d', 'etc/strongswan.conf', 'etc/strongswan.d', 'etc/xl2tpd', 'etc/ppp', 'etc/sysctl.d', 'etc/ssl/openvpn_manager', 'etc/systemd/system/openvpn_manager.service', 'etc/systemd/system/openvpn_manager.service.d', 'etc/iptables/rules.v4', 'etc/iptables/rules.v6')
seen = set()
total = 0
with os.fdopen(3, 'rb') as archive, tarfile.open(fileobj=archive, mode='r|gz') as tar:
    for member in tar:
        name = member.name
        parts = name.split('/')
        if not name or any(p in ('', '.', '..') for p in parts) or name.startswith('/') or name in seen:
            raise ValueError('invalid or duplicate archive path')
        seen.add(name)
        if name == 'database.dump.gpg':
            if not member.isfile(): raise ValueError('invalid database entry')
        elif name.startswith('files/'):
            sub = name[6:]
            if not any(sub == p or sub.startswith(p + '/') or (member.isdir() and p.startswith(sub + '/')) for p in allowed):
                raise ValueError('path outside allowlist')
        else:
            raise ValueError('unexpected archive entry')
        if not (member.isdir() or member.isfile()): raise ValueError('links and special files forbidden')
        if len(seen) > 100000 or member.size < 0: raise ValueError('archive limit exceeded')
        total += member.size
        if total > 20 * 1024**3: raise ValueError('archive size limit exceeded')
        dest = os.path.join(root, *parts)
        if member.isdir():
            os.makedirs(dest, mode=0o700, exist_ok=True)
        else:
            os.makedirs(os.path.dirname(dest), mode=0o700, exist_ok=True)
            src = tar.extractfile(member)
            if src is None: raise ValueError('missing file content')
            fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, 'wb') as out:
                remaining = member.size
                while remaining:
                    chunk = src.read(min(1024 * 1024, remaining))
                    if not chunk: raise ValueError('truncated file')
                    out.write(chunk)
                    remaining -= len(chunk)
    if 'database.dump.gpg' not in seen: raise ValueError('database missing')
    while archive.read(1024 * 1024):
        pass
PY
    }; then fail "Validation or decryption failed; the directory was retained for inspection: $recovery"; fi
    gpg_decrypt "$recovery/database.dump.gpg" > "$recovery/database.dump" || fail "Database decryption failed: $recovery"
    pg_restore --list "$recovery/database.dump" >/dev/null || fail 'Invalid dump format.'
    stamp=$(date -u +%Y%m%d%H%M%S)_$(openssl rand -hex 4)
    staged="eylan_stage_$stamp"; saved="eylan_old_$stamp"
    printf 'New database: %s; old database name: %s\n' "$staged" "$saved"
    printf '%s\n' 'A staging database will now be created and the backup SQL executed; then the service will be stopped and the database switched.'
    confirm
    runuser -u postgres -- createdb --owner="$ROLE" --template=template0 "$staged"
    runuser -u postgres -- pg_restore --exit-on-error --no-owner --no-privileges --role="$ROLE" --dbname="$staged" < "$recovery/database.dump" || fail "Staging restore failed; database $staged was retained for inspection."
    if systemctl is-active --quiet "$SERVICE"; then active=1; fi
    cleanup_restore() {
        local rc=$?
        trap - EXIT
        if (( stopped && active )); then
            if ! systemctl start "$SERVICE"; then printf 'Error: Start the service manually: %s\n' "$SERVICE" >&2; rc=1; fi
        fi
        if (( rc != 0 )); then printf 'Restore failed; the staging/previous database has not been deleted. Directory: %s\n' "$recovery" >&2; fi
        exit "$rc"
    }
    trap cleanup_restore EXIT
    if (( active )); then
        stopped=1
        systemctl stop "$SERVICE" || fail 'Failed to stop the service.'
    fi
    pre=$(mktemp "$BASE/pre-restore-$stamp-XXXXXXXX.dump.gpg")
    if ! runuser -u postgres -- pg_dump --format=custom --no-owner --no-privileges "$DB" | gpg_encrypt "$pre"; then
        fail "Pre-restore backup failed; possibly incomplete file: $pre"
    fi
    printf 'Encrypted pre-restore backup: %s\n' "$pre"
    # Fixed identifiers are generated internally; both renames commit atomically.
    runuser -u postgres -- psql --no-psqlrc -v ON_ERROR_STOP=1 --dbname=postgres --single-transaction \
        -c "ALTER DATABASE \"$DB\" RENAME TO \"$saved\";" \
        -c "ALTER DATABASE \"$staged\" RENAME TO \"$DB\";" || fail 'Database switch failed; the transaction was rolled back.'
    switched=1
    printf 'The previous database was retained as %s. Review and manually restore the files in %s.\n' "$saved" "$recovery/files"
    printf 'The decrypted dump file remains at %s; securely delete it once you are sure it is no longer needed.\n' "$recovery/database.dump"
    cleanup_restore
}

[[ $EUID -eq 0 ]] || fail 'This program must be run as root.'
printf '%s\n' 'Warning: This is experimental; do not install or run it on the production server.' >&2
case ${1-} in
    --backup) [[ $# == 1 ]] || fail 'Invalid argument.'; backup ;;
    '')
        printf '%s\n' '1) Set up hourly backups' '2) Restore a local backup' '0) Exit'
        read -r -p 'Choice: ' choice
        case $choice in 1) setup ;; 2) restore ;; 0) exit 0 ;; *) fail 'Invalid choice.' ;; esac ;;
    *) fail 'Invalid argument.' ;;
esac
