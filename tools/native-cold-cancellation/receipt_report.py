"""Bounded pure projection from exact reviewed A56 DTO to schema1 report facts.
No JSON/IO/asdict/deepcopy/recursive walk or raw-dict fallback. Historical
producer clocks and claims remain facts; caller supplies the original actual
validation deadline and trusted nonblocking exact-bool cancellation authority.
"""
from enum import Enum
import time
from receipt_contract import (InteractiveReceipt,ControlFact,ClosureFact,TransportCode,
    ResourceName,ControlKind,ReceiptValidationError,validate_interactive_receipt,
    TOP_SPECS,TOP_NAMES,CLOSURE_NAMES,RESOURCE_NAMES,CODE_VALUES,CONTROL_VALUES)

class ProjectionCode(str,Enum):
    INVALID_CONTROL='REPORT_INVALID_CONTROL'
    CANCELLED='REPORT_CANCELLED'
    DEADLINE='REPORT_DEADLINE_EXCEEDED'
    SHAPE='REPORT_DTO_SHAPE_INVALID'
    TYPE='REPORT_DTO_TYPE_INVALID'
    RANGE='REPORT_DTO_RANGE_INVALID'
    ENUM='REPORT_DTO_ENUM_INVALID'
    RESOURCE='REPORT_DTO_RESOURCE_INVALID'
    ORDER='REPORT_DTO_ORDER_INVALID'
    RELATION='REPORT_DTO_RELATION_INVALID'

class ReceiptProjectionError(ValueError):
    schema_version=1
    def __init__(self,code):
        self.code=code.value
        super().__init__(self.code)

class _Checks:
    __slots__=('deadline','cancelled')
    def __init__(self,deadline,cancelled):
        if type(deadline) is not int or not 1<=deadline<=(1<<63)-1 or not callable(cancelled):
            raise ReceiptProjectionError(ProjectionCode.INVALID_CONTROL)
        self.deadline=deadline;self.cancelled=cancelled
    def checkpoint(self):
        if time.monotonic_ns()>=self.deadline:raise ReceiptProjectionError(ProjectionCode.DEADLINE)
        try:value=self.cancelled()
        except BaseException:raise ReceiptProjectionError(ProjectionCode.INVALID_CONTROL) from None
        if type(value) is not bool:raise ReceiptProjectionError(ProjectionCode.INVALID_CONTROL)
        if value:raise ReceiptProjectionError(ProjectionCode.CANCELLED)
        if time.monotonic_ns()>=self.deadline:raise ReceiptProjectionError(ProjectionCode.DEADLINE)
    def require(self,condition,code):
        self.checkpoint()
        if not condition:raise ReceiptProjectionError(code)


def _field(value,name):
    try:return object.__getattribute__(value,name)
    except AttributeError:raise ReceiptProjectionError(ProjectionCode.SHAPE) from None


def _integer(value,lower,upper,nullable=False):
    if nullable and value is None:return
    if type(value) is not int:raise ReceiptProjectionError(ProjectionCode.TYPE)
    if value.bit_length()>64 or not lower<=value<=upper:raise ReceiptProjectionError(ProjectionCode.RANGE)


def _enum(value,expected,allowed,limit):
    if type(value) is not expected:raise ReceiptProjectionError(ProjectionCode.TYPE)
    primitive=_field(value,'value')
    if type(primitive) is not str:raise ReceiptProjectionError(ProjectionCode.TYPE)
    if len(primitive)>limit:raise ReceiptProjectionError(ProjectionCode.RANGE)
    if primitive not in allowed:raise ReceiptProjectionError(ProjectionCode.ENUM)


def _preflight(receipt,c):
    # This gate runs to completion before input-derived dicts/lists are built.
    c.checkpoint()
    if type(receipt) is not InteractiveReceipt:raise ReceiptProjectionError(ProjectionCode.TYPE)
    for name,kind,lower,upper in TOP_SPECS:
        c.checkpoint();value=_field(receipt,name)
        if kind=='bool':
            if type(value) is not bool:raise ReceiptProjectionError(ProjectionCode.TYPE)
        elif kind in ('int','nullable_int'):_integer(value,lower,upper,kind=='nullable_int')
        elif kind=='code':
            if value is not None:_enum(value,TransportCode,CODE_VALUES,64)
        elif kind=='unknown':
            if type(value) is not str:raise ReceiptProjectionError(ProjectionCode.TYPE)
            if len(value)>7:raise ReceiptProjectionError(ProjectionCode.RANGE)
            if value!='unknown':raise ReceiptProjectionError(ProjectionCode.ENUM)
        elif kind in ('control_list','closure_list'):
            if type(value) is not tuple:raise ReceiptProjectionError(ProjectionCode.TYPE)
            if len(value)>upper:raise ReceiptProjectionError(ProjectionCode.RANGE)
        else:raise ReceiptProjectionError(ProjectionCode.SHAPE)
    for row in _field(receipt,'controlCommands'):
        c.checkpoint()
        if type(row) is not ControlFact:raise ReceiptProjectionError(ProjectionCode.TYPE)
        _enum(_field(row,'kind'),ControlKind,CONTROL_VALUES,16)
        c.checkpoint();_integer(_field(row,'wireBytes'),1,256)
    resource_mask=0;index_mask=0;previous_resource=-1
    closures=_field(receipt,'closureReadbacks')
    for row in closures:
        c.checkpoint()
        if type(row) is not ClosureFact:raise ReceiptProjectionError(ProjectionCode.TYPE)
        for name in CLOSURE_NAMES:
            c.checkpoint();value=_field(row,name)
            if name=='resource':_enum(value,ResourceName,RESOURCE_NAMES,16)
            elif name=='descriptor':_integer(value,0,(1<<31)-1,True)
            elif name=='samePID':_integer(value,1,(1<<31)-1)
            elif name=='objectType':
                if type(value) is not str:raise ReceiptProjectionError(ProjectionCode.TYPE)
                if not 1<=len(value)<=128:raise ReceiptProjectionError(ProjectionCode.RANGE)
                if not value.isidentifier():raise ReceiptProjectionError(ProjectionCode.ENUM)
            elif name in ('fstatReturn','fcntlReturn'):_integer(value,-1,0,True)
            elif name in ('fstatErrnoEBADF','fcntlErrnoEBADF'):_integer(value,9,9,True)
            elif type(value) is not bool:raise ReceiptProjectionError(ProjectionCode.TYPE)
        c.checkpoint();index=_field(row,'producerIndex');_integer(index,0,6)
        resource=RESOURCE_NAMES.index(_field(_field(row,'resource'),'value'));bit=1<<resource
        c.require(not resource_mask&bit,ProjectionCode.RESOURCE);resource_mask|=bit
        c.require(resource>previous_resource,ProjectionCode.ORDER);previous_resource=resource
        c.require(not index_mask&(1<<index),ProjectionCode.ORDER);index_mask|=1<<index
    c.require(index_mask==(1<<len(closures))-1,ProjectionCode.ORDER)


def project_receipt(receipt,*,absolute_deadline_ns,cancelled):
    """Return exact bounded builtin schema1 facts in producer closure order.

    Accept only the exact reviewed A56 DTO types. Reject corrupt typed facts;
    never truncate/deduplicate, encode JSON or fall back to arbitrary input.
    ProducerIndex is projection metadata, omitted from original closure rows.
    The same caller deadline/authority is forwarded to public A56 semantic
    validation after bounded typed preflight and before any result is returned.
    """
    c=_Checks(absolute_deadline_ns,cancelled);c.checkpoint();_preflight(receipt,c);c.checkpoint()
    result={}
    for name in TOP_NAMES:
        c.checkpoint();value=_field(receipt,name)
        if name=='controlCommands':
            rows=[]
            for row in value:
                c.checkpoint();rows.append({'kind':_field(_field(row,'kind'),'value'),'wireBytes':_field(row,'wireBytes')})
            value=rows
        elif name=='closureReadbacks':
            rows=[None]*len(value)
            for row in value:
                c.checkpoint();primitive={}
                for field in CLOSURE_NAMES:
                    c.checkpoint();item=_field(row,field)
                    primitive[field]=_field(item,'value') if field=='resource' else item
                rows[_field(row,'producerIndex')]=primitive
            value=rows
        elif name in ('code','firstErrorCode'):value=None if value is None else _field(value,'value')
        result[name]=value
    c.checkpoint()
    try:validate_interactive_receipt(result,absolute_deadline_ns=c.deadline,cancelled=c.cancelled)
    except ReceiptValidationError as error:
        code={'RECEIPT_INVALID_CONTROL':ProjectionCode.INVALID_CONTROL,
              'RECEIPT_CANCELLED':ProjectionCode.CANCELLED,
              'RECEIPT_DEADLINE_EXCEEDED':ProjectionCode.DEADLINE}.get(error.code,ProjectionCode.RELATION)
        raise ReceiptProjectionError(code) from None
    c.checkpoint();return result
