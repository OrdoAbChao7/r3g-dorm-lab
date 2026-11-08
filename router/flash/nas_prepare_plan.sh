#!/bin/sh
# nas_prepare_plan.sh - READ-ONLY inspection + plan generation.
# Runs ON THE ROUTER as root. It never mounts, formats, installs or changes
# configuration. Review the generated plan before executing anything.
#
# Usage:
#   scp nas_prepare_plan.sh root@192.168.1.1:/tmp/
#   ssh root@192.168.1.1 sh /tmp/nas_prepare_plan.sh
#   # then read /tmp/nas_plan.sh

set -e
PLAN=/tmp/nas_plan.sh

echo "=== block devices ==="
lsblk -f 2>/dev/null || cat /proc/partitions
echo
echo "=== blkid ==="
blkid 2>/dev/null || true
echo
echo "=== mounts ==="
mount | grep -E 'sd[a-z]|usb' || echo "(no usb mount)"
echo
echo "=== kernel messages (last 30) ==="
dmesg | tail -30
echo

# Pick the first USB-attached block device that has a filesystem.
CANDIDATE=""
for dev in /sys/block/sd*; do
    [ -e "$dev" ] || continue
    name=$(basename "$dev")
    [ "$(cat "$dev/removable" 2>/dev/null)" = "1" ] || continue
    for part in /dev/${name}[0-9]*; do
        [ -e "$part" ] || continue
        fstype=$(blkid -o value -s TYPE "$part" 2>/dev/null || true)
        uuid=$(blkid -o value -s UUID "$part" 2>/dev/null || true)
        if [ -n "$fstype" ] && [ -n "$uuid" ]; then
            CANDIDATE="$part"
            CAND_UUID="$uuid"
            CAND_FS="$fstype"
            break 2
        fi
    done
done

if [ -z "$CANDIDATE" ]; then
    echo "未找到带文件系统的 USB 分区。"
    echo "请确认硬盘已插好；不要格式化未识别的磁盘。"
    exit 0
fi

echo "识别到: $CANDIDATE  fstype=$CAND_FS  uuid=$CAND_UUID"
echo

cat > "$PLAN" <<EOF
#!/bin/sh
# Generated plan for $CANDIDATE ($CAND_FS, UUID=$CAND_UUID)
# REVIEW EVERY LINE BEFORE RUNNING. Nothing has been changed yet.
set -e

# 1) Mount (temporary verification)
mkdir -p /mnt/usb
mount UUID=$CAND_UUID /mnt/usb
touch /mnt/usb/.rw_test && rm /mnt/usb/.rw_test

# 2) Persist by UUID
uci add fstab mount
uci set fstab.@mount[-1].uuid='$CAND_UUID'
uci set fstab.@mount[-1].target='/mnt/usb'
uci set fstab.@mount[-1].fstype='$CAND_FS'
uci set fstab.@mount[-1].options='noatime'
uci commit fstab

# 3) Directories on the existing filesystem (no formatting is performed)
mkdir -p /mnt/usb/media /mnt/usb/downloads /mnt/usb/backup

# 4) SMB (verify package names with: opkg list | grep ksmbd)
opkg update
opkg install ksmbd-server luci-app-ksmbd

# 5) Aria2
opkg install aria2

echo "Plan finished. Configure shares and rpc-secret manually."
EOF

chmod +x "$PLAN"
echo "计划已生成: $PLAN"
echo "请先阅读，再决定是否执行。脚本没有修改任何配置。"
