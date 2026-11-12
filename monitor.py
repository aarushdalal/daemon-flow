#!/usr/bin/env python3
"""Measured demand sampling; --auto delegates verified changes to existing owner."""
import argparse
import json
from pathlib import Path
import time
from policy import Engine, Policy
from control import Actuator, request


def read(path):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return None


def pressure(resource):
    raw = read('/proc/pressure/' + resource)
    if raw:
        for line in raw.splitlines():
            fields = line.split()
            if fields and fields[0] == 'some':
                for field in fields[1:]:
                    if field.startswith('avg10='):
                        return float(field.split('=', 1)[1])
    return None


def cpu_counters():
    result = {}
    for line in Path('/proc/stat').read_text().splitlines():
        parts = line.split()
        if parts and parts[0].startswith('cpu'):
            # guest times are already counted in user/nice.
            v = [int(x) for x in parts[1:9]]
            result[parts[0]] = (sum(v), v[3] + (v[4] if len(v) > 4 else 0))
    return result


def sample(previous):
    counters = cpu_counters()
    usage = {}
    for key, (total, idle) in counters.items():
        if key in previous and total > previous[key][0]:
            delta = total - previous[key][0]
            usage[key] = max(0, min(100, 100 * (delta - idle + previous[key][1]) / delta))
    try:
        status = request('STATUS')
    except (OSError, ValueError):
        ppd_profile = Actuator.read_profile()
        tier_map = {'power-saver': 'quiet', 'balanced': 'standard', 'performance': 'extreme'}
        ac_online = [read(p / 'online') for p in Path('/sys/class/power_supply').glob('*') if read(p / 'type') == 'Mains']
        on_ac = any(x == '1' for x in ac_online) if ac_online else True
        status = {
            'status': 'ok',
            'tier': tier_map.get(ppd_profile, 'standard'),
            'profile': ppd_profile,
            'on_ac': on_ac,
            'backend': 'powerprofilesctl'
        }
    KNOWN_DRIVERS = {'k10temp', 'zenpower', 'coretemp', 'cpu_thermal', 'soc_thermal'}
    temperatures = []
    for hw in Path('/sys/class/hwmon').glob('hwmon*'):
        if read(hw / 'name') in KNOWN_DRIVERS:
            for path in hw.glob('temp*_input'):
                value = read(path)
                if value:
                    temperatures.append(float(value) / 1000)
    if not temperatures:
        for zone in Path('/sys/class/thermal').glob('thermal_zone*'):
            z_type = read(zone / 'type')
            if z_type and any(k in z_type.lower() for k in ('x86_pkg_temp', 'cpu', 'acpitz')):
                val = read(zone / 'temp')
                if val:
                    temperatures.append(float(val) / 1000)
    gpu = [read(p) for p in Path('/sys/class/drm').glob('card*/device/gpu_busy_percent')]
    battery = []
    for p in Path('/sys/class/power_supply').glob('*'):
        if read(p / 'type') == 'Battery':
            if read(p / 'scope') == 'Device':
                continue
            cap = read(p / 'capacity')
            if cap is not None:
                try:
                    battery.append(float(cap))
                except ValueError:
                    pass
    if not battery:
        for p in Path('/sys/class/power_supply').glob('BAT*'):
            cap = read(p / 'capacity')
            if cap is not None:
                try:
                    battery.append(float(cap))
                except ValueError:
                    pass
    return counters, {'time': time.monotonic(), 'cpu': usage.get('cpu'),
        'busiest_core': max((v for k, v in usage.items() if k != 'cpu'), default=None),
        'gpu': max((float(v) for v in gpu if v is not None), default=None),
        'temperature': max(temperatures, default=None),
        'battery': min(battery, default=None),
        'memory_pressure': pressure('memory'), 'cpu_pressure': pressure('cpu'), 'io_pressure': pressure('io'), 'on_ac': status.get('on_ac'),
        'tier': status.get('tier'), 'profile': status.get('profile')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--replay', type=Path, help='NDJSON samples; no hardware access')
    parser.add_argument('--config', type=Path, help='JSON policy thresholds; no executable rules')
    parser.add_argument('--auto', action='store_true', help='Apply verified recommendations through the existing power owner')
    parser.add_argument('--hold', action='store_true', help='Preserve an existing manual hold until explicitly resumed')
    parser.add_argument('--continuous', action='store_true', help='Continuous monitoring until interrupted')
    parser.add_argument('--samples', type=int, default=3)
    parser.add_argument('--interval', type=float, default=5)
    args = parser.parse_args()
    engine = Engine(Policy(**json.loads(args.config.read_text())) if args.config else None)
    if args.auto and (not args.continuous or args.replay):
        parser.error('--auto requires live continuous mode')
    engine.override = args.hold
    actuator = Actuator() if args.auto else None
    if args.replay:
        with args.replay.open() as trace:
            for line in trace:
                if line.strip():
                    print(json.dumps(engine.update(json.loads(line))))
        return
    if args.continuous:
        if not 1 <= args.interval <= min(60, engine.policy.maximum_gap):
            parser.error('Interval must be 1..60s within policy maximum_gap')
        counters = cpu_counters()
        while True:
            time.sleep(args.interval)
            try:
                counters, measured = sample(counters)
                decision = engine.update(measured)
                if actuator:
                    decision = actuator.apply(engine, decision, measured['time'])
                print(json.dumps({'sample': measured, 'decision': decision}), flush=True)
            except (OSError, ValueError):
                print(json.dumps({'error': 'Telemetry unavailable; automatic changes suspended'}), flush=True)
    if not 1 <= args.samples <= 120 or not 1 <= args.interval <= min(60, engine.policy.maximum_gap):
        parser.error('Use 1..120 samples, interval 1..60s within policy maximum_gap')
    counters = cpu_counters()
    for _ in range(args.samples):
        time.sleep(args.interval)
        counters, measured = sample(counters)
        print(json.dumps({'sample': measured, 'decision': engine.update(measured)}), flush=True)


if __name__ == '__main__':
    main()
