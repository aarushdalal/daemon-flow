"""Measured task-aware system-demand policy across the 2-level Ryzen power hierarchy."""
from dataclasses import dataclass
import math


TIERS = ('quiet', 'standard', 'extreme')
PROFILES = ('power-saver', 'balanced', 'performance')
MODES = ('adaptive', 'silent', 'focus')


@dataclass
class Policy:
    smooth_seconds: float = 6
    minimum_duration: float = 25
    quiet_delay: float = 60
    burst_delay: float = 2
    medium_delay: float = 4
    heavy_delay: float = 6
    thermal_limit: float = 96
    thermal_standard_bal_limit: float = 93
    thermal_extreme_limit: float = 90
    maximum_gap: float = 30
    battery_floor: float = 20
    battery_perf_floor: float = 30

    def __post_init__(self):
        limits = {
            'smooth_seconds': (1, 120),
            'minimum_duration': (1, 600),
            'quiet_delay': (1, 600),
            'burst_delay': (1, 60),
            'medium_delay': (1, 120),
            'heavy_delay': (1, 600),
            'thermal_limit': (50, 105),
            'thermal_standard_bal_limit': (50, 102),
            'thermal_extreme_limit': (50, 100),
            'maximum_gap': (5, 120),
            'battery_floor': (5, 50),
            'battery_perf_floor': (10, 80),
        }
        for key, (low, high) in limits.items():
            value = getattr(self, key)
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or not low <= value <= high:
                raise ValueError('Invalid policy setting: ' + key)


class Engine:
    def __init__(self, policy=None, mode='adaptive'):
        if mode not in MODES:
            raise ValueError('Invalid flow mode: ' + str(mode))
        self.policy = policy or Policy()
        self.mode = mode
        self.last_time = None
        self.last_on_ac = None
        self.ema = None
        self.proposal = None
        self.proposal_since = None
        self.recommendation = None
        self.changed_at = None
        self.observed = None
        self.override = False
        self.hold_on_ac = None
        self.demand_since = None
        self.thermal_guard = False
        self.thermal_standard_bal = False
        self.thermal_extreme_capped = False

    def set_mode(self, mode):
        if mode not in MODES:
            raise ValueError('Invalid flow mode: ' + str(mode))
        self.mode = mode

    def acknowledge_applied(self, tier, profile):
        """Only the actuator may acknowledge a read-back verified own transition."""
        if tier not in TIERS or profile not in PROFILES:
            raise ValueError("Invalid applied state")
        self.observed = (tier, profile)

    def release_override(self):
        self.override = False
        self.hold_on_ac = None

    def update(self, sample):
        p = self.policy

        def number(key, low, high, required=False):
            value = sample.get(key)
            if value is None and not required:
                return None
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or not low <= value <= high:
                raise ValueError('Invalid ' + key)
            return value

        now = number('time', 0, 1e15, True)
        cpu = number('cpu', 0, 100, True)
        core = number('busiest_core', 0, 100)
        busy_cores = number('busy_cores', 0, 256)
        gpu = number('gpu', 0, 100)
        temperature = number('temperature', -20, 150)
        battery = number('battery', 0, 100)
        pressure = number('memory_pressure', 0, 100)
        cpu_pressure = number('cpu_pressure', 0, 100)
        io_pressure = number('io_pressure', 0, 100)
        iowait = number('iowait', 0, 100) or 0.0
        nice_share = number('nice_share', 0, 1) or 0.0
        task_class = sample.get('task_class')
        mode = sample.get('mode', self.mode)
        if mode not in MODES:
            raise ValueError('Invalid flow mode: ' + str(mode))
        on_ac = sample.get('on_ac')
        if type(on_ac) is not bool:
            raise ValueError('Power source unknown')
        current = (sample.get('tier'), sample.get('profile'))
        if current[0] not in TIERS or current[1] not in PROFILES:
            raise ValueError('Power policy unknown')
        if self.last_time is not None and now <= self.last_time:
            raise ValueError('Samples must have increasing timestamps')

        reasons = []
        power_source_changed = (self.last_on_ac is not None and on_ac != self.last_on_ac)
        if self.override and self.hold_on_ac is not None and on_ac != self.hold_on_ac:
            self.override = False
            self.hold_on_ac = None
            reasons.append('power source changed; manual hold released')
        elif power_source_changed and self.override:
            self.override = False
            self.hold_on_ac = None
            reasons.append('power source changed; manual hold released')

        if power_source_changed:
            # Accept OS power-source transition profile without latching a false hold.
            self.observed = current
            self.proposal = None
            self.proposal_since = None
        else:
            if self.observed is not None and current != self.observed:
                self.override = True
                self.hold_on_ac = on_ac
            self.observed = current

        self.last_on_ac = on_ac
        if self.recommendation is None:
            self.recommendation = current
            self.changed_at = now

        dt = 0 if self.last_time is None else now - self.last_time
        discontinuity = self.last_time is not None and dt > p.maximum_gap
        if discontinuity:
            self.ema = None
            self.proposal = None
            self.demand_since = None
            self.recommendation = current
            self.changed_at = now
            reasons.append('sampling gap; dwell restarted')

        if busy_cores is None:
            busy_cores = 1 if (core or 0) >= 60 else 0

        # Scale single-core peak so 100% single-thread work reaches Standard/Performance cleanly
        # while multi-core/GPU saturation drives Extreme on AC.
        demand = max(cpu, (core or 0) * 0.50, gpu or 0)
        alpha = 1 if self.ema is None else 1 - math.exp(-dt / p.smooth_seconds)
        self.ema = demand if self.ema is None else self.ema + alpha * (demand - self.ema)
        self.last_time = now

        if temperature is not None:
            if temperature >= p.thermal_limit:
                self.thermal_guard = True
            elif temperature <= p.thermal_limit - 5:
                self.thermal_guard = False

            if temperature >= p.thermal_standard_bal_limit:
                self.thermal_standard_bal = True
            elif temperature <= p.thermal_standard_bal_limit - 5:
                self.thermal_standard_bal = False

            if temperature >= p.thermal_extreme_limit:
                self.thermal_extreme_capped = True
            elif temperature <= p.thermal_extreme_limit - 5:
                self.thermal_extreme_capped = False

        guard = self.thermal_guard
        low_battery = not on_ac and battery is not None and battery <= p.battery_floor
        battery_allows_perf = on_ac or battery is None or battery > p.battery_perf_floor
        is_background_only = (nice_share >= 0.65 and cpu < 65)

        if mode == 'focus':
            heavy_cond = (self.ema >= 55 or busy_cores >= 3 or (gpu or 0) >= 55 or
                          ((cpu_pressure or 0) >= 8 and (cpu >= 25 or (core or 0) >= 75)))
            heavy_delay = max(2, p.heavy_delay - 2)
        else:
            heavy_cond = (self.ema >= 65 or busy_cores >= 4 or (gpu or 0) >= 65 or
                          ((cpu_pressure or 0) >= 10 and (cpu >= 30 or (core or 0) >= 85)))
            heavy_delay = p.heavy_delay

        medium_cond = (busy_cores >= 2 or (core or 0) >= 80 or cpu >= 32 or self.ema >= 32 or (gpu or 0) >= 45)
        burst_cond = (demand >= 35 or cpu >= 18 or self.ema >= 22 or
                      (cpu_pressure or 0) >= 3 or (pressure or 0) >= 5 or
                      (io_pressure or 0) >= 10 or iowait >= 15)
        light_cond = (cpu >= 13 or (gpu or 0) >= 18 or (core or 0) >= 40)

        if guard or low_battery:
            target = ('quiet', 'power-saver')
            reasons.append('critical thermal emergency (>=96C)' if guard else 'battery reserve')
            delay = 0
        elif mode == 'silent':
            if heavy_cond or medium_cond:
                target = ('quiet', 'performance')
                reasons.append('silent mode cap (Quiet 100%)')
                delay = p.medium_delay
            elif burst_cond or light_cond:
                target = ('quiet', 'balanced')
                reasons.append('silent mode balanced (Quiet 75%)')
                delay = p.burst_delay
            else:
                target = ('quiet', 'power-saver')
                reasons.append('silent mode idle (Quiet 50%)')
                delay = p.quiet_delay
        elif is_background_only and (burst_cond or medium_cond or heavy_cond):
            target = ('standard', 'balanced')
            reasons.append('background nice>=10 workload; capped at Standard Balanced')
            delay = p.burst_delay
        elif heavy_cond:
            if on_ac and not self.thermal_extreme_capped and temperature is not None:
                target = ('extreme', 'performance')
                reasons.append('sustained multi-core/GPU heavy demand on AC')
            elif battery_allows_perf and not self.thermal_standard_bal:
                target = ('standard', 'performance')
                if temperature is None:
                    reasons.append('temperature unavailable; capped at Standard Perf')
                elif self.thermal_extreme_capped:
                    reasons.append('sustained demand; thermal cap at Standard Perf (>=90C)')
                else:
                    reasons.append('heavy demand on battery (>30%); Standard Perf')
            else:
                target = ('standard', 'balanced')
                reasons.append('elevated thermal cap (>=93C)' if self.thermal_standard_bal else 'battery conservation cap')
            delay = heavy_delay
        elif medium_cond:
            if battery_allows_perf and not self.thermal_standard_bal:
                target = ('standard', 'performance')
                reasons.append('elevated thermal cap (>=90C)' if self.thermal_extreme_capped else 'active compute / few-core burst')
            else:
                target = ('standard', 'balanced')
                reasons.append('elevated thermal cap (>=93C)' if self.thermal_standard_bal else 'battery conservation cap')
            delay = p.medium_delay
        elif burst_cond:
            target = ('standard', 'balanced')
            reasons.append('measured burst or pressure')
            delay = p.burst_delay
        elif light_cond:
            if mode == 'focus':
                target = ('standard', 'balanced')
                reasons.append('focus mode minimum floor')
                delay = p.burst_delay
            else:
                target = ('quiet', 'balanced')
                reasons.append('light interactive / media activity')
                delay = p.burst_delay if self.recommendation[0] == 'quiet' else p.minimum_duration
        else:
            if mode == 'focus':
                target = ('standard', 'balanced')
                reasons.append('focus mode floor (Standard Balanced)')
                delay = p.burst_delay
            else:
                target = ('quiet', 'power-saver')
                reasons.append('sustained light demand')
                delay = p.quiet_delay

        if (pressure or 0) >= 5:
            reasons.append('memory contention; extra CPU power cannot resolve RAM pressure alone')
        if (io_pressure or 0) >= 10 or iowait >= 15:
            reasons.append('I/O contention; no Extreme boost for disk stalls alone')

        needs_standard_floor = target[0] in ('standard', 'extreme') and not guard and not low_battery
        if needs_standard_floor:
            if self.demand_since is None:
                self.demand_since = now
        else:
            self.demand_since = None

        if target != self.proposal:
            self.proposal, self.proposal_since = target, now

        if self.override and not (guard or low_battery):
            if self.recommendation != current:
                self.changed_at = now
            self.recommendation = current
            scope = 'AC' if self.hold_on_ac is True else ('BAT' if self.hold_on_ac is False else 'manual')
            reasons.append(f'manual hold active ({scope}); auto-releases on power change')
        else:
            tier_rank = {'quiet': 0, 'standard': 1, 'extreme': 2}
            prof_rank = {'power-saver': 0, 'balanced': 1, 'performance': 2}
            upgrading = (tier_rank[target[0]], prof_rank[target[1]]) > (
                tier_rank[self.recommendation[0]], prof_rank[self.recommendation[1]]
            )

            if (needs_standard_floor and self.recommendation[0] == 'quiet' and
                    now - self.demand_since >= p.burst_delay):
                self.recommendation, self.changed_at = ('standard', 'balanced'), now

            if (target != self.recommendation and now - self.proposal_since >= delay and
                    (guard or low_battery or upgrading or now - self.changed_at >= p.minimum_duration)):
                self.recommendation, self.changed_at = target, now

        if self.override and (guard or low_battery):
            reasons.append('manual hold retained; protective advisory only')

        return {
            'schema': 1,
            'mode': 'advisory',
            'flow_mode': mode,
            'time': now,
            'current': dict(zip(('tier', 'profile'), current)),
            'recommended': dict(zip(('tier', 'profile'), self.recommendation)),
            'candidate': dict(zip(('tier', 'profile'), target)),
            'smoothed_demand': round(self.ema, 2),
            'busy_cores': int(busy_cores),
            'task_class': task_class or ('background' if is_background_only else 'measured'),
            'manual_override': self.override,
            'hold_on_ac': self.hold_on_ac,
            'reasons': reasons,
            'applied': False,
        }
