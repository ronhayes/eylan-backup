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

service_unit() { printf '%s\n' '[Unit]' 'Description=Encrypted Eylan panel backup' '[Service]' 'Type=oneshot' "ExecStart=$SELF --backup"; }
old_timer_unit() { printf '%s\n' '[Unit]' 'Description=Hourly Eylan backup' '[Timer]' 'OnCalendar=hourly' 'Persistent=true' 'Unit=eylan-backup.service' '[Install]' 'WantedBy=timers.target'; }
timer_unit() { printf '%s\n' '[Unit]' 'Description=Hourly Eylan backup' '[Timer]' 'OnActiveSec=1h' 'OnUnitInactiveSec=1h' 'Unit=eylan-backup.service' '[Install]' 'WantedBy=timers.target'; }

setup() {
    need systemctl install openssl gpg python3 curl runuser pg_dump pg_restore psql createdb flock stat mktemp tar cmp cp mv rm chmod bash grep
    local service=/etc/systemd/system/eylan-backup.service timer=/etc/systemd/system/eylan-backup.timer
    local token chat dropins fragment dir name unit
    for dir in "$CONFIG" "$BASE"; do
        if [[ -e $dir || -L $dir ]]; then
            [[ -d $dir && ! -L $dir && $(stat -c '%u:%a' "$dir") == 0:700 ]] || fail "Unsafe existing directory: $dir"
        fi
    done
    local -a credentials
    [[ -f $0 && ! -L $0 ]] || fail 'Run a regular downloaded script file.'
    lock
    if [[ -e $KEY || -L $KEY ]]; then check_key; [[ -s $KEY ]] || fail 'Existing key is empty.'; fi
    if [[ -e $SELF || -L $SELF || -e $service || -L $service || -e $timer || -L $timer || -e $CREDS || -L $CREDS ]]; then
        # Accept only the exact units created by this installer; custom units need manual review.
        [[ -d $CONFIG && ! -L $CONFIG && $(stat -c '%u:%a' "$CONFIG") == 0:700 && -d $BASE && ! -L $BASE && $(stat -c '%u:%a' "$BASE") == 0:700 ]] || fail 'Incomplete or unsafe installation; inspect it manually.'
        check_key
        [[ -s $KEY && -f $CREDS && ! -L $CREDS && $(stat -c '%u:%a' "$CREDS") == 0:600 ]] || fail 'Incomplete or unsafe credentials; inspect the installation manually.'
        mapfile -t credentials < "$CREDS"
        [[ ${#credentials[@]} == 2 && ${credentials[0]} =~ ^[0-9]+:[A-Za-z0-9_-]+$ && ${credentials[1]} =~ ^-?[0-9]+$ ]] || fail 'Invalid credentials; inspect the installation manually.'
        unset credentials
        [[ -f $SELF && ! -L $SELF && $(stat -c '%u:%a' "$SELF") == 0:700 && -f $service && ! -L $service && $(stat -c '%u:%a' "$service") == 0:600 && -f $timer && ! -L $timer && $(stat -c '%u:%a' "$timer") == 0:600 ]] || fail 'Incomplete or unsafe installation files; inspect them manually.'
        cmp -s "$service" <(service_unit) || fail 'Unrecognized service unit; inspect it manually.'
        if ! cmp -s "$timer" <(old_timer_unit) && ! cmp -s "$timer" <(timer_unit); then fail 'Unrecognized timer unit; inspect it manually.'; fi
        [[ ! $0 -ef $SELF ]] || fail 'Already running the installed executable; download the new script and run that instead.'
        for unit in eylan-backup.service eylan-backup.timer; do
            fragment=$(systemctl show --property=FragmentPath --value "$unit") || fail 'Cannot inspect systemd unit.'
            dropins=$(systemctl show --property=DropInPaths --value "$unit") || fail 'Cannot inspect systemd drop-ins.'
            [[ $fragment == "/etc/systemd/system/$unit" && -z $dropins ]] || fail 'Systemd unit overrides exist; inspect them manually before updating.'
        done
        # A timer run must not start while this process holds the backup lock.
        if systemctl is-active --quiet eylan-backup.service; then fail 'Backup service is active; retry after it finishes.'; fi
        printf '%s\n' 'Update the executable and timer? Existing key, credentials, database and backups will not be changed.'
        confirm
            local staged='' staged_timer='' old='' old_timer='' rollback_file=''
            local timer_state='' service_state='' transaction=0 self_changed=0 timer_changed=0 lock_released=0
            update_cleanup() {
                local rc=$? rollback_failed=0 file
                trap - EXIT
                trap '' INT TERM HUP
                set +e
                if (( rc != 0 && transaction )); then
                    if (( lock_released )); then
                        exec 9>/run/lock/eylan-backup.lock && flock -n 9 || rollback_failed=1
                        service_state=$(systemctl show --property=ActiveState --value eylan-backup.service) || rollback_failed=1
                        [[ $service_state == inactive || $service_state == failed ]] || rollback_failed=1
                    fi
                    if (( rollback_failed )); then
                        printf 'Error: Backup lock unavailable or service active; automatic rollback skipped. Restore retained copies after other operations finish, reload systemd, and restore timer state (%s). Executable: %s; timer: %s\n' "$timer_state" "$old" "${old_timer:-unchanged}" >&2
                    else
                        systemctl stop eylan-backup.timer || rollback_failed=1
                        if (( self_changed )); then
                            rollback_file=$(mktemp "${SELF}.rollback.XXXXXXXX") &&
                                cp -p -- "$old" "$rollback_file" &&
                                mv -f -- "$rollback_file" "$SELF" || rollback_failed=1
                        fi
                        if (( timer_changed )); then
                            rollback_file=$(mktemp "${timer}.rollback.XXXXXXXX") &&
                                cp -p -- "$old_timer" "$rollback_file" &&
                                mv -f -- "$rollback_file" "$timer" || rollback_failed=1
                        fi
                        systemctl daemon-reload || rollback_failed=1
                        if (( ! rollback_failed )) && [[ $timer_state == active ]]; then
                            exec 9>&- || rollback_failed=1
                            if (( ! rollback_failed )); then
                                systemctl start eylan-backup.timer || rollback_failed=1
                            fi
                        fi
                        if (( rollback_failed )); then
                            printf 'Error: Rollback incomplete; timer may be stopped. Restore the retained copies manually, run systemctl daemon-reload, and restore timer state (%s). Executable: %s; timer: %s\n' "$timer_state" "$old" "${old_timer:-unchanged}" >&2
                        else
                            printf '%s\n' 'Update failed; previous files and timer state restored.' >&2
                        fi
                    fi
                fi
                for file in "$staged" "$staged_timer" "$rollback_file"; do
                    if [[ -n $file ]] && ! rm -f -- "$file"; then
                        printf 'Error: Could not remove temporary file: %s\n' "$file" >&2
                        rc=1
                    fi
                done
                exit "$rc"
            }
            trap update_cleanup EXIT
            trap 'exit 130' INT
            trap 'exit 143' TERM
            trap 'exit 129' HUP
            staged=$(mktemp "${SELF}.new.XXXXXXXX") || fail 'Cannot stage executable.'
            install -m 700 -- "$0" "$staged" || fail 'Cannot stage executable.'
            bash -n "$staged" || fail 'Downloaded script has invalid Bash syntax.'
            old=$(mktemp "${SELF}.previous.XXXXXXXX") || fail 'Cannot preserve executable.'
            cp -p -- "$SELF" "$old" || fail "Cannot preserve executable: $old"
            printf 'Previous executable retained: %s\n' "$old"
            if ! cmp -s "$timer" <(timer_unit); then
                staged_timer=$(mktemp "${timer}.new.XXXXXXXX") || fail 'Cannot stage timer.'
                timer_unit > "$staged_timer" || fail 'Cannot stage timer.'
                old_timer=$(mktemp "${timer}.previous.XXXXXXXX") || fail 'Cannot preserve timer.'
                cp -p -- "$timer" "$old_timer" || fail "Cannot preserve timer: $old_timer"
                printf 'Previous timer retained: %s\n' "$old_timer"
            fi
            timer_state=$(systemctl show --property=ActiveState --value eylan-backup.timer) || fail 'Cannot inspect timer state.'
            [[ $timer_state == active || $timer_state == inactive ]] || fail "Unexpected timer state: $timer_state"
            transaction=1
            if [[ $timer_state == active ]]; then
                systemctl stop eylan-backup.timer || fail 'Could not stop timer.'
            fi
            service_state=$(systemctl show --property=ActiveState --value eylan-backup.service) || fail 'Cannot inspect backup service state.'
            [[ $service_state == inactive || $service_state == failed ]] || fail 'Backup service is active; retry after it finishes.'
            if [[ -n $staged_timer ]]; then
                timer_changed=1
                mv -f -- "$staged_timer" "$timer" || fail 'Cannot install timer.'
                staged_timer=''
            fi
            self_changed=1
            mv -f -- "$staged" "$SELF" || fail 'Cannot install executable.'
            staged=''
            systemctl daemon-reload || fail 'Cannot reload systemd.'
            if [[ $timer_state == active ]]; then
                lock_released=1
                exec 9>&- || fail 'Cannot release backup lock.'
                systemctl start eylan-backup.timer || fail 'Cannot restore timer activity.'
            fi
            transaction=0
            trap - EXIT INT TERM HUP
        if (( ! lock_released )); then exec 9>&- || fail 'Cannot release backup lock.'; fi
        printf '%s\n' 'Update installed. Check the timer and service journal.'
        return
    fi
    printf '%s\n' 'An hourly timer will be installed, the token saved, and a local key created.'
    printf '%s\n' 'Keep the token and key separately and securely. No existing files will be overwritten.'
    read -r -s -p 'Telegram bot token: ' token; printf '\n'
    read -r -p 'Telegram numeric chat ID: ' chat
    [[ $token =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || fail 'Invalid token format.'
    [[ $chat =~ ^-?[0-9]+$ ]] || fail 'The chat ID must be numeric.'
    confirm
    install -d -m 700 "$CONFIG" "$BASE"
    if [[ -e $KEY || -L $KEY ]]; then check_key; else (set -o noclobber; openssl rand -base64 48 > "$KEY"); chmod 600 "$KEY"; fi
    (set -o noclobber; printf '%s\n%s\n' "$token" "$chat" > "$CREDS")
    unset token chat
    (set -o noclobber; : > "$SELF")
    install -m 700 -- "$0" "$SELF"
    (set -o noclobber; service_unit > "$service")
    (set -o noclobber; timer_unit > "$timer")
    systemctl daemon-reload || fail 'Installation incomplete: systemd reload failed; inspect files manually.'
    systemctl enable eylan-backup.timer || fail 'Installation incomplete: timer enable failed; inspect systemd status.'
    exec 9>&-
    local first_status=0
    systemctl start eylan-backup.service || first_status=$?
    systemctl start eylan-backup.timer || fail 'Timer start failed; inspect systemd status and the first backup journal.'
    (( first_status == 0 )) || fail 'First backup failed; inspect the service journal and any retained local backup.'
    printf '%s\n' 'First backup service completed. Check the journal for upload confirmation. Back up the key /etc/eylan-backup/passphrase separately and securely.'
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
    rm -- "$archive"
    printf '%s\n' 'Uploaded local backup removed.'
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
