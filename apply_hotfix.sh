#!/usr/bin/env python3
"""
Mission Control Plus (v1.31) Hotfix Script
Fixes close button ("X") failure on multi-monitor vertical arrangements.

Usage:
  ./apply_hotfix.sh           # Apply the hotfix, re-sign, and restart MCP
  ./apply_hotfix.sh --restore # Restore the original unpatched backup
  ./apply_hotfix.sh --status  # Check current patch status
"""

import sys
import os
import subprocess
import shutil

APP_PATH = "/Applications/Setapp/Mission Control Plus.app"
BIN_PATH = os.path.join(APP_PATH, "Contents/MacOS/Mission Control Plus")
BACKUP_PATH = BIN_PATH + ".original"

# Patch 1: Coordinate fix (replaces fmov d1, #-1.0; fadd d13, d0, d1 with fmov d13, d0; nop)
# Context: fsub d0, d0, d12 (00 38 6c 1e) followed by fmov d1, #-1.0 (01 10 7e 1e) and fadd d13, d0, d1 (0d 28 61 1e)
P1_ORIG = bytes.fromhex("01107e1e 0d28611e")
P1_PATCH = bytes.fromhex("0d40601e 1f2003d5")

# Patch 2: Screen loop continuation (replaces abort jump with loop to next screen)
# Original: tbz w0, #0, abort (+121 instructions = +484 bytes = 20 0f 00 36)
# Patched:  tbz w0, #0, next  (-176 instructions = -704 bytes = 00 ea 07 36)
P2_ORIG = bytes.fromhex("200f0036")
P2_PATCH = bytes.fromhex("00ea0736")

# Unique signature prefix for Patch 1: fsub d0, d0, d12
P1_SIG_PREFIX = bytes.fromhex("00386c1e")


def find_patch_offsets(data: bytes):
    """Locate patch points dynamically across both Setapp and standalone builds."""
    # Search for P1_SIG_PREFIX followed by P1_ORIG or P1_PATCH
    pos = 0
    p1_offset = None
    while True:
        idx = data.find(P1_SIG_PREFIX, pos)
        if idx == -1:
            break
        candidate = idx + len(P1_SIG_PREFIX)
        if data[candidate : candidate + len(P1_ORIG)] == P1_ORIG or data[candidate : candidate + len(P1_PATCH)] == P1_PATCH:
            p1_offset = candidate
            break
        pos = idx + 1

    if p1_offset is None:
        return None, None

    # Patch 2 is always exactly at p1_offset + 0x3d8
    p2_offset = p1_offset + 0x3d8
    return p1_offset, p2_offset


def check_status():
    if not os.path.exists(BIN_PATH):
        print(f"[!] App not found at {APP_PATH}")
        return
    with open(BIN_PATH, "rb") as f:
        data = f.read()

    off1, off2 = find_patch_offsets(data)
    has_backup = os.path.exists(BACKUP_PATH)

    print("=== Mission Control Plus Status ===")
    print(f"Target App:      {APP_PATH}")
    print(f"Backup exists:   {has_backup}")

    if off1 is None or off2 is None:
        print("Patch Status:    UNKNOWN / INCOMPATIBLE BINARY")
        return

    is_p1_patched = data[off1 : off1 + len(P1_PATCH)] == P1_PATCH
    is_p2_patched = data[off2 : off2 + len(P2_PATCH)] == P2_PATCH
    is_p1_orig = data[off1 : off1 + len(P1_ORIG)] == P1_ORIG
    is_p2_orig = data[off2 : off2 + len(P2_ORIG)] == P2_ORIG

    if is_p1_patched and is_p2_patched:
        print("Patch Status:    HOTFIX APPLIED (Active)")
    elif is_p1_orig and is_p2_orig:
        print("Patch Status:    ORIGINAL (Unpatched - Ready to Patch)")
    else:
        print("Patch Status:    PARTIALLY MODIFIED")


def restore():
    print(f"[*] Restoring original binary for {APP_PATH}...")
    if not os.path.exists(BACKUP_PATH):
        print(f"[!] Error: Backup file not found at {BACKUP_PATH}")
        sys.exit(1)

    print("[*] Quitting running instances...")
    subprocess.run(["osascript", "-e", 'tell application "Mission Control Plus" to quit'], capture_output=True)
    subprocess.run(["killall", "Mission Control Plus"], capture_output=True)

    print("[*] Restoring backup...")
    shutil.copy2(BACKUP_PATH, BIN_PATH)

    print("[*] Stripping extended attributes...")
    subprocess.run(["xattr", "-cr", APP_PATH], check=False)

    print("[*] Re-signing app bundle (ad-hoc)...")
    subprocess.run(["codesign", "--force", "--deep", "-s", "-", APP_PATH], check=True)

    print("[*] Relaunching Mission Control Plus...")
    subprocess.run(["open", APP_PATH])
    print("[✓] Restored and relaunched successfully.")


def apply_patch():
    print("=== Applying Mission Control Plus Hotfix ===")
    if not os.path.exists(BIN_PATH):
        print(f"[!] Error: Application binary not found at:\n    {BIN_PATH}")
        sys.exit(1)

    with open(BIN_PATH, "rb") as f:
        data = bytearray(f.read())

    off1, off2 = find_patch_offsets(data)
    if off1 is None or off2 is None:
        print("[!] Error: Could not locate patch targets in binary. Unsupported build.")
        sys.exit(1)

    already_patched = (data[off1 : off1 + len(P1_PATCH)] == P1_PATCH and 
                       data[off2 : off2 + len(P2_PATCH)] == P2_PATCH)

    if already_patched:
        print("[*] Hotfix binary patches already written. Finalizing signature and launching...")
    else:
        # Verify original bytes
        if data[off1 : off1 + len(P1_ORIG)] != P1_ORIG or data[off2 : off2 + len(P2_ORIG)] != P2_ORIG:
            print("[!] Error: Binary byte signatures did not match expected v1.31 ARM64 code.")
            sys.exit(1)

        # 1. Create backup if it doesn't already exist
        if not os.path.exists(BACKUP_PATH):
            print(f"[*] Creating backup of original binary at:\n    {BACKUP_PATH}")
            shutil.copy2(BIN_PATH, BACKUP_PATH)
        else:
            print(f"[*] Preserving existing backup at:\n    {BACKUP_PATH}")

        # 2. Quit running app
        print("[*] Quitting running instances...")
        subprocess.run(["osascript", "-e", 'tell application "Mission Control Plus" to quit'], capture_output=True)
        subprocess.run(["killall", "Mission Control Plus"], capture_output=True)

        # 3. Apply patches in memory
        print(f"[*] Patching coordinate conversion at file offset {hex(off1)}...")
        data[off1 : off1 + len(P1_PATCH)] = P1_PATCH

        print(f"[*] Patching screen loop check at file offset {hex(off2)}...")
        data[off2 : off2 + len(P2_PATCH)] = P2_PATCH

        # 4. Write back to binary
        print(f"[*] Writing patched binary to {BIN_PATH}...")
        with open(BIN_PATH, "wb") as f:
            f.write(data)

    # 5. Clear extended attributes & ad-hoc re-sign
    print("[*] Stripping extended attributes (FinderInfo/detritus)...")
    subprocess.run(["xattr", "-cr", APP_PATH], check=False)

    print("[*] Re-signing app bundle (ad-hoc)...")
    subprocess.run(["codesign", "--force", "--deep", "-s", "-", APP_PATH], check=True)

    # 6. Relaunch
    print("[*] Relaunching Mission Control Plus...")
    subprocess.run(["open", APP_PATH])

    print("\n[✓] Hotfix applied successfully!")
    print("Mission Control Plus is now running with the fix.")
    print("Trigger Mission Control to verify the close button ('X') appears on your windows.")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--restore":
        restore()
    elif len(sys.argv) > 1 and sys.argv[1] == "--status":
        check_status()
    elif len(sys.argv) > 1 and sys.argv[1] in ("--help", "-h"):
        print(__doc__)
    else:
        apply_patch()
