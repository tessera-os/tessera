# 26.11.1

**Project:** WelcomeApp  
**Release week:** 2026-11-02 – 2026-11-08

## Highlights

- Added a bottom-left **Skip Setup** action on all setup pages before Done. It persists setup completion and closes Welcome without requiring language, keyboard, time-zone, or appearance selections.
- The setup navigation stays at the bottom of the available height on compact mobile screens.

## Validation

- The ARM64 Welcome executable compiled successfully with `--no-optimize` and was installed as dev-root `welcome-skip-20261107` (request 1794012409163, 0 failures). Device logs confirm the restarted Welcome process received focus. Physical interaction with Skip Setup still needs a user test.
