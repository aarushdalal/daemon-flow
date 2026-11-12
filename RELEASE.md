# FLOW v0.2.0

**Dynamic AMD Ryzen power management with graduated thermal step-down, peripheral battery filtering, and universal dual-backend support.**

### Highlights in v0.2.0:
- **Build Stall & Heavy Compute Fix**: Raised critical thermal emergency limit to 96°C; intermediate thermal cap at 88°C steps down to Standard (20W balanced) rather than stalling in Quiet. Heavy compilation and rendering jobs freely maintain Standard and Extreme power envelopes across the 80°C–87°C range.
- **Peripheral Battery Filter**: Fixed battery parsing in `monitor.py` to filter out peripheral devices (`scope: Device`, e.g. digitizer/stylus reporting 0%) so laptops running on battery (unplugged from AC) are not falsely forced into Quiet battery reserve mode.
- **Universal Dual-Backend Actuator**: Added graceful fallback to Linux standard `powerprofilesctl` when `/run/ryzen-power.sock` is absent, allowing pure AMD Ryzen platforms without custom SMU daemons to run out-of-the-box.
- **Multi-Sensor Thermal Discovery**: Extended sensor probing across `k10temp`, `zenpower`, `coretemp`, and ACPI thermal zones.
- **Testing**: 29 unit and regression tests pass; native offscreen Quickshell service probe passes.

Read `README.md` before installation.
