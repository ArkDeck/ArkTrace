"""Synthetic malformed-wire regressions, never evidence of a native run."""
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import report_checks as checks

TRACE = 'a' * 64
PARSER = 'b' * 64
DOCUMENT = b'{"formatVersion":1,"traceSHA256":"' + TRACE.encode() + b'","flags":[],"marks":[],"favoriteTrackIDs":null}'
DOC_SHA = hashlib.sha256(DOCUMENT).hexdigest()
IDENTITY = checks.Identity(11, 22, 33)


def receipt():
    return dict(formatVersion=1, backupIdentifier=checks.backup_identifier(TRACE, PARSER, DOC_SHA),
                traceSHA256=TRACE, parserKey=PARSER, documentSHA256=DOC_SHA,
                documentByteCount=len(DOCUMENT), flagCount=0, persistentMarkCount=0, favoriteTrackCount=None)


def wire(status='backedUp', value=None):
    body = dict(status=status, receipt=receipt() if value is None and status in ['backedUp', 'alreadyBackedUp'] else value)
    return dict(formatVersion=1, session=22, request=33, body=body)


def raw(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()


class ReportChecks(unittest.TestCase):
    def validate(self, value, identity=IDENTITY, origin=11, trace=TRACE, parser=PARSER):
        return checks.validate_envelope(raw(value), identity, origin, trace, parser)

    def reject(self, value, **kwargs):
        with self.assertRaises(checks.InvalidReport):
            self.validate(value, **kwargs)

    def test_all_closed_statuses_and_receipt_relationship(self):
        for status in checks.STATUSES:
            with self.subTest(status=status):
                self.assertEqual(self.validate(wire(status))['status'], status)
                candidate = wire(status)
                candidate['body']['receipt'] = None if status in ['backedUp', 'alreadyBackedUp'] else receipt()
                self.reject(candidate)
        for status in ['backed_up', 'futureStatus', '/Users/private', None, 1, True]:
            self.reject(wire(status))

    def test_every_closed_key_is_required_and_unknown_paths_rejected(self):
        for location in [[], ['body'], ['body', 'receipt']]:
            original = wire()
            target = original
            for key in location:
                target = target[key]
            for key in list(target):
                candidate = copy.deepcopy(original)
                selected = candidate
                for step in location:
                    selected = selected[step]
                del selected[key]
                with self.subTest(location=location, missing=key):
                    self.reject(candidate)
            for key in ['path', 'engine', 'destination', 'sql', 'future']:
                candidate = copy.deepcopy(original)
                selected = candidate
                for step in location:
                    selected = selected[step]
                selected[key] = '/Users/private/cache'
                self.reject(candidate)

    def test_expected_engine_session_request_and_opening_provenance(self):
        self.reject(wire(), origin=44)
        for identity in [checks.Identity(0, 22, 33), checks.Identity(11, 0, 33), checks.Identity(11, 22, 0),
                         checks.Identity(True, 22, 33), checks.Identity(11, 22, 2**64)]:
            self.reject(wire(), identity=identity)
        for key, value in [('session', 23), ('request', 34), ('session', True), ('request', 0)]:
            candidate = wire()
            candidate[key] = value
            self.reject(candidate)
        self.reject(wire(), trace='c' * 64)
        self.reject(wire(), parser='c' * 64)

    def test_integer_bounds_combined_counts_and_nullable_favorites(self):
        valid = receipt()
        valid.update(documentByteCount=checks.MAX_DOCUMENT_BYTES, flagCount=4095,
                     persistentMarkCount=1, favoriteTrackCount=4096)
        self.validate(wire(value=valid))
        for favorite in [None, 0, 4096]:
            candidate = receipt()
            candidate['favoriteTrackCount'] = favorite
            self.validate(wire(value=candidate))
        cases = {'formatVersion': [0, 2, True, 1.0, '1', None],
                 'documentByteCount': [0, -1, checks.MAX_DOCUMENT_BYTES + 1, True, 1.0, '1'],
                 'flagCount': [-1, 4097, True, 1.0, None],
                 'persistentMarkCount': [-1, 4097, True, 1.0, None],
                 'favoriteTrackCount': [-1, 4097, True, 1.0, '0']}
        for key, values in cases.items():
            for value in values:
                candidate = receipt()
                candidate[key] = value
                with self.subTest(key=key, value=value):
                    self.reject(wire(value=candidate))
        candidate = receipt()
        candidate.update(flagCount=4096, persistentMarkCount=1)
        self.reject(wire(value=candidate))

    def test_lowercase_digests_and_domain_separated_snapshot_identity(self):
        preimage = b'ArkTrace.ViewStateRollback.v1\0' + TRACE.encode() + b'\0' + PARSER.encode() + b'\0' + DOC_SHA.encode() + b'\0'
        self.assertEqual(receipt()['backupIdentifier'], hashlib.sha256(preimage).hexdigest())
        for key in ['traceSHA256', 'parserKey', 'documentSHA256', 'backupIdentifier']:
            for value in ['A' * 64, 'g' * 64, 'a' * 63, 'a' * 65, '/private/tmp/secret', None, 9]:
                candidate = receipt()
                candidate[key] = value
                self.reject(wire(value=candidate))
        for domain in [b'', b'ArkTrace.ViewStateRollback.v2\0']:
            candidate = receipt()
            candidate['backupIdentifier'] = hashlib.sha256(domain + preimage.split(b'\0', 1)[1]).hexdigest()
            self.reject(wire(value=candidate))

    def test_bounded_original_json_duplicates_float_utf8_and_depth(self):
        valid = raw(wire())
        checks.validate_envelope(valid + b' ' * (checks.MAX_REPORT_BYTES - len(valid)), IDENTITY, 11, TRACE, PARSER)
        for encoded in [b'', b'\xff', b'null', b'[]', valid + b' ' * (checks.MAX_REPORT_BYTES + 1 - len(valid)),
                        valid.replace(b'"formatVersion":1', b'"formatVersion":1,"formatVersion":1', 1),
                        valid.replace(b'"flagCount":0', b'"flagCount":0.0'),
                        valid.replace(b'"flagCount":0', b'"flagCount":NaN'), b'[' * 17 + b'0' + b']' * 17]:
            with self.subTest(encoded=encoded[:40]), self.assertRaises(checks.InvalidReport):
                checks.validate_envelope(encoded, IDENTITY, 11, TRACE, PARSER)

    def test_published_document_hash_count_and_original_values(self):
        expected = json.loads(DOCUMENT)
        self.assertEqual(checks.verify_document(DOCUMENT, receipt(), expected), expected)
        for field, value in [('documentByteCount', len(DOCUMENT) + 1), ('documentSHA256', 'c' * 64),
                             ('flagCount', 1), ('persistentMarkCount', 1), ('favoriteTrackCount', 0)]:
            modified = receipt()
            modified[field] = value
            with self.assertRaises(checks.InvalidReport):
                checks.verify_document(DOCUMENT, modified, expected)
        modified = {**expected, 'favoriteTrackIDs': []}
        with self.assertRaises(checks.InvalidReport):
            checks.verify_document(DOCUMENT, receipt(), modified)


if __name__ == '__main__':
    unittest.main(verbosity=2)
