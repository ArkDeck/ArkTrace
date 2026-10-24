import unittest
from overlap import classify


def row(engine, start, end, observed, alive=None):
    polls = [] if alive is None else [dict(startNs=alive, endNs=alive + 1, state=2, terminal=False)]
    polls.append(dict(startNs=observed - 1, endNs=observed, state=3, terminal=True))
    return dict(engine=engine, session=engine + 2, request=engine + 4,
                submitStartNs=start, submitEndNs=end, terminalObservedNs=observed, polls=polls)


class OverlapTests(unittest.TestCase):
    def test_delayed_terminal_observation_is_not_outstanding_proof(self):
        result = classify([row(1, 10, 20, 100), row(2, 30, 40, 110)], {1, 2})
        self.assertTrue(result['observedSubmitToTerminalIntervalsOverlap'])
        self.assertFalse(result['knownOutstandingIntervalsOverlap'])
        self.assertFalse(result['submitCallIntervalsOverlap'])

    def test_nonterminal_polls_prove_only_outstanding_overlap(self):
        result = classify([row(1, 10, 20, 100, 80), row(2, 15, 30, 110, 90)], {1, 2})
        self.assertTrue(result['knownOutstandingIntervalsOverlap'])
        self.assertTrue(result['submitCallIntervalsOverlap'])
        self.assertFalse(result['publicationCriticalSectionRaceProven'])

    def test_sequential_requests_and_touching_endpoints_do_not_overlap(self):
        result = classify([row(1, 10, 20, 40, 30), row(2, 40, 50, 80, 70)], {1, 2})
        self.assertFalse(result['knownOutstandingIntervalsOverlap'])
        self.assertFalse(result['observedSubmitToTerminalIntervalsOverlap'])


if __name__ == '__main__':
    unittest.main()
