"""Single Flow actuator, using the existing Ryzen daemon; no sysfs writes."""
import json
import socket
import subprocess

TIERS = ('quiet', 'standard', 'extreme')
PROFILES = ('power-saver', 'balanced', 'performance')


def request(command):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(5)
        connection.connect('/run/ryzen-power.sock')
        connection.sendall(command.encode('ascii'))
        raw = b''
        while len(raw) <= 16384:
            block = connection.recv(4096)
            if not block:
                break
            raw += block
        if len(raw) > 16384:
            raise ValueError('Power owner response too large')
        status = json.loads(raw)
        if status.get('status') != 'ok':
            raise ValueError('Power owner rejected request')
        return status


def state(status):
    value = status.get('tier'), status.get('profile')
    if value[0] not in TIERS or value[1] not in PROFILES:
        raise ValueError('Power owner state unavailable')
    return value


class Actuator:
    def __init__(self, send=request, profile_reader=None):
        self.send = send
        self.profile_reader = profile_reader or self.read_profile
        self.retry_after = 0

    @staticmethod
    def read_profile():
        return subprocess.check_output(['powerprofilesctl', 'get'], text=True, timeout=3).strip()

    def apply(self, engine, decision, now):
        current = tuple(decision['current'][k] for k in ('tier', 'profile'))
        target = tuple(decision['recommended'][k] for k in ('tier', 'profile'))
        decision.update(mode='automatic', applied=False)
        if decision['manual_override'] or current == target or now < self.retry_after:
            return decision
        if target[0] not in TIERS or target[1] not in PROFILES:
            raise ValueError('Invalid recommendation')
        try:
            observed = state(self.send('STATUS'))
            if observed != current or self.profile_reader() != current[1]:
                decision['reasons'].append('external change before apply; wait for next sample')
                return decision
            # Serial, verified steps let the policy distinguish its own changes
            # from the user's. Stop on partial failure or an unexpected state.
            for index, (command, wanted) in enumerate((('SET_TIER', target[0]), ('SET_PROFILE', target[1]))):
                if observed[index] == wanted:
                    continue
                latest = self.send('STATUS')
                if (state(latest) != observed or self.profile_reader() != observed[1] or
                        (target[0] == 'extreme' and latest.get('on_ac') is not True)):
                    decision['reasons'].append('state/source changed during apply; user state preserved')
                    return decision
                self.send(command + ':' + wanted)
                expected = list(observed)
                expected[index] = wanted
                actual = state(self.send('STATUS'))
                if actual != tuple(expected) or self.profile_reader() != actual[1]:
                    raise ValueError('Power setting read-back mismatch')
                engine.acknowledge_applied(*actual)
                observed = actual
            decision['applied'] = observed == target
            decision['verified_current'] = dict(zip(('tier', 'profile'), observed))
        except (OSError, ValueError, subprocess.SubprocessError):
            self.retry_after = now + 10
            decision['apply_error'] = 'Power change failed verification; retry delayed'
        return decision
