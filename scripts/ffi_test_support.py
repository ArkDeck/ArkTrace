"""Contract-derived ctypes used only by the native conformance harness."""
import ctypes as C
import json
from pathlib import Path
import time
ROOT = Path(__file__).resolve().parent.parent
CONTRACT = json.loads((ROOT/'contracts/ffi-v1.json').read_text())
TYPES = {'u8':C.c_uint8,'u32':C.c_uint32,'u64':C.c_uint64,'i64':C.c_int64,'f64':C.c_double}

def type_for(t):
    if t.endswith('*'): return C.POINTER(type_for(t.removeprefix('const ')[:-1]))
    if '[' in t:
        base,count=t[:-1].split('[');return type_for(base)*int(count)
    return TYPES[t]
for record in CONTRACT['records']:
    TYPES[record['name']] = type(record['name'], (C.Structure,), {'_fields_':[(f['name'],type_for(f['type'])) for f in record['fields']]})
K = CONTRACT['constants']

class ABI:
    def __init__(self, path):
        self.lib = C.CDLL(str(path))
        for f in CONTRACT['functions']:
            fn=getattr(self.lib,f['name']);fn.argtypes=[type_for(p['type']) for p in f['parameters']];fn.restype=C.c_uint32
    def call(self,name,*args,expected=0):
        deadline=time.monotonic()+60
        while True:
            code=getattr(self.lib,'arktrace_'+name)(*args)
            if code!=K['STATUS_BUSY'] or time.monotonic()>=deadline:break
            time.sleep(.001)
        assert code==expected,(name,code,expected)
        return code
    def out(self,name,kind,*args,expected=0):
        value=TYPES[kind]()
        self.call(name,*args,C.byref(value),C.sizeof(value),expected=expected)
        return value
    def input(self,name,payload,kind,*prefix,expected=0):
        data=payload if isinstance(payload,bytes) else json.dumps(payload,ensure_ascii=False,separators=(',',':')).encode()
        array=(C.c_uint8*len(data)).from_buffer_copy(data)
        return self.out(name,kind,*prefix,array,len(data),expected=expected)
    def wait(self,engine,request):
        deadline=time.monotonic()+60
        while True:
            status=self.out('request_poll','PollStatus',engine,request)
            if status.state in (K['REQUEST_SUCCEEDED'],K['REQUEST_FAILED']):return status
            assert time.monotonic()<deadline,'request timeout'
            time.sleep(.001)
    def result(self,engine,request):
        status=self.wait(engine,request);assert status.state==K['REQUEST_SUCCEEDED'],(status.code,status.stage)
        view=self.out('result_acquire','ResultView',engine,request)
        return view,C.string_at(view.data,view.length)
    def submit(self,engine,session,operation):
        data=json.dumps(operation,ensure_ascii=False,separators=(',',':')).encode();array=(C.c_uint8*len(data)).from_buffer_copy(data)
        value=self.out('request_submit','u64',engine,session,array,len(data),60_000)
        return value.value
    def drain(self,engine):
        self.call('engine_drain',engine);deadline=time.monotonic()+60
        while self.out('engine_drain_status','u32',engine).value!=K['DRAIN_DRAINED']:
            assert time.monotonic()<deadline,'drain timeout';time.sleep(.001)
