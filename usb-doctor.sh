#!/bin/bash
#
# usb-doctor.sh — USB flash drive diagnosis and repair for macOS
#
# Usage:  ./usb-doctor.sh
#
# Interactive, four stages:
#   1. Diagnose  — read-only, cannot damage anything
#   2. Back up   — full disk image, strongly advised before any repair
#   3. Repair    — writes to the drive, requires typed confirmation
#   4. Clean up  — removes any package the script installed
#
# Nothing is ever written to the drive without an explicit typed confirmation.
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

# Requires typing an exact word. Guards against a reflexive Enter keypress
# on the one prompt that authorises writing to the drive.
ask_typed() {
    local prompt="$1" expected="$2" answer
    printf '\n%s%s%s\n' "$B" "$prompt" "$N"
    printf 'Type %s%s%s to confirm (anything else cancels): ' "$B" "$expected" "$N"
    read -r answer </dev/tty
    [ -n "$LOG" ] && printf '\n>>> confirmation %s -> %s\n' "$expected" "$answer" >> "$LOG"
    [ "$answer" = "$expected" ]
}

die() { say ""; bad "$*"; say ""; exit 1; }

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
trap cleanup EXIT INT TERM

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
    bad "macOS sees no external disk at all."
    say ""
    say "${B}What this means${N}"
    say "  The Mac is not detecting the drive even at the hardware level."
    say "  The fault is upstream of the filesystem."
    say ""
    say "${B}Check, in this order${N}"
    say "  1. Try a different USB port — try every port"
    say "  2. Try a different USB-C adapter or hub — a very common cause"
    say "  3. Plug in directly, with no hub and no extension cable"
    say "  4. Reset the Mac's NVRAM / SMC"
    say ""
    say "If the drive works on Windows but appears on no Mac, and nothing is"
    say "listed above, the adapter is the prime suspect."
    say ""
    say "USB system log, last 5 minutes:"
    log show --last 5m --predicate 'subsystem CONTAINS "usb"' --style compact 2>/dev/null \
        | tail -40 | tee -a "$LOG"
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
    SIZE=$(diskutil info "$DISK" 2>/dev/null | awk -F': *' '/Disk Size/{print $2; exit}')
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
        SIZE=$(diskutil info "$d" 2>/dev/null | awk -F': *' '/Disk Size/{print $2; exit}')
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
# Note: dd's exit status is checked directly, not through a pipe — a pipeline
# reports the status of its last command, which would mask a dd failure.
say ""
say "${B}Physical read test${N}"
PHYS_OK=1
if [ "$SUDO_OK" -eq 1 ]; then
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

if gpt -r show "$DISK" >>"$LOG" 2>&1; then
    ok "Partition table readable"
else
    warn "Partition table unreadable or absent (details in the report)"
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

NTFS_FOUND=0
BROKEN_PARTS=()

if [ ${#PARTS[@]} -eq 0 ]; then
    bad "No partitions found on $DISK"
    warn "The disk is visible, but its partition table is empty or unreadable."
else
    for p in "${PARTS[@]}"; do
        DEV="/dev/$p"
        FSTYPE=$(diskutil info "$DEV" 2>/dev/null | awk -F': *' '/Type \(Bundle\)/{print $2; exit}')
        FSNAME=$(diskutil info "$DEV" 2>/dev/null | awk -F': *' '/Volume Name/{print $2; exit}')
        MOUNTED=$(diskutil info "$DEV" 2>/dev/null | awk -F': *' '/Mounted/{print $2; exit}')
        PSIZE=$(diskutil info "$DEV" 2>/dev/null | awk -F': *' '/(Disk|Volume) Size/{print $2; exit}')

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
    bad "Partition table missing or unreadable."
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
if [ "$NEED_REPAIR" -eq 1 ] || [ "$PHYS_OK" -eq 0 ] || [ ${#PARTS[@]} -eq 0 ]; then
    title "5. Backup (strongly recommended)"

    say "Before any repair, copy the whole drive into an image file. If the"
    say "repair goes wrong, everything stays recoverable from that image."
    say ""
    DISKSIZE=$(diskutil info "$DISK" 2>/dev/null | awk -F': *' '/Disk Size/{print $2; exit}')
    say "Size to copy: ${B}${DISKSIZE:-unknown}${N}"
    say "Destination:  ${C}$LOGDIR/drive-image.dmg${N}"
    say ""
    say "${DIM}Free space on this Mac must exceed that size:${N}"
    df -h "$HOME" | tail -1 | sed 's/^/  /' | tee -a "$LOG"

    if [ "$SUDO_OK" -eq 0 ]; then
        warn "Backup needs administrator rights — skipped."
    elif ask "Create the backup image now?"; then
        say ""
        info "Unmounting the drive..."
        diskutil unmountDisk "$DISK" >/dev/null 2>&1

        say ""
        say "${B}Copying.${N} This can take a while — minutes to hours depending"
        say "on size and on how damaged the drive is."
        say "${DIM}Ctrl+C to abort.${N}"
        say ""

        # /dev/rdiskN is the raw character device: much faster than /dev/diskN.
        # conv=noerror,sync keeps going past bad sectors, padding them with
        # zeroes so that everything after them stays correctly aligned.
        RAW="${DISK/\/dev\//\/dev\/r}"
        if sudo dd if="$RAW" of="$LOGDIR/drive-image.dmg" bs=1m conv=noerror,sync status=progress 2>>"$LOG"; then
            say ""
            ok "Image created: $LOGDIR/drive-image.dmg"
            ok "Unreadable sectors were zero-filled rather than aborting the copy."
            IMAGE_DONE=1
        else
            warn "The copy finished with errors (see the report)."
            [ -f "$LOGDIR/drive-image.dmg" ] && IMAGE_DONE=1
        fi
    else
        warn "Backup skipped. Any repair will run without a safety net."
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Stage 6 — repair
# ─────────────────────────────────────────────────────────────────────────────
if [ "$NEED_REPAIR" -eq 1 ] && [ "$SUDO_OK" -eq 1 ]; then
    title "6. Repair"

    say "Affected partition(s): ${B}${BROKEN_PARTS[*]}${N}"
    say ""
    say "${Y}Repair writes to the drive.${N} In rare cases it can discard files"
    say "that were already damaged."
    if [ "$IMAGE_DONE" -eq 0 ]; then
        say ""
        warn "No backup image was created."
    fi

    if ask_typed "Run the repair?" "REPAIR"; then
        for DEV in "${BROKEN_PARTS[@]}"; do
            FSTYPE=$(diskutil info "$DEV" 2>/dev/null | awk -F': *' '/Type \(Bundle\)/{print $2; exit}')
            say ""
            say "${B}Repairing $DEV ($FSTYPE)${N}"

            if printf '%s' "$FSTYPE" | grep -qi ntfs; then
                # The one case that needs an external tool.
                say ""
                info "NTFS: macOS provides no repair tool for this filesystem."
                info "An external utility (ntfs-3g) is required."

                if ask "Install ntfs-3g temporarily? (removed automatically on exit)"; then
                    if ! command -v brew >/dev/null 2>&1; then
                        for cand in /opt/homebrew/bin/brew /usr/local/bin/brew; do
                            [ -x "$cand" ] && eval "$("$cand" shellenv)" && break
                        done
                    fi

                    if ! command -v brew >/dev/null 2>&1; then
                        warn "Homebrew is not installed."
                        say "  To install it:"
                        say "  ${C}/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"${N}"
                        warn "NTFS repair is not possible without it."
                    else
                        info "Installing ntfs-3g-mac..."
                        if brew install ntfs-3g-mac >>"$LOG" 2>&1; then
                            INSTALLED_BY_US+=("ntfs-3g-mac")
                            ok "ntfs-3g-mac installed (temporarily)"
                            diskutil unmount "$DEV" >/dev/null 2>&1
                            NTFSFIX=$(command -v ntfsfix || echo "$(brew --prefix)/bin/ntfsfix")
                            if [ -x "$NTFSFIX" ]; then
                                sudo "$NTFSFIX" -d "$DEV" 2>&1 | tee -a "$LOG" | sed 's/^/  /'
                                ok "ntfsfix finished"
                                say ""
                                warn "ntfsfix only flags the volume for a later scan."
                                warn "For a real NTFS repair, plug the drive into a PC and run:"
                                warn "  chkdsk X: /f"
                            fi
                        else
                            warn "Could not install ntfs-3g-mac (see the report)."
                            say "  The most reliable NTFS fix remains a Windows PC:"
                            say "  an admin Command Prompt, then ${B}chkdsk X: /f${N}"
                        fi
                    fi
                else
                    info "Installation declined."
                    say "  For NTFS, the reference repair is, on a PC:"
                    say "  ${B}chkdsk X: /f${N}"
                fi
            else
                # FAT / exFAT / HFS+ / APFS — native macOS tools, nothing to install.
                diskutil unmount "$DEV" >/dev/null 2>&1
                REPAIR=$(diskutil repairVolume "$DEV" 2>&1)
                printf '%s\n' "$REPAIR" >> "$LOG"
                printf '%s' "$REPAIR" | tail -20 | sed 's/^/  /'
                if printf '%s' "$REPAIR" | grep -qiE "appears to be OK|was repaired successfully|seems to be OK"; then
                    ok "Repair succeeded"
                else
                    warn "Repair did not succeed"
                    # Second pass with the low-level checkers, which are more
                    # aggressive than diskutil's wrapper.
                    RDEV="${DEV/\/dev\//\/dev\/r}"
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
        info "Repair cancelled. Nothing was written to the drive."
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
