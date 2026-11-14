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

fail() { printf 'خطا: %s\n' "$*" >&2; exit 1; }
need() { local x; for x in "$@"; do command -v "$x" >/dev/null || fail "برنامه موردنیاز نصب نیست: $x"; done; }
confirm() { local answer; read -r -p 'برای ادامه عبارت YES را وارد کنید: ' answer; [[ $answer == YES ]] || fail 'عملیات لغو شد.'; }
lock() { exec 9>/run/lock/eylan-backup.lock; flock -n 9 || fail 'عملیات دیگری در حال اجراست.'; }
check_key() {
    [[ -f $KEY && ! -L $KEY ]] || fail 'کلید محلی موجود نیست؛ آن را جداگانه بازیابی کنید.'
    [[ $(stat -c '%u:%a' "$KEY") == 0:600 ]] || fail 'مالک کلید باید root و دسترسی آن 600 باشد.'
}
gpg_encrypt() { gpg --no-options --batch --yes --pinentry-mode loopback --passphrase-file "$KEY" --symmetric --cipher-algo AES256 --output "$1"; }
gpg_decrypt() { gpg --no-options --batch --yes --pinentry-mode loopback --passphrase-file "$KEY" --decrypt "$1"; }

setup() {
    need systemctl install openssl gpg python3 curl runuser pg_dump pg_restore psql createdb flock stat mktemp tar
    [[ ! -e $SELF && ! -e /etc/systemd/system/eylan-backup.service && ! -e /etc/systemd/system/eylan-backup.timer && ! -e $CREDS ]] || fail 'نصب قبلی یا فایل همنام وجود دارد؛ بازنویسی خودکار انجام نمی‌شود.'
    printf '%s\n' 'نصب تایمر ساعتی، ذخیره توکن و ساخت کلید محلی انجام می‌شود.'
    printf '%s\n' 'توکن و کلید را جداگانه و امن نگهداری کنید. هیچ فایل قبلی بازنویسی نمی‌شود.'
    local token chat
    read -r -s -p 'Telegram bot token: ' token; printf '\n'
    read -r -p 'Telegram numeric chat ID: ' chat
    [[ $token =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || fail 'قالب توکن نامعتبر است.'
    [[ $chat =~ ^-?[0-9]+$ ]] || fail 'شناسه گفتگو باید عددی باشد.'
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
    printf '%s\n' 'تایمر فعال شد. کلید /etc/eylan-backup/passphrase را جداگانه و امن پشتیبان بگیرید.'
}

backup() {
    need gpg python3 curl runuser pg_dump flock stat mktemp
    lock
    check_key
    [[ -f $CREDS && ! -L $CREDS && $(stat -c '%u:%a' "$CREDS") == 0:600 ]] || fail 'فایل اطلاعات تلگرام معتبر نیست.'
    local token chat work archive size status
    mapfile -t credentials < "$CREDS"
    [[ ${#credentials[@]} == 2 && ${credentials[0]} =~ ^[0-9]+:[A-Za-z0-9_-]+$ && ${credentials[1]} =~ ^-?[0-9]+$ ]] || fail 'اطلاعات تلگرام نامعتبر است.'
    token=${credentials[0]}; chat=${credentials[1]}; unset credentials
    install -d -m 700 "$BASE"
    local -a existing
    shopt -s nullglob
    existing=("$BASE"/eylan-*.tar.gz.gpg)
    shopt -u nullglob
    (( ${#existing[@]} < 48 )) || fail '۴۸ نسخه محلی وجود دارد؛ پس از بررسی دستی، فضا آزاد کنید.'
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
    then rm -f -- "$archive"; fail 'ساخت بایگانی شکست خورد.'; fi
    mv -f -- "$work/archive.gpg" "$archive"
    size=$(stat -c %s "$archive")
    printf 'نسخه رمزگذاری‌شده محلی: %s (%s bytes)\n' "$archive" "$size"
    (( size <= MAX_UPLOAD )) || fail 'فایل برای Telegram Bot API بزرگ است؛ نسخه محلی حفظ شد.'
    # URL containing the token is passed through stdin, never argv or logs.
    if ! status=$(printf 'url = "https://api.telegram.org/bot%s/sendDocument"\n' "$token" | curl --config - --silent --output "$work/response" --write-out '%{http_code}' --connect-timeout 15 --max-time 300 --proto '=https' --form-string "chat_id=$chat" --form "document=@$archive;type=application/octet-stream"); then
        fail 'ارسال ناموفق بود؛ نسخه محلی حفظ شد.'
    fi
    unset token chat
    [[ $status == 200 ]] || fail 'Telegram پاسخ HTTP موفق نداد؛ نسخه محلی حفظ شد.'
    python3 -I - "$work/response" <<'PY' || fail 'پاسخ Telegram ناموفق یا نامعتبر بود؛ نسخه محلی حفظ شد.'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    result = json.load(f)
if not isinstance(result, dict) or result.get('ok') is not True:
    raise SystemExit(1)
PY
    printf '%s\n' 'ارسال به Telegram تأیید شد.'
    rm -rf -- "$work"
    trap - EXIT
}

restore() {
    need gpg python3 openssl runuser pg_dump pg_restore psql createdb systemctl flock stat mktemp install
    check_key
    local file recovery stamp staged saved pre active=0 stopped=0 switched=0
    printf '%s\n' 'فقط دیتابیس جایگزین می‌شود؛ فایل‌ها برای بررسی دستی در پوشه بازیابی قرار می‌گیرند.'
    printf '%s\n' 'بازیابی dump می‌تواند SQL دلخواه اجرا کند؛ فقط نسخه قابل اعتماد و بررسی‌شده را انتخاب کنید.'
    printf '%s\n' 'دیتابیس قدیمی حذف نمی‌شود. فقط سرویس پنل متوقف می‌شود؛ دیگر نویسندگان را خودتان متوقف کنید.'
    printf '%s\n' 'نسخه آزمایشی است؛ پیش از استفاده روی سرور اصلی، ریستور را در سرور آزمایشی بررسی کنید.'
    read -r -p 'مسیر کامل بایگانی محلی: ' file
    [[ -f $file && ! -L $file ]] || fail 'بایگانی فایل معمولی نیست.'
    confirm
    lock
    install -d -m 700 "$BASE"
    recovery=$(mktemp -d /root/eylan-recovery-XXXXXXXX)
    printf 'پوشه بازیابی: %s\n' "$recovery"
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
    }; then fail "اعتبارسنجی یا رمزگشایی شکست خورد؛ پوشه برای بررسی باقی ماند: $recovery"; fi
    gpg_decrypt "$recovery/database.dump.gpg" > "$recovery/database.dump" || fail "رمزگشایی دیتابیس شکست خورد: $recovery"
    pg_restore --list "$recovery/database.dump" >/dev/null || fail 'فرمت dump نامعتبر است.'
    stamp=$(date -u +%Y%m%d%H%M%S)_$(openssl rand -hex 4)
    staged="eylan_stage_$stamp"; saved="eylan_old_$stamp"
    printf 'دیتابیس جدید: %s؛ نام دیتابیس قدیمی: %s\n' "$staged" "$saved"
    printf '%s\n' 'اکنون دیتابیس staging ساخته و SQL نسخه اجرا می‌شود؛ سپس سرویس متوقف و دیتابیس جابه‌جا می‌شود.'
    confirm
    runuser -u postgres -- createdb --owner="$ROLE" --template=template0 "$staged"
    runuser -u postgres -- pg_restore --exit-on-error --no-owner --no-privileges --role="$ROLE" --dbname="$staged" < "$recovery/database.dump" || fail "بازیابی staging شکست خورد؛ دیتابیس $staged برای بررسی حفظ شد."
    if systemctl is-active --quiet "$SERVICE"; then active=1; fi
    cleanup_restore() {
        local rc=$?
        trap - EXIT
        if (( stopped && active )); then
            if ! systemctl start "$SERVICE"; then printf 'خطا: سرویس را دستی راه‌اندازی کنید: %s\n' "$SERVICE" >&2; rc=1; fi
        fi
        if (( rc != 0 )); then printf 'بازیابی ناموفق؛ staging/دیتابیس قبلی حذف نشده است. پوشه: %s\n' "$recovery" >&2; fi
        exit "$rc"
    }
    trap cleanup_restore EXIT
    if (( active )); then
        stopped=1
        systemctl stop "$SERVICE" || fail 'توقف سرویس شکست خورد.'
    fi
    pre=$(mktemp "$BASE/pre-restore-$stamp-XXXXXXXX.dump.gpg")
    if ! runuser -u postgres -- pg_dump --format=custom --no-owner --no-privileges "$DB" | gpg_encrypt "$pre"; then
        fail "پشتیبان پیش از بازیابی ناموفق است؛ فایل احتمالی ناقص: $pre"
    fi
    printf 'پشتیبان رمزگذاری‌شده پیش از بازیابی: %s\n' "$pre"
    # Fixed identifiers are generated internally; both renames commit atomically.
    runuser -u postgres -- psql --no-psqlrc -v ON_ERROR_STOP=1 --dbname=postgres --single-transaction \
        -c "ALTER DATABASE \"$DB\" RENAME TO \"$saved\";" \
        -c "ALTER DATABASE \"$staged\" RENAME TO \"$DB\";" || fail 'جابه‌جایی دیتابیس شکست خورد؛ تراکنش لغو شد.'
    switched=1
    printf 'دیتابیس قبلی با نام %s حفظ شد. فایل‌ها را در %s بررسی و دستی بازیابی کنید.\n' "$saved" "$recovery/files"
    printf 'فایل dump رمزگشایی‌شده در %s باقی مانده است؛ پس از اطمینان آن را امن حذف کنید.\n' "$recovery/database.dump"
    cleanup_restore
}

[[ $EUID -eq 0 ]] || fail 'این برنامه باید با root اجرا شود.'
printf '%s\n' 'هشدار: نسخه آزمایشی است؛ روی سرور اصلی نصب یا اجرا نشود.' >&2
case ${1-} in
    --backup) [[ $# == 1 ]] || fail 'آرگومان نامعتبر است.'; backup ;;
    '')
        printf '%s\n' '1) راه‌اندازی پشتیبان ساعتی' '2) بازیابی نسخه محلی' '0) خروج'
        read -r -p 'انتخاب: ' choice
        case $choice in 1) setup ;; 2) restore ;; 0) exit 0 ;; *) fail 'انتخاب نامعتبر است.' ;; esac ;;
    *) fail 'آرگومان نامعتبر است.' ;;
esac
