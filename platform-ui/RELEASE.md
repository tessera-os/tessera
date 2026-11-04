# 26.11.1

**Project:** Platform UI  
**Release week:** 2026-11-02 – 2026-11-08

## Highlights

Added built-in wallpapers and adjusted lock-screen swipe completion.

## Added

- Bundled light and dark wallpaper image resources.

## Fixed

- Lock-screen swipe-up completion now considers the greater of the actual upward drag and the predicted end translation, so a sufficiently long drag can open the cover without depending solely on its predicted momentum.

## Validation

- No on-device lock-screen or wallpaper rendering test was run for this release preparation.
