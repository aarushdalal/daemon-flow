# FLOW v0.3.0

**Task-aware 2-level AMD Ryzen power allocation, AC/Battery-scoped manual holds, Flow operating modes (`Adaptive` / `Silent` / `Focus`), and graduated 90°C/93°C/96°C thermal protection.**

### Highlights in v0.3.0:
- **Full 2-Level Hierarchy Scaling**: Dynamically utilizes intermediate `(Tier, Allocation)` pairs (`Quiet · 50%/75%/100%`, `Standard · 75%/100%`, `Extreme · 100%`) instead of 3 rigid diagonal presets, including `Standard · Performance` (16W) on battery above 30% charge and 25W `Extreme · Performance` on AC in ~6s for sustained multi-core or GPU workloads.
- **Hybrid Telemetry & Bounded `/proc` Task Classification**: Separates `iowait` from `idle`, tracks per-core concurrency (`busy_cores`), and scans `/proc/<pid>/stat` to keep `nice >= 10` background indexers snappy at `Standard · Balanced` without spinning up `Extreme` fans.
- **Flow Operating Modes**: Switch live between `Adaptive`, `Silent` (capped at `Quiet` tier), and `Focus` (minimum `Standard · Balanced` floor with faster `Extreme` boost) from the panel or `omarchy-shell flow mode <mode>`.
- **Power-Source-Scoped Manual Hold**: Manual tier/allocation overrides stay held only for the active power source (`AC` or `Battery`), automatically releasing when switching between AC and Battery and avoiding false latches on OS plug/unplug transitions.
- **Graduated Thermal Step-Down**: Steps down smoothly (`>= 90°C` → `Standard · Performance` 20W, `>= 93°C` → `Standard · Balanced` 15W, `>= 96°C` → `Quiet · Power-Saver` 8W) with 5°C hysteresis.
- **Upgraded Panel & IPC**: Clear `HELD (AC/BAT)` / `AUTO · MODE` badge, desktop notification on external holds, live target wattage & task class readout, quick manual Tier/Allocation controls, and `omarchy-shell flow set <tier> <profile>`.
- **Testing**: 34 unit & regression tests pass; native offscreen Quickshell service probe passes.

Read `README.md` before installation.
