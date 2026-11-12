import importlib.util
from pathlib import Path
import sys
import unittest

path = Path(__file__).resolve().parents[1] / 'policy.py'
spec = importlib.util.spec_from_file_location('flow_policy', path)
policy = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = policy
spec.loader.exec_module(policy)


def sample(time, **changes):
    value = dict(time=time, cpu=10, on_ac=True, tier='standard', profile='balanced', temperature=55, battery=70)
    value.update(changes)
    return value


class PolicyTests(unittest.TestCase):
    def test_quiet_requires_dwell(self):
        e = policy.Engine()
        self.assertEqual(e.update(sample(0))['recommended']['tier'], 'standard')
        for t in range(5, 60, 5):
            self.assertEqual(e.update(sample(t))['recommended']['tier'], 'standard')
        self.assertEqual(e.update(sample(60))['recommended']['tier'], 'quiet')

    def test_heavy_ac_and_battery_limits(self):
        for ac, tier in ((True, 'extreme'), (False, 'standard')):
            e = policy.Engine()
            e.update(sample(0, cpu=90, on_ac=ac))
            for t in range(5, 36, 5):
                result = e.update(sample(t, cpu=90, on_ac=ac))
            self.assertEqual(result['recommended']['tier'], tier)
            self.assertFalse(result['applied'])

    def test_single_core_burst_detected(self):
        e = policy.Engine()
        result = e.update(sample(0, cpu=6, busiest_core=100))
        self.assertEqual(result['candidate']['tier'], 'standard')

    def test_guardrails_bypass_cooldown(self):
        for extra in (dict(temperature=97), dict(on_ac=False, battery=10)):
            e = policy.Engine()
            e.update(sample(0, cpu=90))
            result = e.update(sample(1, cpu=90, **extra))
            self.assertEqual(result['recommended']['tier'], 'quiet')

    def test_external_selection_held_until_release(self):
        e = policy.Engine()
        e.update(sample(0))
        for t in range(10, 141, 5):
            result = e.update(sample(t, tier='extreme', profile='performance'))
            self.assertTrue(result['manual_override'])
            self.assertEqual(result['recommended']['tier'], 'extreme')
        e.release_override()
        self.assertEqual(e.update(sample(150, tier='extreme', profile='performance'))['recommended']['tier'], 'quiet')

    def test_no_oscillation_under_alternating_bursts(self):
        e = policy.Engine()
        values = [e.update(sample(t, cpu=90 if t % 10 == 0 else 5))['recommended']['tier'] for t in range(0, 200, 5)]
        self.assertEqual(set(values), {'standard'})

    def test_invalid_missing_unknown_and_reordered_samples(self):
        for changes in (dict(cpu=float('nan')), dict(cpu=-1), dict(on_ac=None), dict(profile='unknown')):
            with self.assertRaises(ValueError):
                policy.Engine().update(sample(0, **changes))
        e = policy.Engine()
        e.update(sample(10))
        with self.assertRaises(ValueError):
            e.update(sample(9))

    def test_gap_restarts_dwell_without_stale_transition(self):
        e = policy.Engine()
        e.update(sample(0, cpu=90))
        result = e.update(sample(600, cpu=90))
        self.assertEqual(result['recommended']['tier'], 'standard')
        self.assertIn('sampling gap; dwell restarted', result['reasons'])
        for t in range(605, 631, 5):
            result = e.update(sample(t, cpu=90))
        self.assertEqual(result['recommended']['tier'], 'extreme')

    def test_manual_hold_preserved_with_protective_advisory(self):
        e = policy.Engine()
        e.update(sample(0))
        result = e.update(sample(5, tier='extreme', profile='performance', temperature=97))
        self.assertTrue(result['manual_override'])
        self.assertEqual(result['recommended']['tier'], 'quiet')
        self.assertFalse(result['applied'])
        result = e.update(sample(10, tier='extreme', profile='performance', temperature=60))
        self.assertTrue(result['manual_override'])
        self.assertEqual(result['recommended']['tier'], 'extreme')

    def test_hold_clearance_refreshes_minimum_duration(self):
        e = policy.Engine()
        e.update(sample(0))
        e.update(sample(5, tier='extreme', profile='performance', temperature=90))
        e.update(sample(10, tier='extreme', profile='performance'))
        e.release_override()
        # Moderate demand would otherwise immediately exit the held Extreme tier.
        result = e.update(sample(15, tier='extreme', profile='performance', cpu=60))
        self.assertEqual(result['recommended']['tier'], 'extreme')
        for t in range(20, 41, 5):
            result = e.update(sample(t, tier='extreme', profile='performance', cpu=60))
        self.assertEqual(result['recommended']['tier'], 'standard')

    def test_policy_config_validation(self):
        for changes in (dict(smooth_seconds=0), dict(thermal_limit=110), dict(battery_floor=float('nan'))):
            with self.assertRaises(ValueError):
                policy.Policy(**changes)
        self.assertEqual(policy.Policy(quiet_delay=90).quiet_delay, 90)

    def test_application_name_does_not_change_decision(self):
        a, b = policy.Engine(), policy.Engine()
        self.assertEqual(a.update(sample(0, application='Antigravity')), b.update(sample(0, application='Spotify')))


if __name__ == '__main__':
    unittest.main()
