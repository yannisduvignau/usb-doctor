# USB Doctor

Diagnoses and repairs a USB flash drive that a Mac refuses to open.

Written for the case where a drive still works on Windows but no longer
mounts on any Mac — which usually means a damaged filesystem rather than a
dead drive.

## How to run it

Nothing to install and nothing to clone.

1. Plug in the USB drive.
2. Open **Terminal** (press `Cmd + Space`, type `Terminal`, press Enter).
3. Copy and paste this line, then press Enter:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/yannisduvignau/usb-doctor/main/usb-doctor.sh -o /tmp/usb-doctor.sh && bash /tmp/usb-doctor.sh; rm -f /tmp/usb-doctor.sh
   ```

4. Answer the questions as they come up.

The script downloads, runs, and deletes itself — including if you press
Ctrl+C partway through.

It will ask for your Mac password at the start. That is expected: macOS
requires administrator rights to read a disk sector by sector. Without
them the script cannot tell a healthy drive from a failing one, so it
warns and skips those tests rather than guessing.

### Why not `curl … | bash`

The usual one-liner pipes the script straight into `bash`. That does not
work here: this script is interactive, and piping it makes `bash` read the
script itself from standard input, leaving nothing for the keyboard. The
prompts would scroll past unanswered.

Writing to a temporary file first keeps standard input free for your
answers. The `;` before `rm` is deliberate rather than a typo — with `&&`,
an interrupted run would leave the file behind.

### Running it from a local copy

If you have cloned the repository:

```bash
git clone https://github.com/yannisduvignau/usb-doctor.git
cd usb-doctor && ./usb-doctor.sh
```

## What it does

It runs in four stages and stops to ask before anything irreversible.

| Stage | What happens | Risk |
|---|---|---|
| 1. Diagnose | Reads the drive, checks the partition table and filesystem | None — read-only |
| 2. Back up | Copies the whole drive to an image file on the Desktop | None to the drive |
| 3. Repair | Fixes the filesystem | Writes to the drive |
| 4. Clean up | Removes anything it installed | None |

Stages 2 and 3 only run if stage 1 finds a problem. A healthy drive stops
after the diagnosis.

### What you actually have to do

Two things: enter your Mac password, and confirm which drive to work on
(`y`, or a number if several external disks are plugged in). Everything
after that is decided automatically.

### How the repair decides

Repairing writes to the drive and can, in rare cases, discard files that
were already damaged. So it only runs automatically **once the backup image
exists**:

- Enough free space → the image is created, then the repair runs.
- Not enough space, or the copy failed → **the repair does not run.** The
  script says why and prints the manual command, rather than risking data
  that may have no other copy.

The image needs as much free space as the drive's *total* size — a 64 GB
drive needs 64 GB free, even if it holds only a few files.

Everything it finds is saved to a folder on your Desktop named
`usb-doctor-<date>`, containing a full `report.txt`.

## About the backup

Before repairing, the script offers to copy the entire drive into a single
`.dmg` image file. This is worth doing: repairing a filesystem occasionally
discards files that were already damaged, and the image makes that
recoverable.

It needs as much free space on your Mac as the drive's total size — a 64 GB
drive needs 64 GB free, even if it only holds a few files. The script shows
you your free space before asking.

The copy does not stop at unreadable sectors; it fills them with zeroes and
carries on, so a partially failing drive still produces a usable image.

## About downloads

The script installs nothing in the normal case. macOS already includes every
tool it needs for FAT32, exFAT, HFS+ and APFS drives — `diskutil`,
`fsck_msdos`, `fsck_exfat`, `fsck_hfs`, `gpt` and `dd`.

There is one exception. macOS can read **NTFS** drives but has no tool to
repair them. If a damaged NTFS partition is found and Homebrew is already
installed, the script installs `ntfs-3g` and removes it again when it exits —
including if you press Ctrl+C partway through.

If Homebrew is *not* installed, the script skips this rather than installing
it. Homebrew is a large, permanent addition to the system, and `ntfsfix`
does not truly repair NTFS anyway — so it would be a poor trade.

Be aware that `ntfs-3g` only flags an NTFS volume for a later scan; it does
not truly repair it. For NTFS, the reliable fix is a Windows PC:

```
chkdsk X: /f
```

(replacing `X:` with the drive letter).

## What the results mean

**No external disk detected** — the Mac isn't seeing the drive at all, even
as hardware. The filesystem isn't the problem. Try a different port, then a
different USB-C adapter. If the drive works on Windows but on no Mac, the
adapter is the most common culprit.

**Filesystem is corrupt** — the expected finding for this symptom. Windows
is more tolerant than macOS and often repairs such faults silently at mount
time, which is why the drive still opens on a PC. Stage 3 usually fixes this.

**Partition table missing** — the data is probably still there, but macOS no
longer knows where it starts. Do not reformat; use recovery software first.

**Media not responding** — a hardware fault. Software repair won't help.
Copy whatever is still readable, immediately.

## If it doesn't work

1. **Recover the data first.** On Windows, `chkdsk X: /f` fixes most cases.
   On macOS, TestDisk (free) or DiskDrill can read an unmounted drive.
2. **Then reformat.** Disk Utility → Erase → format **exFAT**, scheme
   **GUID**. exFAT reads and writes natively on both macOS and Windows;
   NTFS does not, which is what causes this problem in the first place.
3. **If it happens again, replace the drive.** Repeated corruption means
   worn-out flash memory.

Whatever the outcome, copy the drive's contents somewhere else as soon as it
mounts. A drive that has corrupted once tends to do it again.
