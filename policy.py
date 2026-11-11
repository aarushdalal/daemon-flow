"""Measured system-demand policy; hardware changes belong to the existing owner."""
from dataclasses import dataclass
import math


@dataclass
class Policy:
    smooth_seconds: float = 12
    minimum_duration: float = 30
    quiet_delay: float = 60
    burst_delay: float = 2
    heavy_delay: float = 12
    thermal_limit: float = 80
    maximum_gap: float = 30
    battery_floor: float = 20

    def __post_init__(self):
        limits = {'smooth_seconds': (1, 120), 'minimum_duration': (1, 600),
                  'quiet_delay': (1, 600), 'burst_delay': (1, 60),
                  'heavy_delay': (1, 600), 'thermal_limit': (50, 100),
                  'maximum_gap': (5, 120), 'battery_floor': (5, 50)}
        for key, (low, high) in limits.items():
            value = getattr(self, key)
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or not low <= value <= high:
                raise ValueError('Invalid policy setting: ' + key)


class Engine:
    def __init__(self, policy=None):
        self.policy = policy or Policy()
        self.last_time = None
        self.ema = None
        self.proposal = None
        self.proposal_since = None
        self.recommendation = None
        self.changed_at = None
        self.observed = None
        self.override = False
        self.demand_since = None
        self.thermal_guard = False

    def acknowledge_applied(self, tier, profile):
        """Only the actuator may acknowledge a read-back verified own transition."""
        if tier not in ("quiet", "standard", "extreme") or profile not in ("power-saver", "balanced", "performance"):
            raise ValueError("Invalid applied state")
        self.observed = (tier, profile)

    def release_override(self):
        self.override = False

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
        gpu = number('gpu', 0, 100)
        temperature = number('temperature', -20, 150)
        battery = number('battery', 0, 100)
        pressure = number('memory_pressure', 0, 100)
        cpu_pressure = number('cpu_pressure', 0, 100)
        io_pressure = number('io_pressure', 0, 100)
        if type(sample.get('on_ac')) is not bool:
            raise ValueError('Power source unknown')
        current = (sample.get('tier'), sample.get('profile'))
        if current[0] not in ('quiet', 'standard', 'extreme') or current[1] not in ('power-saver', 'balanced', 'performance'):
            raise ValueError('Power policy unknown')
        if self.last_time is not None and now <= self.last_time:
            raise ValueError('Samples must have increasing timestamps')
        if self.observed is not None and current != self.observed:
            self.override = True  # unacknowledged changes are external; preserve user selection
        self.observed = current
        if self.recommendation is None:
            self.recommendation = current
            self.changed_at = now
        dt = 0 if self.last_time is None else now - self.last_time
        discontinuity = self.last_time is not None and dt > p.maximum_gap
        if discontinuity:
            # Unsampled time is not proof of sustained demand. Preserve manual hold.
            self.ema = None
            self.proposal = None
            self.demand_since = None
            self.recommendation = current
            self.changed_at = now
        # A saturated core matters on a 16-thread CPU even when aggregate demand is low.
        demand = max(cpu, (core or 0) * .6, gpu or 0)
        alpha = 1 if self.ema is None else 1 - math.exp(-dt / p.smooth_seconds)
        self.ema = demand if self.ema is None else self.ema + alpha * (demand - self.ema)
        self.last_time = now
        reasons = ["sampling gap; dwell restarted"] if discontinuity else []
        if temperature is not None:
            if temperature >= p.thermal_limit:
                self.thermal_guard = True
            elif temperature <= p.thermal_limit - 5:
                self.thermal_guard = False
        guard = self.thermal_guard
        low_battery = not sample['on_ac'] and battery is not None and battery <= p.battery_floor
        if guard or low_battery:
            target = ('quiet', 'power-saver')
            reasons.append('thermal guardrail' if guard else 'battery reserve')
            delay = 0
        elif self.ema >= 75 or ((cpu_pressure or 0) >= 15 and (cpu >= 35 or (core or 0) >= 85)):
            target = ('extreme', 'performance') if sample['on_ac'] else ('standard', 'balanced')
            reasons.append('sustained measured demand / CPU contention')
            delay = p.heavy_delay
        elif demand >= 35 or cpu >= 18 or self.ema >= 25 or (cpu_pressure or 0) >= 3 or (pressure or 0) >= 5 or (io_pressure or 0) >= 10:
            target = ('standard', 'balanced')
            reasons.append('measured burst or pressure')
            delay = p.burst_delay
        else:
            target = ('quiet', 'power-saver')
            reasons.append('sustained light demand')
            delay = p.quiet_delay
        if temperature is None and target[0] == 'extreme':
            target = ('standard', 'balanced')
            reasons.append('temperature unavailable; no Extreme escalation')
        if (pressure or 0) >= 5:
            reasons.append('memory contention; extra CPU power cannot resolve RAM pressure alone')
        if (io_pressure or 0) >= 10:
            reasons.append('I/O contention; no Extreme boost for disk stalls alone')
        needs_response = target[0] != 'quiet' and not guard and not low_battery
        if needs_response:
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
            reasons.append('external/manual selection held until release')
        else:
            rank = {'quiet': 0, 'standard': 1, 'extreme': 2}
            upgrading = rank[target[0]] > rank[self.recommendation[0]] or (
                target[0] == self.recommendation[0] and target[1] != 'power-saver' and self.recommendation[1] == 'power-saver')
            # Upshifts do not wait out the downshift cooldown. Under heavy
            # demand first leave Quiet quickly, then verify sustained demand
            # before entering Extreme. A single isolated spike is insufficient.
            if (needs_response and self.recommendation[0] == 'quiet' and
                    now - self.demand_since >= p.burst_delay):
                self.recommendation, self.changed_at = ('standard', 'balanced'), now
            if (target != self.recommendation and now - self.proposal_since >= delay and
                    (guard or low_battery or upgrading or now - self.changed_at >= p.minimum_duration)):
                self.recommendation, self.changed_at = target, now
        if self.override and (guard or low_battery):
            reasons.append('manual hold retained; protective advisory only')
        return {'schema': 1, 'mode': 'advisory', 'time': now,
                'current': dict(zip(('tier', 'profile'), current)),
                'recommended': dict(zip(('tier', 'profile'), self.recommendation)),
                'candidate': dict(zip(('tier', 'profile'), target)),
                'smoothed_demand': round(self.ema, 2), 'manual_override': self.override,
                'reasons': reasons, 'applied': False}
