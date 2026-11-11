# Existing hardware-owner contract

Flow expects an existing local UNIX stream socket `/run/ryzen-power.sock`. Each connection sends one ASCII request, receives one bounded JSON reply, then closes. The owner is trusted to enforce thermal and hardware limits.

| Request | Reply contract |
|---|---|
| `STATUS` | `status:ok`, `tier:quiet/standard/extreme`, `profile:power-saver/balanced/performance`, `on_ac:boolean` |
| `SET_TIER:<tier>` | `status:ok` only after accepting the tier |
| `SET_PROFILE:<profile>` | `status:ok` only after accepting the profile |

Flow checks the owner state before and after each step and verifies actual PPD profile with `powerprofilesctl get`. Rejected/time-out/mismatched transitions delay retries10seconds. Successfully verified partial changes are acknowledged so a later retry does not falsely enter a manual hold. Unacknowledged state changes latch that hold.

The protocol lacks atomic compare-and-set. Checks reduce conflicting changes but cannot eliminate a concurrent-user-change race between a check and a setter. Do not run multiple automatic clients. Quiet/Standard/Extreme watt envelopes and PPD profiles are separate settings, configured by the existing owner; no arbitrary TDP numbers are embedded in Flow.
