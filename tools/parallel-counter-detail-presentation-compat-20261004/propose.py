#!/usr/bin/env python3
"""Create reviewable main-owned hunks without modifying frozen producers."""
import difflib
from prepare import OWN, ROOT, digest, write

def main():
    edits = [
        ('rust/crates/arktrace-viewer/src/detail.rs',
         '''                    items.push(input(
                        sample.key,
                        expected.1,''',
         '''                    if sample.key.table != expected.1
                        && !(series.scope == CounterScope::Process
                            && sample.key.table == EventTable::Measure)
                    {
                        return Err(ViewerError::InvalidEvidence);
                    }
                    items.push(input(
                        sample.key,
                        sample.key.table,'''),
        ('rust/crates/arktrace-viewer/src/presentation.rs',
         '''                builder.detail(
                    primitive(
                        sample.key,
                        table,''',
         '''                if sample.key.table != table
                    && !(series.scope == CounterScope::Process
                        && sample.key.table == EventTable::Measure)
                {
                    return Err(ViewerError::InvalidEvidence);
                }
                builder.detail(
                    primitive(
                        sample.key,
                        sample.key.table,''')]
    diff, pins = [], []
    for path, old, new in edits:
        p = ROOT / path; original = p.read_text(encoding='utf-8')
        assert original.count(old) == 1, path
        proposal = original.replace(old, new)
        diff.extend(difflib.unified_diff(original.splitlines(True), proposal.splitlines(True), fromfile='a/' + path, tofile='b/' + path))
        pins.append(digest(p))
    (OWN / 'main-counter-guard-proposal.patch').write_text(''.join(diff), encoding='utf-8')
    write(OWN / 'receipts/proposal-source-pins.json', {'files': pins, 'productionFilesModified': False,
           'proposalAppliedOrCompiled': False, 'onlyPolicyChange': 'process Counter admits actual Measure as well as ProcessMeasure; CPU remains Measure only; original key preserved'})
    print('Created two main-owned guard hunks; frozen producers unchanged')

if __name__ == '__main__': main()
