#!/usr/bin/env python3
"""Measured task-aware demand sampling; --auto delegates verified changes to existing owner."""
import argparse
import json
import os
from pathlib import Path
import time
from policy import Engine, Policy, MODES
from control import Actuator, compute_target_watts, request


COMPUTE_HINTS = (
    'gcc', 'g++', 'cc1', 'cc1plus', 'clang', 'rustc', 'cargo', 'cmake', 'ninja', 'make',
    'ld', 'lld', 'mold', 'go', 'javac', 'gradle', 'mvn', 'vite', 'webpack', 'esbuild',
    'tsc', 'python', 'python3', 'pytest', 'ffmpeg', 'blender', 'handbrake', 'wine',
    'proton', 'gamescope', 'obs', 'kdenlive', 'magick', 'v8', 'ollama', 'llama'
)


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
            v = [int(x) for x in parts[1:9]]
            idle_only = v[3]
            iowait = v[4] if len(v) > 4 else 0
            result[parts[0]] = (sum(v), idle_only, iowait)
    return result


def scan_tasks(previous_procs):
    """Bounded single-pass /proc/<pid>/stat scan for nice>=10 vs foreground compute share."""
    current = {}
    total_dticks = 0
    nice_dticks = 0
    fg_by_comm = {}
    try:
        with os.scandir('/proc') as entries:
            for entry in entries:
                if not entry.name.isdigit():
                    continue
                try:
                    with open(f'/proc/{entry.name}/stat', 'r') as f:
                        raw = f.read()
                    lpar = raw.find('(')
                    rpar = raw.rfind(')')
                    if lpar < 0 or rpar <= lpar:
                        continue
                    comm = raw[lpar + 1:rpar]
                    rest = raw[rpar + 2:].split()
                    if len(rest) < 20:
                        continue
                    utime = int(rest[11])
                    stime = int(rest[12])
                    nice = int(rest[16])
                    starttime = int(rest[19])
                    key = (entry.name, starttime)
                    ticks = utime + stime
                    current[key] = (ticks, nice, comm)
                    prev = previous_procs.get(key)
                    if prev is not None:
                        dticks = ticks - prev[0]
                        if dticks > 0:
                            total_dticks += dticks
                            if nice >= 10:
                                nice_dticks += dticks
                            else:
                                fg_by_comm[comm] = fg_by_comm.get(comm, 0) + dticks
                except OSError:
                    continue
    except OSError:
        return current, {'nice_share': 0.0, 'top_comm': ''}

    nice_share = (nice_dticks / total_dticks) if total_dticks > 0 else 0.0
    top_comm = max(fg_by_comm.items(), key=lambda kv: kv[1])[0] if fg_by_comm else ''
    return current, {'nice_share': round(nice_share, 3), 'top_comm': top_comm}


def classify_task(cpu, busiest_core, busy_cores, gpu, io_pressure, iowait, nice_share, top_comm):
    if nice_share >= 0.65 and (cpu or 0) < 65:
        return 'background'
    if (io_pressure or 0) >= 10 and (cpu or 0) < 25 and iowait >= 10:
        return 'io_bound'
    if (gpu or 0) >= 50 and (cpu or 0) < 40:
        return 'gpu_compute'
    low_comm = (top_comm or '').lower()
    if busy_cores >= 4 or (cpu or 0) >= 55:
        if any(h in low_comm for h in COMPUTE_HINTS):
            return 'heavy_compile'
        return 'heavy_compute'
    if busy_cores >= 2 or (cpu or 0) >= 30 or (busiest_core or 0) >= 80:
        if any(h in low_comm for h in COMPUTE_HINTS):
            return 'compile_burst'
        return 'active_compute'
    if (cpu or 0) >= 13 or (busiest_core or 0) >= 35 or (gpu or 0) >= 18:
        return 'interactive'
    return 'idle'


def sample(previous, previous_procs=None, mode='adaptive'):
    counters = cpu_counters()
    usage = {}
    iowait_pct = 0.0
    for key, (total, idle_only, iowait) in counters.items():
        if key in previous and total > previous[key][0]:
            delta = total - previous[key][0]
            prev_total, prev_idle, prev_iowait = previous[key]
            idle_total = idle_only + iowait
            prev_idle_total = prev_idle + prev_iowait
            usage[key] = max(0.0, min(100.0, 100.0 * (delta - (idle_total - prev_idle_total)) / delta))
            if key == 'cpu':
                iowait_pct = max(0.0, min(100.0, 100.0 * (iowait - prev_iowait) / delta))

    procs, proc_info = scan_tasks(previous_procs or {})

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
            'backend': 'powerprofilesctl',
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

    gpu_vals = [read(p) for p in Path('/sys/class/drm').glob('card*/device/gpu_busy_percent')]
    gpu = max((float(v) for v in gpu_vals if v is not None), default=None)

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

    core_vals = [v for k, v in usage.items() if k != 'cpu']
    cpu = usage.get('cpu')
    busiest_core = max(core_vals, default=None)
    busy_cores = sum(1 for v in core_vals if v >= 60.0)
    io_p = pressure('io')
    cpu_p = pressure('cpu')
    mem_p = pressure('memory')
    task_class = classify_task(cpu, busiest_core, busy_cores, gpu, io_p, iowait_pct, proc_info['nice_share'], proc_info['top_comm'])
    tier = status.get('tier')
    profile = status.get('profile')
    on_ac = status.get('on_ac')
    target_watts = status.get('target_w') or compute_target_watts(tier, profile, on_ac)

    measured = {
        'time': time.monotonic(),
        'cpu': cpu,
        'busiest_core': busiest_core,
        'busy_cores': busy_cores,
        'gpu': gpu,
        'temperature': max(temperatures, default=None),
        'battery': min(battery, default=None),
        'memory_pressure': mem_p,
        'cpu_pressure': cpu_p,
        'io_pressure': io_p,
        'iowait': round(iowait_pct, 2),
        'nice_share': proc_info['nice_share'],
        'top_comm': proc_info['top_comm'],
        'task_class': task_class,
        'mode': mode,
        'on_ac': on_ac,
        'tier': tier,
        'profile': profile,
        'target_watts': target_watts,
    }
    return counters, procs, measured


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--replay', type=Path, help='NDJSON samples; no hardware access')
    parser.add_argument('--config', type=Path, help='JSON policy thresholds; no executable rules')
    parser.add_argument('--auto', action='store_true', help='Apply verified recommendations through the existing power owner')
    parser.add_argument('--hold', action='store_true', help='Preserve an existing manual hold until explicitly resumed or power change')
    parser.add_argument('--hold-on-ac', choices=('none', 'ac', 'bat'), default='none', help='Scope preserved hold to AC or Battery')
    parser.add_argument('--mode', choices=MODES, default='adaptive', help='Flow operating mode')
    parser.add_argument('--continuous', action='store_true', help='Continuous monitoring until interrupted')
    parser.add_argument('--samples', type=int, default=3)
    parser.add_argument('--interval', type=float, default=5)
    args = parser.parse_args()

    engine = Engine(Policy(**json.loads(args.config.read_text())) if args.config else None, mode=args.mode)
    if args.auto and (not args.continuous or args.replay):
        parser.error('--auto requires live continuous mode')

    if args.hold_on_ac == 'ac':
        engine.override = True
        engine.hold_on_ac = True
    elif args.hold_on_ac == 'bat':
        engine.override = True
        engine.hold_on_ac = False
    elif args.hold:
        engine.override = True
        engine.hold_on_ac = None

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
        procs, _ = scan_tasks({})
        while True:
            time.sleep(args.interval)
            try:
                counters, procs, measured = sample(counters, procs, mode=args.mode)
                decision = engine.update(measured)
                if actuator:
                    decision = actuator.apply(engine, decision, measured['time'])
                print(json.dumps({'sample': measured, 'decision': decision}), flush=True)
            except (OSError, ValueError):
                print(json.dumps({'error': 'Telemetry unavailable; automatic changes suspended'}), flush=True)

    if not 1 <= args.samples <= 120 or not 1 <= args.interval <= min(60, engine.policy.maximum_gap):
        parser.error('Use 1..120 samples, interval 1..60s within policy maximum_gap')
    counters = cpu_counters()
    procs, _ = scan_tasks({})
    for _ in range(args.samples):
        time.sleep(args.interval)
        counters, procs, measured = sample(counters, procs, mode=args.mode)
        print(json.dumps({'sample': measured, 'decision': engine.update(measured)}), flush=True)


if __name__ == '__main__':
    main()
