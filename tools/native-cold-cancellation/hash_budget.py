"""Versioned cooperative hash limits supplied by the trusted operation caller.

The cancellation callback must be cheap, nonblocking, and return an exact bool.
The runtime uses the real monotonic clock; neither input files nor stdout can
supply time or cancellation authority. One budget is shared across all hashes
in an operation. No refresh/reset method or unlimited default exists.
"""
from dataclasses import dataclass
from enum import Enum
import time

MAX_FILE_BYTES=64*1024*1024
MAX_TOTAL_BYTES=256*1024*1024
MAX_CHUNK_BYTES=64*1024
MAX_DEADLINE_NS=(1<<63)-1

class HashCode(str,Enum):
    INVALID_POLICY='HASH_INVALID_POLICY'
    INVALID_CONTROL='HASH_INVALID_CONTROL'
    CANCELLED='HASH_CANCELLED'
    DEADLINE='HASH_DEADLINE_EXCEEDED'
    FILE_BUDGET='HASH_FILE_BUDGET_EXCEEDED'
    TOTAL_BUDGET='HASH_TOTAL_BUDGET_EXCEEDED'
    READ_CONTRACT='HASH_READ_CONTRACT_VIOLATION'

class HashBudgetError(ValueError):
    schema_version=1
    def __init__(self,code):
        assert type(code) is HashCode
        self.code=code.value
        super().__init__(self.code)

def bounded_integer(value,lower,upper):
    if type(value) is not int or not lower<=value<=upper:
        raise HashBudgetError(HashCode.INVALID_POLICY)

@dataclass(frozen=True,slots=True)
class HashPolicy:
    schema_version:int
    per_file_max_bytes:int
    total_max_bytes:int
    chunk_bytes:int
    absolute_deadline_ns:int
    def __post_init__(self):
        bounded_integer(self.schema_version,1,1)
        bounded_integer(self.per_file_max_bytes,1,MAX_FILE_BYTES)
        bounded_integer(self.total_max_bytes,1,MAX_TOTAL_BYTES)
        bounded_integer(self.chunk_bytes,1,min(MAX_CHUNK_BYTES,self.per_file_max_bytes))
        bounded_integer(self.absolute_deadline_ns,1,MAX_DEADLINE_NS)

class HashBudget:
    __slots__=('_policy','_cancelled','_total','_reads')
    def __init__(self,policy,cancelled):
        if type(policy) is not HashPolicy:raise HashBudgetError(HashCode.INVALID_POLICY)
        if not callable(cancelled):raise HashBudgetError(HashCode.INVALID_CONTROL)
        self._policy=policy;self._cancelled=cancelled;self._total=0;self._reads=0
    @property
    def policy(self):return self._policy
    @property
    def bytes_read_total(self):return self._total
    @property
    def read_calls(self):return self._reads
    def checkpoint(self):
        if time.monotonic_ns()>=self._policy.absolute_deadline_ns:raise HashBudgetError(HashCode.DEADLINE)
        try:cancelled=self._cancelled()
        except Exception:raise HashBudgetError(HashCode.INVALID_CONTROL) from None
        if type(cancelled) is not bool:raise HashBudgetError(HashCode.INVALID_CONTROL)
        if cancelled:raise HashBudgetError(HashCode.CANCELLED)
        # A trusted callback cannot extend the original deadline.
        if time.monotonic_ns()>=self._policy.absolute_deadline_ns:raise HashBudgetError(HashCode.DEADLINE)
    def authorize_file(self,size):
        if type(size) is not int or size<0:raise HashBudgetError(HashCode.READ_CONTRACT)
        if size>self._policy.per_file_max_bytes:raise HashBudgetError(HashCode.FILE_BUDGET)
    def next_read_size(self,file_read,file_size):
        self.checkpoint()
        if type(file_read) is not int or not 0<=file_read<file_size:raise HashBudgetError(HashCode.READ_CONTRACT)
        remaining=self._policy.total_max_bytes-self._total
        if remaining<=0:raise HashBudgetError(HashCode.TOTAL_BUDGET)
        return min(self._policy.chunk_bytes,file_size-file_read,self._policy.per_file_max_bytes-file_read,remaining)
    def charge_read(self,amount,requested):
        # Account actual returned bytes before cancellation/deadline checks.
        if type(amount) is not int or type(requested) is not int or not 0<=amount<=requested:
            raise HashBudgetError(HashCode.READ_CONTRACT)
        self._total+=amount;self._reads+=1
        if self._total>self._policy.total_max_bytes:raise HashBudgetError(HashCode.TOTAL_BUDGET)
