#!/bin/sh
# backup_readonly.sh - dump every MTD partition on the router to /tmp.
# Runs ON THE ROUTER as root. It only reads flash; nothing is written back.
#
# Usage (from Windows):
#   scp backup_readonly.sh root@192.168.31.1:/tmp/
#   ssh root@192.168.31.1 sh /tmp/backup_readonly.sh
#   scp root@192.168.31.1:/tmp/mtd_backup_*.tgz .
#
# Partition names are taken from /proc/mtd, never from fixed /dev/mtdN numbers.

set -e

STAMP=$(date +%Y%m%d_%H%M%S)
WORK="/tmp/mtd_backup_${STAMP}"
OUT="/tmp/mtd_backup_${STAMP}.tgz"

echo "=== /proc/mtd ==="
cat /proc/mtd
echo

mkdir -p "$WORK"

echo "=== dumping partitions ==="
tail -n +2 /proc/mtd | while IFS= read -r line; do
    DEV=$(echo "$line" | cut -d: -f1)
    LABEL=$(echo "$line" | sed -n 's/.*"\(.*\)".*/\1/p')
    [ -n "$LABEL" ] || LABEL="unknown"
    TARGET="${WORK}/${DEV}_${LABEL}.bin"
    echo "  ${DEV} -> ${LABEL}"
    dd if="/dev/${DEV}" of="${TARGET}" bs=4096 2>/dev/null || echo "    WARN: read failed for ${DEV}"
done

echo
echo "=== environment / identity ==="
{
    echo "# uname"; uname -a
    echo "# cmdline"; cat /proc/cmdline 2>/dev/null
    echo "# mtd"; cat /proc/mtd
    echo "# links"; ip -o link 2>/dev/null || ifconfig -a
    echo "# mounts"; mount 2>/dev/null
    echo "# df"; df -h 2>/dev/null
    echo "# uboot env"; fw_printenv 2>/dev/null || echo "(fw_printenv unavailable)"
    echo "# ubi"; ubinfo -a 2>/dev/null || echo "(ubinfo unavailable)"
} > "${WORK}/system_info.txt" 2>&1

echo
echo "=== checksums ==="
cd "$WORK"
sha256sum ./*.bin > SHA256SUMS.txt 2>/dev/null || true
cat SHA256SUMS.txt

cd /tmp
tar czf "$OUT" "$(basename "$WORK")"
SIZE=$(wc -c < "$OUT")
echo
echo "archive: $OUT"
echo "size   : $SIZE bytes"
sha256sum "$OUT" 2>/dev/null || echo "(sha256sum unavailable)"

echo
echo "Copy it back with:"
echo "  scp root@<router>:$OUT ."
echo
echo "Reminder: EEPROM/factory is usually the 'factory' partition; losing it"
echo "degrades or kills Wi-Fi calibration. Keep at least two copies."
