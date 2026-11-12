# Changelog

## 0.2.0 — 2026-11-12

- **Build Stall & Heavy Compute Fix**: Graduated thermal step-down (intermediate thermal cap at 88°C steps down to Standard 20W rather than Quiet; critical thermal emergency threshold set to 96°C). High-demand compilation jobs freely operate in Standard and Extreme across the 80°C–87°C range.
- **Peripheral Battery Filter**: Fixed battery parsing in `monitor.py` to filter out peripheral devices (`scope: Device`, e.g. digitizer/stylus reporting 0%) so laptops running on battery (unplugged from AC) are not falsely forced into Quiet battery reserve mode.
- **Universal Dual-Backend Actuator**: Added graceful fallback to Linux standard `powerprofilesctl` when `/run/ryzen-power.sock` is absent, allowing pure AMD Ryzen platforms without custom SMU daemons to run out-of-the-box.
- **Multi-Sensor Thermal Discovery**: Extended sensor probing across `k10temp`, `zenpower`, `coretemp`, and ACPI thermal zones.
- **Test Suite Expansion**: Added build-load, graduated thermal hysteresis, and fallback actuator regressions; 29 unit tests pass.

## 0.1.1 — 2026-11-11

Initial separate-repository publication of the documented capability set. Compatibility and known limitations are recorded in README.md.
