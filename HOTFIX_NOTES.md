# Mission Control Plus (v1.31) Hotfix Notes

## 1. Overview & Problem Description

On multi-monitor setups where displays are arranged vertically (e.g. an upper monitor stacked above a primary monitor), Mission Control Plus (v1.31) fails to show the close button ("X") or register mouse-hover events when Mission Control is active.

### Trigger Condition
- Multi-display arrangement where an upper display's bottom edge touches the primary display's top edge ($Y = 0$ in CoreGraphics coordinate space).
- The primary monitor ($[0, 0, \text{width}, \text{height}]$ in Cocoa coordinates) is positioned below the secondary monitor.

---

## 2. Root Cause Technical Analysis

The root cause lies in `captureWindows()` inside the ARM64 slice of the binary:

### Bug 1: Off-by-One Coordinate Conversion Subtraction
MCP converts CoreGraphics window bounds to Cocoa screen coordinates using:
$$\text{cocoaRect.origin.y} = \text{primaryScreen.height} - \text{cgRect.origin.y} - 1.0 - \text{cgRect.size.height}$$

The `- 1.0` subtraction causes any window whose bottom edge is flush with the bottom of the upper display ($\text{cgRect.origin.y} + \text{cgRect.size.height} = 0$) to calculate a Cocoa Y origin of:
$$\text{cocoaRect.origin.y} = \text{primaryScreen.height} - 0.0 - 1.0 = \text{primaryScreen.height} - 1.0$$

Because $\text{primaryScreen.height} - 1.0 < \text{primaryScreen.height}$, the bottom of the window bleeds **1 pixel down** into the primary display's vertical coordinate range ($[0.0, \text{primaryScreen.height}]$).

### Bug 2: Fatal Early Abort on Screen Hit-Testing
When MCP associates captured windows with displays, it iterates over `NSScreen.screens`:
1. `Screen 0` (the primary display) is tested first.
2. Because of the 1-pixel overlap from Bug 1, `CGRectIntersectsRect(Screen[0].frame, cocoaRect)` evaluates to `true`.
3. MCP then tests: `CGRectContainsPoint(Screen[0].frame, window.midPoint)`.
4. Because the window physically lives on the upper display, its midpoint is located in the upper display, outside `Screen 0`.
5. **The Fatal Abort:** Instead of continuing the loop to check `Screen 1`, MCP executes:
   ```assembly
   tbz w0, #0x0, <abort_label>
   ```
   This immediately deallocates the captured windows array and exits the function, returning an empty list `[]` on every poll frame.

Because `capturedWindows.count == 0` continuously:
- `isMissionControlIdle()` evaluates to `false`.
- Mouse tracking taps and close button windows are never spawned.

---

## 3. Binary Patch Specification (ARM64)

The hotfix modifies two instructions in the ARM64 slice:

### Patch 1: Coordinate Conversion Math Fix
- **Virtual Address:** `0x100031260` (Standalone release) / `0x10001405c` (Setapp release)
- **Original Code:**
  ```assembly
  fmov    d1, #-1.00000000   ; 01 10 7e 1e
  fadd    d13, d0, d1        ; 0d 28 61 1e
  ```
- **Patched Code:**
  ```assembly
  fmov    d13, d0            ; 0d 40 60 1e
  nop                        ; 1f 20 03 d5
  ```
- **Effect:** Eliminates the `- 1.0` subtraction so $\text{cocoaY} = \text{primaryHeight} - \text{cgY} - \text{cgHeight}$.

### Patch 2: Screen Loop Continuation
- **Virtual Address:** `0x100031638` (Standalone release) / `0x100014434` (Setapp release)
- **Original Code:**
  ```assembly
  tbz     w0, #0x0, abort    ; 20 0f 00 36 (+121 instructions to error teardown)
  ```
- **Patched Code:**
  ```assembly
  tbz     w0, #0x0, next     ; 00 ea 07 36 (-176 instructions to loop next screen)
  ```
- **Effect:** When a window's midpoint is not inside the current screen, MCP branches to the loop continuation block, releasing the screen reference and evaluating the next screen.

---

## 4. Automation & Maintenance

- **`apply_hotfix.sh`**: Python-based automation script that dynamically locates the ARM64 byte signatures, creates a backup (`.original`), applies both patches, strips extended attributes, and ad-hoc signs the application.
- **`.github/workflows/check_upstream.yml`**: Scheduled daily GitHub Action that checks `ronyfadel/MissionControlPlusReleases` for any tag newer than `v1.31` and opens an issue if an official update is available.
