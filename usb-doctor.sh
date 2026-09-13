#!/bin/bash
#
# usb-doctor.sh — USB flash drive diagnosis and repair for macOS
#
# Usage:  ./usb-doctor.sh
#
# Four stages, decided automatically from what is detected:
#   1. Diagnose  — read-only, cannot damage anything
#   2. Back up   — full disk image, if a fault was found and space allows
#   3. Repair    — only if that backup image was created successfully
#   4. Clean up  — removes any package the script installed
#
# The only input required is the Mac password, plus confirming which drive to
# work on. Everything after that is automatic.
#
# The backup gates the repair on purpose: repairing writes to the drive and can
# discard already-damaged files. With no image to fall back on, the script
# stops and prints the manual command instead of risking irreplaceable data.
#
# Design note: macOS ships every tool needed for FAT32, exFAT, HFS+ and APFS
# (diskutil, fsck_msdos, fsck_exfat, fsck_hfs, gpt, dd). The only case that
# needs an external utility is NTFS, which macOS can read but cannot repair.
# ntfs-3g is therefore installed on demand only, and removed on exit.

set -uo pipefail

VERSION="1.0"
LOGDIR="$HOME/Desktop/usb-doctor-$(date +%Y%m%d-%H%M%S)"
LOG=""
INSTALLED_BY_US=()      # packages this script installed, removed during cleanup
SUDO_KEEPALIVE=""
SUDO_OK=0

# ─────────────────────────────────────────────────────────────────────────────
# Output helpers
# ─────────────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[31m'; G=$'\033[32m'
    Y=$'\033[33m'; C=$'\033[36m'; N=$'\033[0m'
else
    B=""; DIM=""; R=""; G=""; Y=""; C=""; N=""
fi

say()  { printf '%s\n' "$*"; [ -n "$LOG" ] && printf '%s\n' "$*" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG"; }
ok()   { say "  ${G}✓${N} $*"; }
warn() { say "  ${Y}!${N} $*"; }
bad()  { say "  ${R}✗${N} $*"; }
info() { say "  ${DIM}·${N} $*"; }

title() {
    say ""
    say "${B}${C}━━━ $* ━━━${N}"
    say ""
}

# Yes/no prompt. Returns 0 for yes. Accepts English and French affirmatives.
ask() {
    local prompt="$1" answer
    printf '\n%s%s%s [y/N] ' "$B" "$prompt" "$N"
    read -r answer </dev/tty
    [ -n "$LOG" ] && printf '\n>>> %s -> %s\n' "$prompt" "$answer" >> "$LOG"
    case "$answer" in [yYoO]*) return 0 ;; *) return 1 ;; esac
}

die() { say ""; bad "$*"; say ""; exit 1; }

# /dev/diskN -> /dev/rdiskN, the raw character device.
# Note: bash pattern substitution is not sed — escaping the slashes as \/
# would insert literal backslashes into the result.
rawdev() { printf '%s' "${1/#\/dev\///dev/r}"; }

# Human-readable size for a device, without diskutil's byte-count suffixes:
# "2.0 GB" rather than "2.0 GB (1992294400 Bytes) (exactly 3891200 ...)".
disk_size() {
    diskutil info "$1" 2>/dev/null \
        | awk -F': *' '/(Disk|Volume) Size/{print $2; exit}' \
        | awk -F' \\(' '{print $1}'
}

# USB devices currently on the bus, hubs and built-in peripherals filtered
# out. Sees the hardware even when no /dev/diskN exists for it, which is what
# separates an ejected drive from an absent one.
usb_devices() {
    ioreg -p IOUSB -w0 2>/dev/null \
        | grep -oE '\+-o [^@]+@' \
        | sed 's/^+-o //; s/@$//' \
        | grep -viE 'hub|root|xhci|composite|keyboard|mouse|trackpad|camera|audio|receiver|bluetooth'
}

# Waits for a drive to appear, for those cases where the user has to unplug
# and replug. Prints a countdown; returns 0 as soon as one shows up.
wait_for_disk() {
    local timeout="$1" waited=0 found=""
    # The countdown is drawn only on a real terminal; redirecting to /dev/tty
    # is itself an error when there is none.
    local tty_ok=0
    [ -t 1 ] && tty_ok=1

    while [ "$waited" -lt "$timeout" ]; do
        found=$(diskutil list external physical 2>/dev/null | grep -Eo '^/dev/disk[0-9]+' | head -1)
        if [ -n "$found" ]; then
            [ "$tty_ok" -eq 1 ] && printf '\r%-60s\r' ""
            return 0
        fi
        [ "$tty_ok" -eq 1 ] && printf '\r  Waiting for the drive... %ds ' "$(( timeout - waited ))"
        sleep 2
        waited=$(( waited + 2 ))
    done
    [ "$tty_ok" -eq 1 ] && printf '\r%-60s\r' ""
    return 1
}

# Diagnosis for a drive macOS never presents as a disk. Nothing can be
# repaired here, so the job is to narrow down where the fault is — the drive,
# the port, or whatever sits between them.
diagnose_absent() {
    say "${B}What the Mac can still tell us${N}"
    say ""

    # A hub or adapter in the chain is worth naming: they are a common cause,
    # and the fix (plug in directly) costs nothing to try.
    local hubs
    hubs=$(ioreg -p IOUSB -w0 -l 2>/dev/null \
        | grep -E '"USB Product Name"' | grep -i hub \
        | sed 's/.*= "//; s/"$//' | sort -u | head -3)

    if [ -n "$hubs" ]; then
        warn "A USB hub or adapter is in use:"
        printf '%s\n' "$hubs" | sed 's/^/      /' | tee -a "$LOG"
        say ""
        say "  ${B}Try the drive plugged straight into the Mac${N}, with no hub,"
        say "  dock or extension cable. This alone fixes many cases —"
        say "  especially where the drive works on a PC but on no Mac."
        say ""
    else
        info "No hub or adapter detected — the drive is on a direct port."
        say ""
    fi

    # Recent USB errors name the fault when there is one.
    local usberr
    usberr=$(log show --last 3m --predicate 'subsystem CONTAINS "usb"' --style compact 2>/dev/null \
        | grep -iE 'error|fail|reject|terminat|overcurrent|not enough power' \
        | tail -6)

    if [ -n "$usberr" ]; then
        warn "Recent USB errors:"
        printf '%s\n' "$usberr" | cut -c1-110 | sed 's/^/      /' | tee -a "$LOG"
        say ""
        if printf '%s' "$usberr" | grep -qi 'power\|overcurrent'; then
            say "  ${B}A power problem.${N} The drive is drawing more than the port"
            say "  provides. Use a powered hub, or a port on the Mac itself."
            say ""
        fi
    else
        info "No USB errors logged in the last 3 minutes."
        say ""
    fi

    say "${B}Where the fault is${N}"
    say ""
    say "  The Mac never presented this drive as a disk, so there is no"
    say "  filesystem to repair — the problem is below that level."
    say ""
    say "  ${B}1.${N} Try every port on the Mac, with no hub or adapter"
    say "  ${B}2.${N} Try a different cable, if the drive uses one"
    say "  ${B}3.${N} Try the drive on another Mac"
    say ""
    say "  If it works on Windows but on no Mac, and a direct port changes"
    say "  nothing, the drive's partition table is likely written in a way"
    say "  macOS refuses — a PC can read past it where macOS will not."
    say ""
    say "  ${B}Recover the files from the PC that does see it${N}, then reformat"
    say "  as exFAT (Disk Utility → Erase → exFAT, scheme GUID). That is the"
    say "  only format both systems read and write natively."
}

# Draws a progress bar for a copy in flight, by watching the output file grow.
#
# macOS ships BSD dd, whose status=progress prints nothing until the copy ends
# — it is a GNU option. So progress is measured from the file itself rather
# than parsed from dd's output.
#
# $1 pid of the running dd, $2 destination path, $3 expected total bytes
show_copy_progress() {
    local pid="$1" dest="$2" total="$3"
    local width=32 done_b=0 pct=0 filled=0 started elapsed rate eta
    started=$(date +%s)

    # Nothing to draw without a terminal; just wait for the copy.
    if [ ! -t 1 ] || [ "${total:-0}" -le 0 ]; then
        wait "$pid" 2>/dev/null
        return $?
    fi

    while kill -0 "$pid" 2>/dev/null; do
        done_b=$(stat -f%z "$dest" 2>/dev/null || echo 0)
        [ "$done_b" -gt "$total" ] && done_b="$total"
        pct=$(( done_b * 100 / total ))
        filled=$(( pct * width / 100 ))

        elapsed=$(( $(date +%s) - started ))
        rate=0
        [ "$elapsed" -gt 0 ] && rate=$(( done_b / elapsed ))

        # Remaining time, once there is enough of a rate to extrapolate from.
        eta=""
        if [ "$rate" -gt 0 ] && [ "$done_b" -lt "$total" ]; then
            local secs=$(( (total - done_b) / rate ))
            if [ "$secs" -ge 60 ]; then
                eta=$(printf '%dm%02ds left' $(( secs / 60 )) $(( secs % 60 )))
            else
                eta="${secs}s left"
            fi
        fi

        printf '\r  [%s%s] %3d%%  %d/%d MB  %s' \
            "$(printf '%*s' "$filled" '' | tr ' ' '#')" \
            "$(printf '%*s' "$(( width - filled ))" '')" \
            "$pct" \
            "$(( done_b / 1000000 ))" "$(( total / 1000000 ))" \
            "$(printf '%-14s' "${eta:-…}")"
        sleep 1
    done

    wait "$pid" 2>/dev/null
    local status=$?

    # Final state, so the line does not stop at 99%.
    done_b=$(stat -f%z "$dest" 2>/dev/null || echo 0)
    [ "$done_b" -gt "$total" ] && done_b="$total"
    pct=$(( done_b * 100 / total ))
    filled=$(( pct * width / 100 ))
    printf '\r  [%s%s] %3d%%  %d/%d MB  %-14s\n' \
        "$(printf '%*s' "$filled" '' | tr ' ' '#')" \
        "$(printf '%*s' "$(( width - filled ))" '')" \
        "$pct" "$(( done_b / 1000000 ))" "$(( total / 1000000 ))" ""
    return $status
}

# Reading a disk sector by sector fails with "Resource busy" while any of its
# volumes are mounted, so unmount first. Returns 0 if the disk was mounted, so
# the caller can remount it afterwards and leave things as it found them.
unmount_disk() {
    # "diskutil list" only prints /Volumes/ for partitioned drives; a disk
    # holding its filesystem directly shows just the volume name. Ask
    # "diskutil info" instead, which answers for both layouts.
    local mounted
    mounted=$(diskutil info "$1" 2>/dev/null | awk -F': *' '/^ *Mounted/{print $2; exit}')

    if [ "$mounted" = "Yes" ] || diskutil list "$1" 2>/dev/null | grep -q "/Volumes/"; then
        diskutil unmountDisk "$1" >/dev/null 2>&1
        sleep 1
        return 0
    fi
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup — always runs, even on Ctrl+C
# ─────────────────────────────────────────────────────────────────────────────
cleanup() {
    [ -n "$SUDO_KEEPALIVE" ] && kill "$SUDO_KEEPALIVE" 2>/dev/null

    if [ ${#INSTALLED_BY_US[@]} -gt 0 ]; then
        title "Cleanup"
        for pkg in "${INSTALLED_BY_US[@]}"; do
            info "Removing $pkg..."
            if brew uninstall --force "$pkg" >/dev/null 2>&1; then
                ok "$pkg removed"
            else
                warn "Could not remove $pkg — remove manually: brew uninstall $pkg"
            fi
        done
        INSTALLED_BY_US=()
    fi
}
trap cleanup EXIT

# Ctrl+C must actually stop the run. With cleanup alone on INT the shell
# resumes at the next statement, which once let an interrupted backup fall
# through into the repair.
on_interrupt() {
    # dd runs in the background under sudo, so Ctrl+C does not reach it: the
    # copy would keep running after the script exits. Stop it explicitly.
    if [ -n "${DD_PID:-}" ] && kill -0 "$DD_PID" 2>/dev/null; then
        sudo kill "$DD_PID" 2>/dev/null
        wait "$DD_PID" 2>/dev/null
    fi
    say ""
    say ""
    warn "Interrupted. Stopping."
    exit 130
}
trap on_interrupt INT TERM

# ─────────────────────────────────────────────────────────────────────────────
# Setup
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p "$LOGDIR" || { echo "Cannot create $LOGDIR"; exit 1; }
LOG="$LOGDIR/report.txt"
: > "$LOG"

[ -t 1 ] && clear
say "${B}╭────────────────────────────────────────────╮${N}"
say "${B}│   USB Doctor v$VERSION — flash drive triage   │${N}"
say "${B}╰────────────────────────────────────────────╯${N}"
say ""
say "Report saved to:"
say "  ${C}$LOG${N}"
say ""
say "${DIM}macOS $(sw_vers -productVersion) ($(uname -m))${N}"

# Raw disk reads and fsck both require root. Ask once, up front, with a
# reason — rather than letting password prompts ambush the user mid-scan.
# Without root, `dd if=/dev/diskN` fails with "Operation not permitted",
# which would otherwise be misreported as failing hardware.
say ""
say "${B}Administrator password${N}"
say "  macOS requires admin rights to read a disk sector by sector and to"
say "  run the repair tools. Without them this script would wrongly report"
say "  a healthy drive as failing."
say ""
if sudo -v 2>/dev/null; then
    ok "Administrator rights granted"
    SUDO_OK=1
    # Keep the sudo timestamp alive for the duration of the run.
    ( while true; do sudo -n true 2>/dev/null; sleep 50; done ) &
    SUDO_KEEPALIVE=$!
else
    warn "No administrator rights — diagnosis will be limited"
    warn "Physical read tests and repair will be skipped."
    SUDO_OK=0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Stage 1 — find the drive
# ─────────────────────────────────────────────────────────────────────────────
title "1. Detecting disks"

say "${B}External disks found:${N}"
say ""
diskutil list external physical 2>&1 | tee -a "$LOG"

EXTERNALS=$(diskutil list external physical 2>/dev/null | grep -Eo '^/dev/disk[0-9]+' | sort -u)

if [ -z "$EXTERNALS" ]; then
    say ""
    bad "macOS lists no external disk."

    # "Ejected" and "unmounted" are different states, and only one of them is a
    # fault. Unmounting leaves /dev/diskN in place — that is what a damaged
    # drive looks like. Ejecting detaches the device entirely, so nothing is
    # left to diagnose even though the hardware is fine and still plugged in.
    # ioreg sees the hardware either way, which tells the two apart.
    USBHW=$(usb_devices | head -5)

    if [ -n "$USBHW" ]; then
        say ""
        say "${B}But the hardware IS connected${N}"
        printf '%s\n' "$USBHW" | sed 's/^/  · /' | tee -a "$LOG"
        say ""
        say "The drive is plugged in and the Mac sees it on the USB bus — it has"
        say "probably been ${B}ejected${N}, which detaches the device completely."
        say ""
        say "${DIM}Ejecting (⏏ in Finder) is not the same as unmounting: a drive${N}"
        say "${DIM}that is merely unmounted still appears here, and that is the${N}"
        say "${DIM}state a damaged drive is normally in.${N}"
        say ""
        say "${B}Unplug the drive and plug it back in now.${N}"
        say ""

        # Wait rather than making the user run the whole thing again.
        if wait_for_disk 60; then
            ok "Drive detected — continuing"
            EXTERNALS=$(diskutil list external physical 2>/dev/null | grep -Eo '^/dev/disk[0-9]+' | sort -u)
        else
            warn "Nothing appeared after 60 seconds."
            say ""
            say "If you did replug it and it still does not show up, the drive"
            say "is not being recognised. See the checks below."
            say ""
            diagnose_absent
            exit 0
        fi
    else
        say ""
        say "The Mac sees no storage device on the USB bus either."
        say ""
        say "${B}Plug the drive in now${N} (or unplug and replug it)."
        say ""

        if wait_for_disk 60; then
            ok "Drive detected — continuing"
            EXTERNALS=$(diskutil list external physical 2>/dev/null | grep -Eo '^/dev/disk[0-9]+' | sort -u)
        else
            say ""
            diagnose_absent
            exit 0
        fi
    fi
fi

# Both branches above may have found a drive while waiting.
if [ -z "$EXTERNALS" ]; then
    diagnose_absent
    exit 0
fi

say ""
ok "External disk(s) found: $(echo "$EXTERNALS" | tr '\n' ' ')"

# Pick the target disk.
DISK=""
COUNT=$(echo "$EXTERNALS" | wc -l | tr -d ' ')
if [ "$COUNT" -eq 1 ]; then
    DISK="$EXTERNALS"
    NAME=$(diskutil info "$DISK" 2>/dev/null | awk -F': *' '/Device \/ Media Name/{print $2; exit}')
    SIZE=$(disk_size "$DISK")
    say ""
    say "Only one external disk: ${B}$DISK${N} — $NAME ($SIZE)"
    ask "Is this the USB drive to diagnose?" || die "Cancelled. Unplug other external disks and run again."
else
    say ""
    say "${B}Several external disks.${N} Choose the USB drive:"
    say ""
    i=1
    OPTIONS=()
    while IFS= read -r d; do
        NAME=$(diskutil info "$d" 2>/dev/null | awk -F': *' '/Device \/ Media Name/{print $2; exit}')
        SIZE=$(disk_size "$d")
        say "  ${B}$i${N}) $d — $NAME ($SIZE)"
        OPTIONS+=("$d")
        i=$((i+1))
    done <<< "$EXTERNALS"
    printf '\nNumber: '
    read -r choice </dev/tty
    idx=$((choice-1))
    [ "$idx" -ge 0 ] 2>/dev/null && [ -n "${OPTIONS[$idx]:-}" ] || die "Invalid choice."
    DISK="${OPTIONS[$idx]}"
fi

DISKNAME=$(basename "$DISK")
say ""
ok "Target disk: ${B}$DISK${N}"

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2 — diagnosis (read-only)
# ─────────────────────────────────────────────────────────────────────────────
title "2. Diagnosis (read-only, safe)"

say "${B}Disk information${N}"
diskutil info "$DISK" 2>&1 | tee -a "$LOG" | grep -E \
    'Device Node|Media Name|Disk Size|Protocol|Removable|Read-Only|Ejectable|SMART|Whole|Content' \
    | sed 's/^/  /'

# Does the drive respond physically? Read the first sector.
#
# The drive must be unmounted first: macOS refuses raw reads of a mounted disk
# with "Resource busy", which would otherwise look exactly like failing
# hardware. It is remounted immediately afterwards.
#
# Note: dd's exit status is checked directly, not through a pipe — a pipeline
# reports the status of its last command, which would mask a dd failure.
say ""
say "${B}Physical read test${N}"
PHYS_OK=1
REMOUNT=0
if [ "$SUDO_OK" -eq 1 ]; then
    if unmount_disk "$DISK"; then
        REMOUNT=1
        info "Temporarily unmounted for the read test"
    fi

    if sudo dd if="$DISK" of=/dev/null bs=512 count=1 2>>"$LOG"; then
        ok "First sector reads correctly"
    else
        bad "Cannot read the first sector"
        warn "The drive's controller is not responding properly."
        PHYS_OK=0
    fi

    # Wider sample, to catch unreadable sectors beyond the very start.
    if [ "$PHYS_OK" -eq 1 ]; then
        if sudo dd if="$DISK" of=/dev/null bs=1m count=32 2>>"$LOG"; then
            ok "First 32 MB read correctly"
        else
            warn "Read errors within the first 32 MB — media may be failing"
        fi
    fi
else
    info "Skipped (needs administrator rights)"
fi

# Partition table
say ""
say "${B}Partition table${N}"
PARTSCHEME=$(diskutil info "$DISK" 2>/dev/null | awk -F': *' '/Content \(IOContent\)/{print $2; exit}')
info "Scheme: ${PARTSCHEME:-unknown}"

# gpt needs root, like the raw reads above.
if [ "$SUDO_OK" -eq 1 ]; then
    if sudo gpt -r show "$DISK" >>"$LOG" 2>&1; then
        ok "Partition table readable"
    else
        info "No GPT table (normal for a FAT/MBR drive — see the report)"
    fi
fi

# Boot sector signature — distinguishes MBR / GPT from a wiped table.
if [ "$SUDO_OK" -eq 1 ]; then
    SIG=$(sudo dd if="$DISK" bs=512 count=1 2>/dev/null | xxd -s 510 -l 2 -p 2>/dev/null)
    if [ "$SIG" = "55aa" ]; then
        ok "Boot sector signature valid (55AA)"
    elif [ -n "$SIG" ]; then
        warn "Unexpected boot sector signature: 0x$SIG (expected 55AA)"
        warn "The partition table is probably corrupt."
    fi
fi

# Put the drive back the way it was found, so the checks below see the real
# mount state rather than one this script created.
if [ "$REMOUNT" -eq 1 ]; then
    diskutil mountDisk "$DISK" >/dev/null 2>&1
    sleep 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Stage 3 — partitions and filesystems
# ─────────────────────────────────────────────────────────────────────────────
title "3. Partition analysis"

# Collected as arrays rather than space-joined strings, so that nothing here
# depends on word-splitting behaviour.
PARTS=()
while IFS= read -r line; do
    [ -n "$line" ] && PARTS+=("$line")
done < <(diskutil list "$DISK" 2>/dev/null | grep -Eo "${DISKNAME}s[0-9]+" | sort -u)

# A drive formatted without a partition table — common on small FAT16/FAT32
# sticks, shown by macOS as "Scheme: None" — carries its filesystem on the
# whole device. There is no diskNs1 to find, so analyse the device itself.
WHOLE_DISK_FS=0
if [ ${#PARTS[@]} -eq 0 ]; then
    WHOLE_FSTYPE=$(diskutil info "$DISK" 2>/dev/null | awk -F': *' '/Type \(Bundle\)/{print $2; exit}')
    if [ -n "$WHOLE_FSTYPE" ]; then
        PARTS=("$DISKNAME")
        WHOLE_DISK_FS=1
    fi
fi

NTFS_FOUND=0
BROKEN_PARTS=()

if [ ${#PARTS[@]} -eq 0 ]; then
    bad "No partitions found on $DISK"
    warn "The disk is visible, but its partition table is empty or unreadable."
else
    [ "$WHOLE_DISK_FS" -eq 1 ] && \
        info "No partition table — the filesystem is on the whole device (normal for a small FAT drive)"
    for p in "${PARTS[@]}"; do
        DEV="/dev/$p"
        FSTYPE=$(diskutil info "$DEV" 2>/dev/null | awk -F': *' '/Type \(Bundle\)/{print $2; exit}')
        FSNAME=$(diskutil info "$DEV" 2>/dev/null | awk -F': *' '/Volume Name/{print $2; exit}')
        MOUNTED=$(diskutil info "$DEV" 2>/dev/null | awk -F': *' '/Mounted/{print $2; exit}')
        PSIZE=$(disk_size "$DEV")

        say ""
        say "${B}$DEV${N} — ${FSNAME:-unnamed} (${FSTYPE:-unknown type}, ${PSIZE:-?})"

        if [ "$MOUNTED" = "Yes" ]; then
            ok "Mounted and accessible"
        else
            bad "Not mounted — this is the reported symptom"

            # Try mounting to capture the exact error message.
            MOUNTOUT=$(diskutil mount "$DEV" 2>&1)
            printf '%s\n' "$MOUNTOUT" >> "$LOG"
            if printf '%s' "$MOUNTOUT" | grep -q "successful"; then
                ok "Forced mount succeeded — the volume is reachable after all"
                diskutil unmount "$DEV" >/dev/null 2>&1
            else
                info "Mount error: $(printf '%s' "$MOUNTOUT" | tail -1)"
            fi
        fi

        # Filesystem check, read-only.
        case "$FSTYPE" in
            msdos|fat32|exfat|ntfs|hfs|apfs|"")
                say "  ${DIM}Verifying filesystem...${N}"
                VERIFY=$(diskutil verifyVolume "$DEV" 2>&1)
                printf '%s\n' "$VERIFY" >> "$LOG"
                if printf '%s' "$VERIFY" | grep -qiE "appears to be OK|seems to be OK"; then
                    ok "Filesystem is healthy"
                else
                    bad "Filesystem is corrupt"
                    printf '%s' "$VERIFY" | grep -iE "error|corrupt|invalid|bad|incorrect" \
                        | head -5 | sed 's/^/      /' | tee -a "$LOG"
                    BROKEN_PARTS+=("$DEV")
                fi
                ;;
        esac

        if printf '%s' "$FSTYPE" | grep -qi ntfs; then
            NTFS_FOUND=1
            warn "NTFS volume — macOS mounts these read-only and cannot repair them natively"
        fi
    done
fi

# ─────────────────────────────────────────────────────────────────────────────
# Stage 4 — verdict
# ─────────────────────────────────────────────────────────────────────────────
title "4. Verdict"

NEED_REPAIR=0
if [ ${#BROKEN_PARTS[@]} -gt 0 ]; then
    bad "Partition(s) needing repair: ${BROKEN_PARTS[*]}"
    say ""
    say "${B}Interpretation${N}"
    say "  The Mac can see the drive, but its filesystem is damaged."
    say "  Windows is far more tolerant than macOS and often repairs these"
    say "  faults silently at mount time — which is exactly why the drive"
    say "  still works on a PC but not on any Mac."
    NEED_REPAIR=1
elif [ "$PHYS_OK" -eq 0 ]; then
    bad "The media is not responding correctly at the hardware level."
    say ""
    say "  Software repair will not fix this. The priority is copying"
    say "  whatever is still readable before it degrades further."
elif [ ${#PARTS[@]} -eq 0 ]; then
    bad "Partition table missing or unreadable, and no filesystem on the device."
    say ""
    say "  The data is most likely still there, but macOS no longer knows"
    say "  where it starts. Do not reformat."
else
    ok "No corruption found on the partitions analysed."
    say ""
    say "  If the drive is still inaccessible despite this result, the fault"
    say "  is more likely the port, the cable, or the USB-C adapter."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Stage 5 — back up before writing anything
# ─────────────────────────────────────────────────────────────────────────────
IMAGE_DONE=0
BACKUP_SKIP_REASON=""
if [ "$NEED_REPAIR" -eq 1 ] || [ "$PHYS_OK" -eq 0 ] || [ ${#PARTS[@]} -eq 0 ]; then
    title "5. Backup"

    say "A problem was found, so the whole drive is copied into an image file"
    say "first. If the repair goes wrong, everything stays recoverable."
    say ""

    # Compare in bytes rather than the human-readable strings, so the decision
    # is exact. Both values are parsed from their respective tools' output.
    DISKSIZE=$(disk_size "$DISK")
    DISKBYTES=$(diskutil info "$DISK" 2>/dev/null | awk -F'[()]' '/Disk Size/{print $2}' | awk '{print $1}')
    FREEBYTES=$(( $(df -k "$HOME" | tail -1 | awk '{print $4}') * 1024 ))

    say "Size to copy: ${B}${DISKSIZE:-unknown}${N}"
    say "Free space:   ${B}$(( FREEBYTES / 1000000000 )) GB${N}"
    say "Destination:  ${C}$LOGDIR/drive-image.dmg${N}"

    # A margin over the exact size, so the copy cannot fill the startup disk.
    NEEDED=$(( ${DISKBYTES:-0} + 1000000000 ))

    if [ "$SUDO_OK" -eq 0 ]; then
        BACKUP_SKIP_REASON="administrator rights were not granted"
        warn "Backup skipped — $BACKUP_SKIP_REASON"
    elif [ -z "$DISKBYTES" ] || [ "$DISKBYTES" -eq 0 ]; then
        BACKUP_SKIP_REASON="the drive size could not be determined"
        warn "Backup skipped — $BACKUP_SKIP_REASON"
    elif [ "$FREEBYTES" -lt "$NEEDED" ]; then
        BACKUP_SKIP_REASON="this Mac does not have enough free space"
        warn "Backup skipped — $BACKUP_SKIP_REASON"
        say ""
        say "  Free up about $(( (NEEDED - FREEBYTES) / 1000000000 + 1 )) GB and run this again,"
        say "  or copy the drive to an external disk from a Windows PC first."
    else
        ok "Enough free space — creating the image automatically"
        say ""
        info "Unmounting the drive..."
        unmount_disk "$DISK"

        say ""
        say "${B}Copying${N} $(( DISKBYTES / 1000000 )) MB. A damaged drive copies slowly —"
        say "reading past bad sectors takes time."
        say "${DIM}Ctrl+C to abort.${N}"
        say ""

        # /dev/rdiskN is the raw character device: much faster than /dev/diskN.
        # conv=noerror,sync keeps going past bad sectors, padding them with
        # zeroes so that everything after them stays correctly aligned.
        RAW=$(rawdev "$DISK")
        sudo dd if="$RAW" of="$LOGDIR/drive-image.dmg" bs=1m conv=noerror,sync 2>>"$LOG" &
        DD_PID=$!
        show_copy_progress "$DD_PID" "$LOGDIR/drive-image.dmg" "$DISKBYTES"
        DD_STATUS=$?

        # The image must be verified by size, not by mere existence: an
        # interrupted copy (Ctrl+C) still leaves a file behind, and treating
        # that as a valid backup would unlock the repair with no real safety
        # net. dd is allowed to fall short by one block from rounding.
        IMGBYTES=0
        [ -f "$LOGDIR/drive-image.dmg" ] && \
            IMGBYTES=$(stat -f%z "$LOGDIR/drive-image.dmg" 2>/dev/null || echo 0)

        say ""
        if [ "$IMGBYTES" -ge $(( DISKBYTES - 1048576 )) ]; then
            ok "Image created: $LOGDIR/drive-image.dmg"
            ok "Unreadable sectors were zero-filled rather than aborting the copy."
            IMAGE_DONE=1
        elif [ "$DD_STATUS" -ge 128 ]; then
            # 128+n means killed by signal n — Ctrl+C is 130.
            BACKUP_SKIP_REASON="the backup was interrupted"
            bad "Backup interrupted at $(( IMGBYTES / 1000000 )) MB of $(( DISKBYTES / 1000000 )) MB"
            rm -f "$LOGDIR/drive-image.dmg"
            info "Incomplete image deleted."
        else
            BACKUP_SKIP_REASON="the backup copy was incomplete"
            bad "Backup incomplete: $(( IMGBYTES / 1000000 )) MB of $(( DISKBYTES / 1000000 )) MB"
            warn "Keeping the partial image, but it is NOT a usable backup."
        fi
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Stage 6 — repair
# ─────────────────────────────────────────────────────────────────────────────
if [ "$NEED_REPAIR" -eq 1 ] && [ "$SUDO_OK" -eq 1 ]; then
    title "6. Repair"

    say "Affected partition(s): ${B}${BROKEN_PARTS[*]}${N}"
    say ""

    # Repair writes to the drive and can discard already-damaged files, so it
    # only runs automatically when the backup image exists. Without that safety
    # net the script stops and hands the decision back to the user, rather than
    # risking data that may have no other copy.
    if [ "$IMAGE_DONE" -eq 1 ]; then
        ok "Backup image exists — repairing automatically"
        DO_REPAIR=1
    else
        bad "No backup image (${BACKUP_SKIP_REASON:-reason unknown})"
        say ""
        say "${Y}Repair is NOT running automatically.${N}"
        say "It writes to the drive and can discard files that are already"
        say "damaged — too risky without a backup."
        say ""
        say "To repair anyway, run this in Terminal:"
        say "  ${C}sudo diskutil repairVolume ${BROKEN_PARTS[0]}${N}"
        DO_REPAIR=0
    fi

    if [ "$DO_REPAIR" -eq 1 ]; then
        for DEV in "${BROKEN_PARTS[@]}"; do
            FSTYPE=$(diskutil info "$DEV" 2>/dev/null | awk -F': *' '/Type \(Bundle\)/{print $2; exit}')
            say ""
            say "${B}Repairing $DEV ($FSTYPE)${N}"

            if printf '%s' "$FSTYPE" | grep -qi ntfs; then
                # The one case that needs an external tool.
                say ""
                info "NTFS: macOS provides no repair tool for this filesystem."
                info "An external utility (ntfs-3g) is required."

                # Homebrew is used only if it is already present. Installing it
                # automatically would be a heavy, lasting change to the system —
                # out of proportion here, especially since ntfsfix does not
                # truly repair NTFS anyway.
                if ! command -v brew >/dev/null 2>&1; then
                    for cand in /opt/homebrew/bin/brew /usr/local/bin/brew; do
                        [ -x "$cand" ] && eval "$("$cand" shellenv)" && break
                    done
                fi

                if command -v brew >/dev/null 2>&1; then
                    ok "Homebrew found — installing ntfs-3g temporarily"
                    if brew install ntfs-3g-mac >>"$LOG" 2>&1; then
                        INSTALLED_BY_US+=("ntfs-3g-mac")
                        ok "ntfs-3g-mac installed (removed on exit)"
                        diskutil unmount "$DEV" >/dev/null 2>&1
                        NTFSFIX=$(command -v ntfsfix || echo "$(brew --prefix)/bin/ntfsfix")
                        if [ -x "$NTFSFIX" ]; then
                            sudo "$NTFSFIX" -d "$DEV" 2>&1 | tee -a "$LOG" | sed 's/^/  /'
                            ok "ntfsfix finished"
                        else
                            warn "ntfsfix not found after install."
                        fi
                    else
                        warn "Could not install ntfs-3g-mac (see the report)."
                    fi
                else
                    info "Homebrew is not installed — skipping ntfs-3g."
                    info "It is not installed automatically: that would be a large,"
                    info "lasting change to the Mac for little benefit here."
                fi

                say ""
                warn "NTFS note: ntfsfix only flags the volume for a later scan;"
                warn "it does not truly repair it. The reliable fix is a Windows PC:"
                warn "  chkdsk X: /f"
            else
                # FAT / exFAT / HFS+ / APFS — native macOS tools, nothing to install.
                diskutil unmount "$DEV" >/dev/null 2>&1
                REPAIR=$(diskutil repairVolume "$DEV" 2>&1)
                REPAIR_STATUS=$?
                printf '%s\n' "$REPAIR" >> "$LOG"
                printf '%s' "$REPAIR" | tail -20 | sed 's/^/  /'

                # Judge by exit status, not by matching prose: diskutil reports
                # a successful repair as "File system check exit code is 0" and
                # "Finished file system repair", neither of which matches the
                # "appears to be OK" wording that verifyVolume uses.
                say ""
                if [ "$REPAIR_STATUS" -eq 0 ] || \
                   printf '%s' "$REPAIR" | grep -qiE "exit code is 0|appears to be OK|was repaired successfully|seems to be OK"; then
                    ok "Repair succeeded"
                else
                    warn "Repair did not succeed"
                    # Second pass with the low-level checkers, which are more
                    # aggressive than diskutil's wrapper.
                    RDEV=$(rawdev "$DEV")
                    case "$FSTYPE" in
                        msdos|fat32) info "Second attempt (fsck_msdos)..."; sudo fsck_msdos -y "$RDEV" 2>&1 | tail -15 | tee -a "$LOG" | sed 's/^/  /' ;;
                        exfat)       info "Second attempt (fsck_exfat)..."; sudo fsck_exfat -y "$RDEV" 2>&1 | tail -15 | tee -a "$LOG" | sed 's/^/  /' ;;
                        hfs)         info "Second attempt (fsck_hfs)...";   sudo fsck_hfs -fy "$RDEV"  2>&1 | tail -15 | tee -a "$LOG" | sed 's/^/  /' ;;
                    esac
                fi
            fi
        done

        # Final check.
        title "7. Post-repair check"
        diskutil mountDisk "$DISK" >/dev/null 2>&1
        sleep 2
        for DEV in "${BROKEN_PARTS[@]}"; do
            MOUNTED=$(diskutil info "$DEV" 2>/dev/null | awk -F': *' '/Mounted/{print $2; exit}')
            MPOINT=$(diskutil info "$DEV" 2>/dev/null | awk -F': *' '/Mount Point/{print $2; exit}')
            if [ "$MOUNTED" = "Yes" ]; then
                ok "$DEV now mounts at $MPOINT"
                say ""
                say "  ${B}Copy its contents somewhere else right away.${N}"
                say "  A drive that has corrupted once usually does it again."
            else
                bad "$DEV still will not mount"
            fi
        done
    else
        info "Nothing was written to the drive."
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────
title "Finished"

say "Full report:"
say "  ${C}$LOG${N}"
if [ "$IMAGE_DONE" -eq 1 ]; then
    say "Backup image:"
    say "  ${C}$LOGDIR/drive-image.dmg${N}"
fi
say ""

if [ ${#BROKEN_PARTS[@]} -gt 0 ] || [ "$PHYS_OK" -eq 0 ] || [ ${#PARTS[@]} -eq 0 ]; then
    say "${B}If the drive is still inaccessible${N}"
    say ""
    say "  ${B}1.${N} Recover the data first, before anything else"
    say "     On a Windows PC: ${C}chkdsk X: /f${N} fixes the majority of cases"
    say "     On macOS: DiskDrill, or TestDisk (free), can read an unmounted drive"
    say ""
    say "  ${B}2.${N} Once the data is safe, reformat"
    say "     Disk Utility → Erase → ${B}exFAT${N}, scheme ${B}GUID${N}"
    say "     exFAT reads and writes natively on both macOS and Windows"
    say ""
    say "  ${B}3.${N} If the problem comes back, the drive is worn out. Replace it."
    say ""
fi

cleanup
trap - EXIT
say "${G}${B}Diagnosis complete.${N}"
say ""
