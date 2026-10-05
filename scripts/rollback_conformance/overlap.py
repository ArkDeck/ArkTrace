"""Conservative classifications of actual public-call monotonic observations."""


def intersects(left, right):
    return max(left[0], right[0]) < min(left[1], right[1])


def classify(rows, nonterminal_states):
    assert len(rows) == 2
    for row in rows:
        assert 0 < row['submitStartNs'] <= row['submitEndNs'] <= row['terminalObservedNs']
        assert row['engine'] and row['session'] and row['request']
        assert row['polls'] and row['polls'][-1]['terminal']
        assert all(row['submitEndNs'] <= p['startNs'] <= p['endNs'] <= row['terminalObservedNs']
                   for p in row['polls'])
    calls = [(r['submitStartNs'], r['submitEndNs']) for r in rows]
    # A returned handle remained outstanding through a nonterminal public poll.
    # Observing terminal late alone supplies no such proof.
    alive = [(r['submitEndNs'], max([r['submitEndNs']] +
             [p['startNs'] for p in r['polls'] if p['state'] in nonterminal_states])) for r in rows]
    return dict(submitCallIntervalsOverlap=intersects(*calls),
                knownOutstandingIntervalsOverlap=intersects(*alive),
                knownOutstandingIntervalsNs=alive,
                observedSubmitToTerminalIntervalsOverlap=intersects(*[
                    (r['submitEndNs'], r['terminalObservedNs']) for r in rows]),
                publicationCriticalSectionRaceProven=False)
