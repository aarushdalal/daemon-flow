# DAEMON Flow

![DAEMON Flow showcase](assets/showcase.svg)

[Full-size panel](assets/panel.png) · [Capture provenance](assets/PROVENANCE.md)

Measured demand, deliberate power changes. Native Omarchy controls backed by your **AMD Ryzen platform**, with fast upshifts, slower downshifts and manual choices that stay held.

**Release:** v0.2.0 · normal release, engineered for AMD Ryzen APUs/CPUs with AMD Radeon Graphics.

---

## What works

- **Demand Telemetry**: System-wide CPU and busiest-core demand, GPU utilization, multi-sensor temperature discovery, and scoped system battery telemetry.
- **PSI Pressure Diagnostics**: CPU, memory and I/O pressure diagnostics (`some.avg10`); disk/RAM stalls alone do not request Extreme.
- **Fast Upshifts, Stable Cooldowns**: Standard after 2 seconds of sustained demand, Extreme after 12 seconds of heavy demand on AC, and 60 seconds of light-work dwell before Quiet. Downshifts observe 30 seconds minimum duration to prevent frequency oscillation.
- **Graduated Thermal Step-Down**:
  - Normal compilation workloads (80°C–87°C on AC) freely engage Extreme (25W) and Standard (20W).
  - High sustained temperatures ($\ge 88^\circ$C) step down to Standard (20W balanced), allowing the hardware SMU and kernel governor to manage clock speeds while keeping builds running at full speed.
  - Critical emergency drop to Quiet activates only if temperatures reach $\ge 96^\circ$C.
- **Peripheral Battery Filtering**: Evaluates battery `scope` to filter out 0%-reporting styluses, pens, and peripheral digitizers (`scope: Device`), accurately reading the primary system battery (`BAT0`).
- **Dual-Backend Support**:
  - **Full Custom Mode (Best Experience)**: Pairs with `/run/ryzen-power.sock` (`ryzen-power-daemon`) for direct SMU wattage clamping and AMDGPU DPM tuning.
  - **Universal Fallback Mode**: Gracefully drives Linux standard `powerprofilesctl` (`power-saver`, `balanced`, `performance`) when the custom socket is absent.
- **Persistent Manual Hold & Resumption**: Preserves user manual profile selections until explicit **Resume Auto** or Auto toggle.

---

## Required Backend

1. **Custom Ryzen Mode**: Python 3, `powerprofilesctl` and a running `/run/ryzen-power.sock` (`ryzen-power-daemon`). See [the backend contract](docs/POWER_OWNER.md).
2. **Universal Linux Mode**: Python 3 and standard `powerprofilesctl` (`power-profiles-daemon`).

Flow does not require root privileges and performs no direct sysfs writes itself.

---

## Install

```sh
omarchy plugin add https://github.com/aarushdalal/daemon-flow --enable
omarchy plugin validate ~/.config/omarchy/plugins/daemon0.flow
omarchy-shell shell toggle daemon0.flow
```

The manager may choose a different checkout directory; validate the path printed by `omarchy plugin list`. A manual profile change pauses automation until Resume Auto or an explicit Auto off/on cycle.

---

## Keyboard and Diagnostics

Suggested shortcut, added to your existing Lua bindings after checking conflicts:

```lua
o.bind("SUPER + CTRL + P", "DAEMON Flow", "omarchy-shell shell toggle daemon0.flow")
```

Within the panel: `R` refresh, `A` apply the current advisory when Auto is off, `U` toggle Auto, `Esc` close. The Resume Auto button releases a held manual choice.

```sh
omarchy-shell flow status
omarchy-shell flow pause
omarchy-shell flow resume
```

`resume` enables Auto and clears its manual hold. Settings: `~/.config/omarchy/flow.json` (`schema`, `autoApply`, `manualHold`). Never expose the local hardware-owner socket over the network.

---

## Development and Validation

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
python3 tests/native_service_probe.py  # needs installed Quickshell; offscreen, no hardware writes
python3 monitor.py --samples 3 --interval 2  # actual read-only sampling
```

29 unit and regression tests pass. Native offscreen hold/resume/file-watch probe passes on Quickshell.

---

## Troubleshooting and Rollback

- **No escalation**: Check Auto, manual hold, temperature and `flow status` reasons. Extreme is intentionally blocked on battery or high thermal states.
- **CPU remains low while work is slow**: Inspect pressure reasons; disk/RAM stalls cannot be solved by CPU wattage alone.
- **Disable plugin**: Run `omarchy plugin disable daemon0.flow`; disable Auto first with `omarchy-shell flow pause`. Current hardware profile is preserved.

[Security](SECURITY.md) · [Third-party notices](THIRD_PARTY.md) · [Changelog](CHANGELOG.md)

---

## Compatibility and Installation Safety

Requires the native Omarchy Quattro / Quickshell plugin API (`qs.Ui`, `qs.Commons`). Tested on Arch Linux / Hyprland / Omarchy with AMD Ryzen processors and AMD Radeon Graphics.
