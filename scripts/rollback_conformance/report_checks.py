"""Closed test-only rollback report reader; no product decoder/API proposal."""
from dataclasses import dataclass
import hashlib
import json
import re

MAX_REPORT_BYTES = 2048
MAX_RECEIPT_BYTES = 1024
MAX_DOCUMENT_BYTES = 4 * 1024 * 1024
MAX_ITEMS = 4096
STATUSES = frozenset(['notConfigured', 'sessionScoped', 'missing', 'preserved', 'backedUp', 'alreadyBackedUp'])
RECEIPT_KEYS = frozenset(['formatVersion', 'backupIdentifier', 'traceSHA256', 'parserKey', 'documentSHA256',
                          'documentByteCount', 'flagCount', 'persistentMarkCount', 'favoriteTrackCount'])
DIGEST = re.compile(r'[0-9a-f]{64}\Z')


class InvalidReport(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise InvalidReport(message)


def exact_keys(value, keys):
    require(type(value) is dict and set(value) == set(keys), 'closed object fields')


def integer(value, minimum, maximum):
    require(type(value) is int and minimum <= value <= maximum, 'integer bound')
    return value


def digest(value):
    require(type(value) is str and DIGEST.fullmatch(value) is not None, 'lowercase digest')
    return value


def _object(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value, 'duplicate JSON key')
        value[key] = item
    return value


def _non_integer(_):
    raise InvalidReport('non-integer JSON number')


def load_closed(raw, maximum):
    require(type(raw) is bytes and 0 < len(raw) <= maximum, 'transport byte bound')
    try:
        # The byte ceiling bounds all allocations; a separate depth ceiling
        # rejects pathological nesting before invoking the standard JSON parser.
        text = raw.decode('utf-8', errors='strict')
        depth = 0
        quoted = escaped = False
        for char in text:
            if quoted:
                if escaped:
                    escaped = False
                elif char == '\\':
                    escaped = True
                elif char == '"':
                    quoted = False
            elif char == '"':
                quoted = True
            elif char in '[{':
                depth += 1
                require(depth <= 16, 'JSON depth bound')
            elif char in ']}':
                depth -= 1
                require(depth >= 0, 'JSON depth balance')
        return json.loads(text, object_pairs_hook=_object, parse_float=_non_integer,
                          parse_constant=_non_integer)
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError) as error:
        raise InvalidReport('invalid bounded JSON') from error


def backup_identifier(trace, parser, document):
    value = hashlib.sha256(b'ArkTrace.ViewStateRollback.v1\0')
    for text in [digest(trace), digest(parser), digest(document)]:
        value.update(text.encode('ascii'))
        value.update(b'\0')
    return value.hexdigest()


@dataclass(frozen=True)
class Identity:
    engine: int
    session: int
    request: int

    def validate(self):
        for value in [self.engine, self.session, self.request]:
            integer(value, 1, 2**64 - 1)


def validate_receipt(value, trace, parser):
    exact_keys(value, RECEIPT_KEYS)
    integer(value['formatVersion'], 1, 1)
    for key in ['backupIdentifier', 'traceSHA256', 'parserKey', 'documentSHA256']:
        digest(value[key])
    require(value['traceSHA256'] == digest(trace) and value['parserKey'] == digest(parser), 'opening provenance')
    require(value['backupIdentifier'] == backup_identifier(trace, parser, value['documentSHA256']), 'snapshot digest')
    integer(value['documentByteCount'], 1, MAX_DOCUMENT_BYTES)
    flags = integer(value['flagCount'], 0, MAX_ITEMS)
    integer(value['persistentMarkCount'], 0, MAX_ITEMS - flags)
    favorites = value['favoriteTrackCount']
    if favorites is not None:
        integer(favorites, 0, MAX_ITEMS)
    return value


def validate_body(value, trace, parser):
    exact_keys(value, ['status', 'receipt'])
    require(type(value['status']) is str and value['status'] in STATUSES, 'closed status')
    backed = value['status'] in ['backedUp', 'alreadyBackedUp']
    require(backed == (value['receipt'] is not None), 'status receipt relationship')
    if backed:
        validate_receipt(value['receipt'], trace, parser)
    return value


def validate_envelope(raw, expected, origin_engine, trace, parser):
    expected.validate()
    # Engine is bound by the actual public call route; the wire deliberately
    # contains only Session/request identities. Never invent an engine field.
    require(type(origin_engine) is int and origin_engine == expected.engine, 'result engine owner')
    value = load_closed(raw, MAX_REPORT_BYTES)
    exact_keys(value, ['formatVersion', 'session', 'request', 'body'])
    integer(value['formatVersion'], 1, 1)
    require(integer(value['session'], 1, 2**64 - 1) == expected.session, 'session identity')
    require(integer(value['request'], 1, 2**64 - 1) == expected.request, 'request identity')
    return validate_body(value['body'], trace, parser)


def verify_document(raw, receipt, expected_document):
    require(type(raw) is bytes and 0 < len(raw) <= MAX_DOCUMENT_BYTES, 'document byte bound')
    require(len(raw) == receipt['documentByteCount'], 'document byte count')
    require(hashlib.sha256(raw).hexdigest() == receipt['documentSHA256'], 'document SHA256')
    value = load_closed(raw, MAX_DOCUMENT_BYTES)
    # This is an oracle comparison to an explicit submitted fixture, rather
    # than a second implementation of native format-1 admission.
    require(value == expected_document, 'persistent original ordered values')
    require(value['formatVersion'] == 1 and value['traceSHA256'] == receipt['traceSHA256'], 'format-1 document identity')
    require(len(value['flags']) == receipt['flagCount'], 'flag receipt count')
    require(all(mark['isPersistent'] is True for mark in value['marks']), 'transient omission')
    require(len(value['marks']) == receipt['persistentMarkCount'], 'mark receipt count')
    favorites = value.get('favoriteTrackIDs')
    require((None if favorites is None else len(favorites)) == receipt['favoriteTrackCount'], 'nullable favorite count')
    return value
