# Load only the unchanged pure terminal module; protocol and Swift stay inert.
from pathlib import Path
import ast,hashlib,json,types
T=Path(__file__).resolve().parent
R=T

def load_terminal():
    source=(T.parent/'terminal_proof.py').read_bytes()
    manifest=json.loads((R/'registration/terminal-segments.json').read_bytes())
    assert len(source)==manifest['sourceByteCount'] and hashlib.sha256(source).hexdigest()==manifest['sourceSHA256']
    tree=ast.parse(source)
    assert all(not isinstance(n,(ast.Import,ast.ImportFrom)) for n in tree.body)
    module=types.ModuleType('N49_original_terminal_proof')
    module.__file__=str(T.parent/'terminal_proof.py')
    exec(compile(source,module.__file__,'exec'),module.__dict__)
    return module
