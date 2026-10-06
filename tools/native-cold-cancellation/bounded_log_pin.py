"""Internal evidence-shape bridge to the unchanged A51 bounded digest.

The operation caller supplies one thread-confined HashBudget for every log pin,
using its original work deadline, nonblocking cancellation authority and IO
credits. This module never constructs a budget, refreshes a deadline, resolves
a user symlink, or implements a second hash algorithm.
"""
import os
from pathlib import Path
import stat
from hash_budget import HashBudget,HashBudgetError,HashCode
from ownership import digest,OwnershipError

LOG_CAP=4*1024*1024
LOG_CODES=frozenset(('LOG_PIN_INVALID_BUDGET','LOG_PIN_INVALID_EXTENT_CAP','LOG_PIN_INVALID_PATH','LOG_PIN_EXTENT_EXCEEDED','LOG_PIN_CHANGED','LOG_PIN_READ_CONTRACT','LOG_PIN_IO_UNAVAILABLE'))
HASH_CODES=frozenset(code.value for code in HashCode)|{'HASH_IO_UNAVAILABLE','HASH_INVALID_EXPECTED_IDENTITY','HASH_INVALID_EXTENT_POLICY'}
CHANGED_ERRORS=frozenset(('file changed before pin','file changed during pin','HASH_EXPECTED_IDENTITY_MISMATCH'))

def pin(path,*,hash_budget,max_log_file_bytes):
    if type(hash_budget) is not HashBudget:raise OwnershipError('LOG_PIN_INVALID_BUDGET')
    if type(max_log_file_bytes) is not int or not 0<max_log_file_bytes<=LOG_CAP:
        raise OwnershipError('LOG_PIN_INVALID_EXTENT_CAP')
    try:
        hash_budget.checkpoint()
        if not isinstance(path,(str,Path)):raise OwnershipError('LOG_PIN_INVALID_PATH')
        spelling=os.fspath(path)
        if type(spelling) is not str or not spelling or '\0' in spelling or len(spelling)>4096 or not os.path.isabs(spelling):
            raise OwnershipError('LOG_PIN_INVALID_PATH')
        if os.path.normpath(spelling)!=spelling:raise OwnershipError('LOG_PIN_INVALID_PATH')
        parts=Path(spelling).parts
        if len(parts)>256:raise OwnershipError('LOG_PIN_INVALID_PATH')
        current=Path(parts[0])
        for index,part in enumerate(parts):
            if index:current=current/part
            hash_budget.checkpoint()
            metadata=os.lstat(current)
            if stat.S_ISLNK(metadata.st_mode):raise OwnershipError('LOG_PIN_INVALID_PATH')
            if index<len(parts)-1 and not stat.S_ISDIR(metadata.st_mode):raise OwnershipError('LOG_PIN_INVALID_PATH')
            if index==len(parts)-1 and not stat.S_ISREG(metadata.st_mode):raise OwnershipError('LOG_PIN_INVALID_PATH')
        leaf_identity=(metadata.st_dev,metadata.st_ino,metadata.st_size,metadata.st_mode,metadata.st_mtime_ns,metadata.st_ctime_ns)
        if leaf_identity[2]>max_log_file_bytes:raise OwnershipError('LOG_PIN_EXTENT_EXCEEDED')
        charged_before=hash_budget.bytes_read_total
        sha,held_identity=digest(spelling,hash_budget=hash_budget,expected_identity=leaf_identity,max_extent_bytes=max_log_file_bytes)
        byte_count=hash_budget.bytes_read_total-charged_before
        if type(held_identity) is not tuple or len(held_identity)!=6 or any(type(value) is not int for value in held_identity):
            raise OwnershipError('LOG_PIN_READ_CONTRACT')
        if held_identity!=leaf_identity:raise OwnershipError('LOG_PIN_CHANGED')
        if byte_count!=held_identity[2] or byte_count>max_log_file_bytes:raise OwnershipError('LOG_PIN_READ_CONTRACT')
        final=os.lstat(spelling)
        if (final.st_dev,final.st_ino,final.st_size,final.st_mode,final.st_mtime_ns,final.st_ctime_ns)!=held_identity:
            raise OwnershipError('LOG_PIN_CHANGED')
        hash_budget.checkpoint()
        return dict(path=str(path),byteCount=byte_count,sha256=sha,mode=stat.S_IMODE(held_identity[3]))
    except HashBudgetError as error:raise OwnershipError(error.code) from None
    except OSError:raise OwnershipError('LOG_PIN_IO_UNAVAILABLE') from None
    except OwnershipError as error:
        code=error.args[0] if len(error.args)==1 and type(error.args[0]) is str else 'LOG_PIN_READ_CONTRACT'
        if code in CHANGED_ERRORS:code='LOG_PIN_CHANGED'
        elif code not in LOG_CODES and code not in HASH_CODES:code='LOG_PIN_READ_CONTRACT'
        raise OwnershipError(code) from None
