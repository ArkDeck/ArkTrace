#!/usr/bin/env python3
"""Compare actual outputs; do not implement time, key, label or color formulas."""
import json
from prepare import OWN, ROOT, digest, write

def main():
    read = lambda path: json.loads(path.read_text(encoding='utf-8'))
    cases = read(OWN / 'fixtures/cases.json')
    rust = read(OWN / 'receipts/rust-observations.json')
    swift = read(OWN / 'receipts/swift-canonical.json')
    inspector = read(OWN / 'fixtures/inherited-inspector-facts.json')
    assert len(cases) == len(rust) == 12 and len(swift) == len(inspector) == 6
    by_r = {v['id']: v for v in rust}
    by_s = {v['name']: v for v in swift}
    by_i = {v['id']: v for v in inspector}
    failures, comparison, passed_samples = [], [], 0
    for c in cases[:6]:
        r, s, i = by_r[c['id']], by_s[c['id']], by_i[c['id']]
        assert len(s['facts']) == len(i['facts'])
        # Actual inspector and new actual primitive may differ in category;
        # primitive has counter styling, Inspector classifies cpu/process.
        for p, f in zip(s['facts'], i['facts']):
            for key in ['key', 'kind', 'range', 'isInstant', 'isOpenEnded']:
                assert p[key] == f[key], (c['id'], key)
            for key in ['processKey', 'threadKey', 'pid', 'tid']:
                assert p['identity'][key] == f[key], (c['id'], key)
        d, p = r['detail'], r['presentation']
        if d['error'] is None:
            assert len(d['items']) == len(s['facts'])
            for a, e in zip(d['items'], s['facts']):
                for ak, ek in [('eventKey', 'key'), ('range', 'range'), ('depth', 'depth'), ('style', 'style'), ('isOpenEnded', 'isOpenEnded')]:
                    assert a[ak] == e[ek], (c['id'], ak)
            for key in ['truncated', 'capabilityAvailable', 'dataQuality']:
                assert d[key] == c['page'][key], (c['id'], key)
        if p['error'] is None:
            # Python's JSON comparison treats CGColor 1/1.0 identically;
            # the compiled Rust test restricts this only to the 4 RGBA slots.
            assert p['facts'] == s['facts'], c['id']
            passed_samples += len(p['facts'])
        blocked = [name for name, value in [('map_detail_page', d), ('present', p)] if value['error'] is not None]
        if blocked: failures.append({'id': c['id'], 'functions': blocked, 'errors': [d['error'], p['error']], 'canonicalSamples': len(s['facts'])})
        comparison.append({'id': c['id'], 'origin': c['origin'], 'detailError': d['error'], 'presentationError': p['error'],
                           'actualSwiftSamples': len(s['facts']), 'blockedFunctions': blocked})
    assert [v['id'] for v in failures] == ['legacy-process-measure-single', 'merged-physical-table-rowid-collision']
    assert all(v['errors'] == ['InvalidEvidence', 'InvalidEvidence'] for v in failures)
    for c in cases[6:]:
        r = by_r[c['id']]
        d, p = r['detail']['error'], r['presentation']['error']
        if c['id'] in ['cpu-wrong-process-measure', 'process-wrong-callstack']: assert d == p == 'InvalidEvidence'
        elif c['id'] in ['process-filter-mismatch', 'process-ipid-mismatch-same-pid']: assert d == 'InvalidEvidence' and p is None
        elif c['id'] == 'native-truncated-retains-machine-quality':
            assert d is None and p is None
            assert r['detail']['truncated'] and r['detail']['dataQuality'] == c['page']['dataQuality']
        else: assert d == p == 'InputBudgetExceeded'
        comparison.append({'id': c['id'], 'origin': c['origin'], 'detailError': d, 'presentationError': p, 'controlContractPassed': True})
    out = {'newCombinations': 12, 'actualDTOGroups': 6, 'actualSwiftSamples': 11, 'matchedAcceptedActualGroups': 4,
           'matchedAcceptedActualSamples': passed_samples, 'legalRejectedGroups': 2, 'legalRejectedFunctionCalls': 4,
           'derivedControlsPassed': 6, 'failures': failures, 'cases': comparison,
           'comparison': {'detailFields': ['eventKey', 'range', 'depth', 'style', 'isOpenEnded'],
             'presentationFieldCount': len(swift[0]['facts'][0]), 'presentationFields': sorted(swift[0]['facts'][0]),
             'pageFields': ['capabilityAvailable', 'truncated', 'dataQuality'],
             'integerFacts': 'exact JSON integer equality in Rust; only declared CGColor RGBA uses exact f64 comparison',
             'copiedExpectedAlgorithm': False},
           'publicEntryLimitation': 'present consumes raw CounterSeries and cannot consume DetailInput or retain page quality/truncation',
           'formalAT_RUST_011_orMacOSAcceptance': False}
    assert passed_samples == 8
    write(OWN / 'receipts/comparison.json', out)
    print(json.dumps({k: v for k, v in out.items() if k not in ['cases', 'comparison']}, ensure_ascii=False))

if __name__ == '__main__': main()
