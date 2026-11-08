#!/bin/sh
# Offline test for update_blocklist.sh. Runs entirely in a temp dir.
# No router, no live DNS, no /www access.
set -u

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d) || exit 1
pass=0
failn=0
ok() { echo "PASS $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; failn=$((failn + 1)); }

mk_adblock() { # $1 count, $2 file
  n=$1
  : > "$2"
  i=0
  while [ "$i" -lt "$n" ]; do
    printf '||ad%s.example^\n' "$i" >> "$2"
    i=$((i + 1))
  done
}

mk_adblock 10 "$work/ad10.txt"
mk_adblock 12 "$work/ad12.txt"
mk_adblock 2 "$work/ad2.txt"
printf '<!DOCTYPE html><html>upstream error</html>\n' > "$work/html.txt"

cat > "$work/fetch.sh" <<'EOS'
#!/bin/sh
cp "$FIXTURE" "$1"
EOS
chmod +x "$work/fetch.sh"

run_update() { # $1 live, $2 fixture, $3 min_domains
  BL_LIVE="$1" BL_BAK="$1.bak" BL_LOG="$work/log.txt" \
  BL_FETCH="$work/fetch.sh" FIXTURE="$2" BL_MIN_DOMAINS="$3" \
  BL_MIN_BYTES=1 BL_MAX_BYTES=99999999 \
  sh "$here/update_blocklist.sh" update
}

count_lines() { grep -cE '^\|\|[^/^]+\^' "$1" 2>/dev/null || true; }

# 1. First install, no live file.
live="$work/live1.txt"
run_update "$live" "$work/ad10.txt" 5 >/dev/null 2>&1
[ -f "$live" ] && [ "$(count_lines "$live")" = "10" ] && ok "first install writes 10 domains" || bad "first install"

# 2. Update with a previous snapshot: .bak must hold the old file.
live="$work/live2.txt"
cp "$work/ad10.txt" "$live"
run_update "$live" "$work/ad12.txt" 5 >/dev/null 2>&1
[ -f "$live" ] && [ "$(count_lines "$live")" = "12" ] && [ -f "$live.bak" ] && [ "$(count_lines "$live.bak")" = "10" ] \
  && ok "update replaces live and keeps previous as .bak" || bad "update with previous"

# 3. Fetch failure leaves the live file untouched.
live="$work/live3.txt"
cp "$work/ad10.txt" "$live"
BL_LIVE="$live" BL_BAK="$live.bak" BL_LOG="$work/log.txt" BL_FETCH=/bin/false BL_MIN_DOMAINS=5 \
  BL_MIN_BYTES=1 BL_MAX_BYTES=99999999 sh "$here/update_blocklist.sh" update >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ "$(count_lines "$live")" = "10" ] && [ ! -f "$live.new" ] \
  && ok "fetch failure rejected, live untouched" || bad "fetch failure"

# 4. HTML error page rejected.
live="$work/live4.txt"
cp "$work/ad10.txt" "$live"
run_update "$live" "$work/html.txt" 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ "$(count_lines "$live")" = "10" ] \
  && ok "HTML page rejected, live untouched" || bad "HTML rejection"

# 5. >50% domain drop rejected.
live="$work/live5.txt"
cp "$work/ad10.txt" "$live"
run_update "$live" "$work/ad2.txt" 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ "$(count_lines "$live")" = "10" ] \
  && ok "domain-count drop rejected, live untouched" || bad "domain drop"

# 6. Rollback restores the previous snapshot.
live="$work/live6.txt"
cp "$work/ad10.txt" "$live"
cp "$work/ad10.txt" "$live.bak"
BL_LIVE="$live" BL_BAK="$live.bak" BL_LOG="$work/log.txt" sh "$here/update_blocklist.sh" -rollback >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ "$(count_lines "$live")" = "10" ] && ok "rollback restores .bak" || bad "rollback"

echo "TOTAL $((pass + failn)) PASS $pass FAIL $failn"
[ "$failn" -eq 0 ] && exit 0 || exit 1
