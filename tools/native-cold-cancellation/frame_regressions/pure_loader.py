# N48: exact original AST methods; full production controller stays inert.
import ast
import hashlib
import json
from pathlib import Path
import sys
import types

T=Path(__file__).resolve().parent
R=T
EXTRACTED_METHODS=('fail','on_stdout_bytes')

def read(path):return Path(path).read_bytes()
def doc(path):return json.loads(read(path))

def extracted_nodes(source):
    tree=ast.parse(source)
    error=next(n for n in tree.body if isinstance(n,ast.ClassDef) and n.name=='SupervisorError')
    controller=next(n for n in tree.body if isinstance(n,ast.ClassDef) and n.name=='Controller')
    methods=[next(n for n in controller.body if isinstance(n,ast.FunctionDef) and n.name==name) for name in EXTRACTED_METHODS]
    return [error]+methods

def segment_manifest(source):
    rows=[]
    for node in extracted_nodes(source):
        segment=ast.get_source_segment(source,node)
        dump=ast.dump(node,include_attributes=True)
        rows.append(dict(name=node.name,startLine=node.lineno,endLine=node.end_lineno,
            originalSourceSegment=segment,segmentUTF8Bytes=len(segment.encode()),
            segmentSHA256=hashlib.sha256(segment.encode()).hexdigest(),
            originalASTSHA256=hashlib.sha256(dump.encode()).hexdigest()))
    return rows

def load_ingress():
    source=read(T.parent/'controller.py').decode()
    expected=doc(R/'registration/loader-segments.json')
    assert segment_manifest(source)==expected['segments']
    error,*methods=extracted_nodes(source)
    holder=ast.ClassDef(name='ExtractedIngress',bases=[],keywords=[],body=methods,decorator_list=[],type_params=[])
    holder.lineno=methods[0].lineno;holder.col_offset=0
    holder.end_lineno=methods[-1].end_lineno;holder.end_col_offset=methods[-1].end_col_offset
    module=ast.Module(body=[error,holder],type_ignores=[])
    ast.fix_missing_locations(module)
    scope={'__name__':'N48_original_ingress_extract','__builtins__':__builtins__}
    exec(compile(module,str(T.parent/'controller.py'),'exec'),scope)
    return scope['ExtractedIngress'],scope['SupervisorError']

def load_hash_budget():
    source=read(T.parent/'hash_budget.py')
    module=types.ModuleType('N48_original_hash_budget')
    module.__file__=str(T.parent/'hash_budget.py')
    sys.modules[module.__name__]=module
    exec(compile(source,module.__file__,'exec'),module.__dict__)
    return module
