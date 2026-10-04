#!/usr/bin/env python3
"""Pin inherited native evidence; prepare only twelve new public-entry combinations."""
import copy
import hashlib
import json
from pathlib import Path

OWN = Path(__file__).resolve().parent
ROOT = OWN.parents[1]
BASE = ROOT.parent
PRIOR = BASE / 'parallel-repository-inspector-parity-20261004'
PRIOR_OWN = PRIOR / 'tools/parallel-repository-inspector-parity-20261004'

def digest(path):
    data = path.read_bytes()
    return {'path': str(path), 'byteCount': len(data), 'sha256': hashlib.sha256(data).hexdigest()}

def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')

def main():
    manifest = PRIOR / 'docs/migration-runs/AT-RUST-011-parallel-repository-inspector-parity-2026-10-04.sha256'
    pins = []
    for line in manifest.read_text(encoding='utf-8').splitlines():
        expected, relative = line.split('  ', 1)
        path = PRIOR / relative
        assert digest(path)['sha256'] == expected, path
        pins.append(digest(path))
    (OWN / 'inherited').mkdir(exist_ok=True)
    names = ['fixtures/minimal-valid-rust-output.json', 'fixtures/minimal-valid-swift-output.json',
             'fixtures/bounded-sealed-rust-output.json', 'fixtures/bounded-swift-output.json',
             'verification/observe-minimal-valid.receipt.json', 'verification/observe-minimal-valid.log',
             'verification/swift-minimal-valid.receipt.json', 'verification/swift-minimal-valid.log',
             'verification/observe-bounded-sealed.receipt.json', 'verification/observe-bounded-sealed.log',
             'verification/swift-bounded.receipt.json', 'verification/swift-bounded.log',
             'verification/swift-source-identities.json', 'verification/rust-source-identities.json']
    inherited = []
    for name in names:
        path = PRIOR_OWN / name
        target = OWN / 'inherited' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(path.read_bytes())
        inherited.append({**digest(path), 'copy': str(target.relative_to(ROOT))})
    load = lambda n: json.loads((PRIOR_OWN / 'fixtures' / n).read_text(encoding='utf-8'))
    native = load('minimal-valid-rust-output.json') + load('bounded-sealed-rust-output.json')
    swift = {v['id']: v for v in load('minimal-valid-swift-output.json') + load('bounded-swift-output.json')}
    ids = ['legacy-process-measure-single', 'cpu-counter-predecessor-nil-duration',
           'cpu-counter-left-bound-instant', 'native-process-counter-nil-duration',
           'native-process-counter-nullable-metadata', 'merged-physical-table-rowid-collision']
    cases, vectors, inspector = [], [], []
    for identifier in ids:
        v = next(v for v in native if v['id'] == identifier)
        assert v['repositoryPage'] == swift[identifier]['repositoryPage']
        q = v['actualQuery']
        source = ({'cpuCounter': {'filterID': q['filterID'], 'cpu': q['cpu']}}
                  if q['scope'] == 'cpu' else
                  {'processCounter': {'filterID': q['filterID'], 'processKey': {'ipid': q['processKey']}}})
        page = copy.deepcopy(v['repositoryPage'])
        page['dataQuality'] = v['repositoryQuality']
        cases.append({'id': identifier, 'origin': 'inherited-actual-Rust-and-Swift-repository-DTO',
                      'source': source, 'range': q['range'], 'limit': q['limit'], 'page': page})
        vectors.append({'name': identifier, 'source': source, 'range': q['range'],
                        'showsNestedDepth': False, 'cpu': [], 'threadStates': [], 'slices': [],
                        'counters': page['items'], 'frames': [], 'truncated': page['truncated'],
                        'capabilityAvailable': page['capabilityAvailable']})
        inspector.append({'id': identifier, 'facts': swift[identifier]['facts']})
    def derive(index, identifier, mutation):
        c = copy.deepcopy(cases[index]); c['id'] = identifier
        c['origin'] = 'explicit-derived-control'; c['parent'] = cases[index]['id']
        mutation(c); cases.append(c)
    def table(c, table): c['page']['items'][0]['samples'][0]['key']['table'] = table
    derive(1, 'cpu-wrong-process-measure', lambda c: table(c, 'process_measure'))
    derive(3, 'process-wrong-callstack', lambda c: table(c, 'callstack'))
    derive(3, 'process-filter-mismatch', lambda c: c['source']['processCounter'].update(filterID=999))
    derive(3, 'process-ipid-mismatch-same-pid', lambda c: c['source']['processCounter'].update(processKey={'ipid': 2}))
    derive(3, 'native-truncated-retains-machine-quality', lambda c: c['page'].update(truncated=True))
    derive(1, 'cpu-total-sample-budget-two-for-three', lambda c: c.update(limit=2))
    assert len(cases) == 12 and sum(len(s['samples']) for c in cases[:6] for s in c['page']['items']) == 11
    write(OWN / 'fixtures/cases.json', cases)
    write(OWN / 'fixtures/swift-vectors.json', vectors)
    write(OWN / 'fixtures/inherited-inspector-facts.json', inspector)
    write(OWN / 'receipts/inheritance.json', {'priorManifest': digest(manifest), 'allFrozenPriorChecksums': pins,
          'selectedCopies': inherited, 'actualDTOGroups': 6, 'actualSamples': 11,
          'newFunctionCombinations': 12, 'derivedControls': 6, 'reranRepositoryOrParser': False})
    print('Pinned inherited frozen evidence; prepared 12 cases / 6 actual DTO groups / 11 actual samples')

if __name__ == '__main__': main()
