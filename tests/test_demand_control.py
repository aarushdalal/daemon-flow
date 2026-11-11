"""Regression traces and actuator boundaries; these do not benchmark real apps."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from policy import Engine
from control import Actuator
from monitor import pressure
from unittest.mock import patch


def sample(t, **extra):
    return dict(dict(time=t, cpu=5, busiest_core=10, on_ac=True, tier='quiet',
                     profile='power-saver', temperature=55, battery=70), **extra)


class DemandTests(unittest.TestCase):
    def test_background_single_core_leaves_quiet_in_two_seconds(self):
        e = Engine()
        e.update(sample(0, cpu=7, busiest_core=100))
        d = e.update(sample(2, cpu=7, busiest_core=100))
        self.assertEqual(d['recommended']['tier'], 'standard')

    def test_heavy_load_has_quick_floor_then_extreme_on_ac(self):
        e = Engine()
        e.update(sample(0, cpu=95))
        self.assertEqual(e.update(sample(2, cpu=95))['recommended']['tier'], 'standard')
        self.assertEqual(e.update(sample(12, cpu=95))['recommended']['tier'], 'extreme')

    def test_cpu_contention_matters_below_old_total_usage_threshold(self):
        e = Engine()
        for t in range(0, 14, 2):
            d = e.update(sample(t, cpu=40, cpu_pressure=20))
        self.assertEqual(d['recommended']['tier'], 'extreme')

    def test_io_only_and_memory_contention_do_not_request_extreme(self):
        for extra in ({'io_pressure':80}, {'memory_pressure':40}):
            e = Engine()
            for t in range(0, 100, 2):
                d = e.update(sample(t, **extra))
            self.assertEqual(d['recommended']['tier'], 'standard')

    def test_short_spike_does_not_change_profile(self):
        e = Engine()
        e.update(sample(0))
        e.update(sample(2, busiest_core=100))
        d = e.update(sample(4))
        self.assertEqual(d['recommended']['tier'], 'quiet')

    def test_own_applied_state_does_not_latch_manual_hold(self):
        e = Engine()
        e.update(sample(0))
        e.acknowledge_applied('standard', 'balanced')
        d = e.update(sample(2, tier='standard', profile='balanced', cpu=80))
        self.assertFalse(d['manual_override'])
        d = e.update(sample(4, tier='quiet', profile='power-saver', cpu=80))
        self.assertTrue(d['manual_override'])

    def test_unknown_temperature_cannot_request_extreme(self):
        e = Engine()
        for t in range(0, 100, 2):
            d = e.update(sample(t, cpu=95, temperature=None))
        self.assertEqual(d['recommended']['tier'], 'standard')

    def test_thermal_hysteresis(self):
        e = Engine()
        e.update(sample(0, cpu=95, temperature=81))
        d = e.update(sample(2, cpu=95, temperature=79))
        self.assertEqual(d['candidate']['tier'], 'quiet')
        d = e.update(sample(4, cpu=95, temperature=74))
        self.assertEqual(d['candidate']['tier'], 'extreme')

    def test_pressure_reads_some_not_cpu_full(self):
        with patch('monitor.read', return_value='some avg10=7.25 total=123\nfull avg10=0.00 total=0\n'):
            self.assertEqual(pressure('cpu'), 7.25)


class FakeOwner:
    def __init__(self):
        self.tier, self.profile = 'quiet', 'power-saver'
        self.calls = []
        self.fail = None
        self.lie = False

    def request(self, command):
        self.calls.append(command)
        if command == self.fail:
            raise OSError('fixture failure')
        if command.startswith('SET_') and not self.lie:
            name, value = command.split(':')
            setattr(self, 'tier' if name == 'SET_TIER' else 'profile', value)
        return {'status':'ok', 'tier':self.tier, 'profile':self.profile, 'on_ac':True}


class ActuatorTests(unittest.TestCase):
    def setUp(self):
        self.owner = FakeOwner()
        self.a = Actuator(self.owner.request, lambda: self.owner.profile)
        self.e = Engine()
        self.e.update(sample(0, cpu=50))
        self.d = self.e.update(sample(2, cpu=50))

    def test_verified_apply_and_next_sample_never_false_holds(self):
        d = self.a.apply(self.e, self.d, 2)
        self.assertTrue(d['applied'])
        self.assertEqual(self.owner.calls, ['STATUS','STATUS','SET_TIER:standard','STATUS','STATUS','SET_PROFILE:balanced','STATUS'])
        self.assertFalse(self.e.update(sample(4, cpu=50, tier='standard', profile='balanced'))['manual_override'])

    def test_manual_hold_never_applies_even_thermal_advisory(self):
        self.d['manual_override'] = True
        self.a.apply(self.e, self.d, 2)
        self.assertEqual(self.owner.calls, [])

    def test_external_change_before_apply_is_preserved(self):
        self.owner.tier = 'extreme'
        self.a.apply(self.e, self.d, 2)
        self.assertEqual(self.owner.calls, ['STATUS'])

    def test_false_success_rejected_and_retries_bounded(self):
        self.owner.lie = True
        d = self.a.apply(self.e, self.d, 2)
        self.assertFalse(d['applied'])
        self.assertIn('apply_error', d)
        before = len(self.owner.calls)
        self.a.apply(self.e, self.d, 4)
        self.assertEqual(len(self.owner.calls), before)

    def test_partial_success_acknowledged_without_false_override(self):
        self.owner.fail = 'SET_PROFILE:balanced'
        d = self.a.apply(self.e, self.d, 2)
        self.assertFalse(d['applied'])
        self.assertEqual(self.e.observed, ('standard','power-saver'))
        self.assertFalse(self.e.update(sample(4, tier='standard', cpu=50))['manual_override'])


if __name__ == '__main__':
    unittest.main()
