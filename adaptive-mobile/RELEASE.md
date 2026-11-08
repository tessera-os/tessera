# 26.11.1

**Project:** AdaptiveMobile  
**Release week:** 2026-11-02 – 2026-11-08

## Highlights

- Mobile platform, windows, dead-zone handling, and startup code changed in 4 tracked package file(s) since the `26.10.4` baseline.

## Changed

- `app/Mobile/DeadZone.kira`
- `app/Mobile/Platform.kira`
- `app/Mobile/Windows.kira`
- `app/main.kira`
- Swipe-to-home now keeps the Desktop home surface visible, restoring it if an earlier swipe hid it, instead of hiding Desktop along with the foreground app.
- A locked phone with no configured passcode now accepts a primary tap or click as well as swipe-up. The platform consumes the matching release so no unmatched input reaches the GUI. When a passcode is configured, the lock screen displays its keypad instead of allowing the tap shortcut.

## Validation

- The swipe-to-home defect was traced to S23+ serial logs showing Desktop (surface 3) and the foreground app (surface 4) both being hidden. Boot input was traced to the lock screen requiring a drag while the compositor already received primary pointer presses. An unoptimized ARM64 executable compiled with an isolated KiraUI compatibility copy passed a QEMU click-to-unlock test and was installed on the S23+ as dev-root `mobile-touch-20261107` (request 1794012409163, 0 failures). On-device serial logs confirm that its primary press opened the lock screen and returned input focus to Welcome. A subsequent passcode-state caching adjustment is present in source but was not included in that tested device binary. Cold-boot device verification remains pending.
