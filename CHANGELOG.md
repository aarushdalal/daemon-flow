# Changelog

## 0.3.0 — 2026-11-25

- **Task-Aware 2-Level Power Allocation**: Expanded policy decisions across the full 2-level hierarchy (`Quiet` / `Standard` / `Extreme` × `50%` / `75%` / `100%`) instead of 3 rigid diagonal pairs, unlocking intermediate states such as `Quiet · Balanced` (11W) and `Standard · Performance` (20W AC / 16W Battery above 30%).
- **Hybrid Telemetry & Bounded `/proc` Task Classification**: Separated `iowait` from `idle` in `/proc/stat`, added per-core concurrency (`busy_cores`), and added bounded `/proc/<pid>/stat` scanning to distinguish foreground compute/compile/GPU workloads from `nice >= 10` background indexers (capped at `Standard · Balanced`).
- **Flow Operating Modes (`Adaptive` / `Silent` / `Focus`)**: Added selectable modes via `Panel.qml` and `omarchy-shell flow mode <adaptive|silent|focus>`.
- **Power-Source-Scoped Manual Hold**: Manual tier/profile overrides now latch only for the active power source (`AC` or `Battery`), automatically releasing on AC ↔ Battery switches, eliminating false latches during OS plug/unplug hooks, and surfacing a `HELD (AC/BAT)` badge + desktop notification.
- **Graduated 90°C / 93°C / 96°C Thermal Step-Down**: Replaced the 88°C drop to 15W with graduated step-downs (`>= 90°C` → `Standard · Performance` 20W; `>= 93°C` → `Standard · Balanced` 15W; `>= 96°C` → `Quiet · Power-Saver` 8W), each with 5°C hysteresis.
- **Panel UI & IPC Upgrades**: Added Flow Mode pills, manual Tier (`Quiet` / `Standard` / `Extreme`) & Allocation (`50%` / `75%` / `100%`) controls, live target wattage/thermal ceiling readout, and `omarchy-shell flow set <tier> <profile>` IPC.
- **Test Suite Expansion**: 34 unit and regression tests pass in the repository suite alongside the native Quickshell offscreen service probe.

## 0.2.0 — 2026-11-12

- **Build Stall & Heavy Compute Fix**: Graduated thermal step-down (intermediate thermal cap at 88°C steps down to Standard 20W rather than Quiet; critical thermal emergency threshold set to 96°C). High-demand compilation jobs freely operate in Standard and Extreme across the 80°C–87°C range.
- **Peripheral Battery Filter**: Fixed battery parsing in `monitor.py` to filter out peripheral devices (`scope: Device`, e.g. digitizer/stylus reporting 0%) so laptops running on battery (unplugged from AC) are not falsely forced into Quiet battery reserve mode.
- **Universal Dual-Backend Actuator**: Added graceful fallback to Linux standard `powerprofilesctl` when `/run/ryzen-power.sock` is absent, allowing pure AMD Ryzen platforms without custom SMU daemons to run out-of-the-box.
- **Multi-Sensor Thermal Discovery**: Extended sensor probing across `k10temp`, `zenpower`, `coretemp`, and ACPI thermal zones.
- **Test Suite Expansion**: Added build-load, graduated thermal hysteresis, and fallback actuator regressions; 29 unit tests pass.

## 0.1.1 — 2026-11-11

Initial separate-repository publication of the documented capability set. Compatibility and known limitations are recorded in README.md.
