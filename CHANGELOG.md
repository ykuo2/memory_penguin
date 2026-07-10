# Changelog

All notable changes to Memory Penguin are recorded in this file. The format is
based on Keep a Changelog, and release versions follow Semantic Versioning.

## [Unreleased]

No unreleased changes yet.

## [0.3.0] - 2026-07-10

### Added

- Added `MemoryPenguinCore` as a reusable home for memory calculations, process
  snapshot parsing, process identity checks, and CPU limit policy logic.
- Added effective used, physical occupied, reclaimable, bounded anonymous, and
  bounded file-backed memory details.
- Added pre-generated transparent status icons for calm, elevated, and high
  memory pressure while retaining the original `memory_icon.png` sprite sheet.
- Added protected-process filtering plus PID, owner UID, and process start-time
  validation before sending process-control signals.
- Added an independent heartbeat resume guard that resumes duty-cycle-limited
  processes after an app crash, forced exit, or stalled main loop.
- Added broader core self-tests and a process-level resume guard integration
  test.

### Changed

- Changed the menu bar percentage and first menu summary from physical memory
  occupancy to the Effective Used Estimate.
- Kept the kernel memory pressure level as the authoritative calm, elevated, or
  high icon state, separate from the estimated usage percentage.
- Clarified CPU limit modes as process run-time duty cycles, such as `Run 50% of
  Time`, rather than absolute CPU percentage ceilings.
- Moved process snapshot collection off the menu UI path and limited refreshes
  to periods when the menu is open.
- Changed process-list failures to appear as `Process list unavailable` instead
  of looking like a valid empty list.
- Updated the application version from 0.2.12 to 0.3.0.

### Fixed

- Prevented invalid, protected, foreign-owner, or reused PIDs from receiving CPU
  control signals.
- Ensured stopped processes are resumed when a limiter is removed or its safety
  heartbeat is lost.
- Normalized speculative and purgeable memory counters to avoid double-counting
  reclaimable memory and bounded estimates to valid physical-memory ranges.

### Verification

- Passed all 19 `MemoryPenguinCoreSelfTests` checks.
- Passed the resume guard process integration test.
- Built and ad-hoc signed the release app bundle and portable archive.
