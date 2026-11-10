#!/bin/sh
# portal_set_credentials.sh - prompt on the console and write the portal
# credentials to /etc/portal/login.conf (root-only, mode 600).
#
# The password is typed by the operator; it is never echoed, never passed on a
# command line and never written anywhere except the 600 file.

set -u

CONF="${PORTAL_CONF:-/etc/portal/login.conf}"

mkdir -p /etc/portal || exit 1
chmod 700 /etc/portal

printf 'Portal username: '
read -r user
printf 'Portal password (input hidden): '
stty -echo 2>/dev/null
read -r pass
stty echo 2>/dev/null
printf '\n'

if [ -z "$user" ] || [ -z "$pass" ]; then
    echo "aborted: empty username or password"
    exit 1
fi

escape() {
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

umask 077
{
    printf "USERNAME='%s'\n" "$(escape "$user")"
    printf "PASSWORD='%s'\n" "$(escape "$pass")"
} >"$CONF"
chmod 600 "$CONF"

echo "saved $CONF (mode 600, owner root)"
echo "verify with: /usr/bin/portal_autologin.sh status"
