"""Independent live kernel witness. No stdout marker admits ownership.
Controlled N37 fixture coverage is not actual product cancellation/forest proof.
The Python supervisor is trusted code; this is not a sandbox against same-process introspection.
"""
import ctypes as C,hashlib,os,stat,subprocess,time
from hash_budget import HashBudget,HashBudgetError
_TOKEN=object()
class OwnershipError(ValueError):pass
class Row(C.Structure):
 _fields_=[('pid',C.c_int32),('ppid',C.c_int32),('pgid',C.c_int32),('state',C.c_int32),('sec',C.c_uint64),('usec',C.c_uint64),('rss',C.c_uint64),('status',C.c_int32),('rss_status',C.c_int32),('error',C.c_int32),('rss_error',C.c_int32)]
def identity(path):
 if type(path) is not str or not os.path.isabs(path) or '\x00' in path:raise OwnershipError('absolute executable path required')
 s=os.lstat(path)
 if not stat.S_ISREG(s.st_mode):raise OwnershipError('regular no-follow executable required')
 return (s.st_dev,s.st_ino,s.st_size,s.st_mode,s.st_mtime_ns,s.st_ctime_ns)
def digest(path,*,hash_budget,expected_identity=None,max_extent_bytes=None):
 # Optional caller-role bounds narrow the existing shared budget. They never
 # create/reset credits or extend its original deadline/cancellation authority.
 if type(hash_budget) is not HashBudget:raise OwnershipError('HASH_INVALID_POLICY')
 if expected_identity is not None and (type(expected_identity) is not tuple or len(expected_identity)!=6 or any(type(v) is not int or v<0 for v in expected_identity)):raise OwnershipError('HASH_INVALID_EXPECTED_IDENTITY')
 if max_extent_bytes is not None and (type(max_extent_bytes) is not int or not 1<=max_extent_bytes<=hash_budget.policy.per_file_max_bytes):raise OwnershipError('HASH_INVALID_EXTENT_POLICY')
 try:
  hash_budget.checkpoint()
  before=identity(path)
  if expected_identity is not None and before!=expected_identity:raise OwnershipError('HASH_EXPECTED_IDENTITY_MISMATCH')
  if max_extent_bytes is not None and before[2]>max_extent_bytes:raise OwnershipError('HASH_FILE_BUDGET_EXCEEDED')
  hash_budget.authorize_file(before[2]);h=hashlib.sha256()
  hash_budget.checkpoint()
  fd=os.open(path,os.O_RDONLY|os.O_NONBLOCK|os.O_NOFOLLOW|os.O_CLOEXEC)
  try:
   hash_budget.checkpoint()
   s=os.fstat(fd);opened=(s.st_dev,s.st_ino,s.st_size,s.st_mode,s.st_mtime_ns,s.st_ctime_ns)
   if opened!=before:raise OwnershipError('file changed before pin')
   file_read=0
   while file_read<before[2]:
    amount=hash_budget.next_read_size(file_read,before[2])
    b=os.read(fd,amount);hash_budget.charge_read(len(b),amount);file_read+=len(b)
    hash_budget.checkpoint()
    if not b:raise OwnershipError('file changed during pin')
    h.update(b)
   s=os.fstat(fd)
   if (s.st_dev,s.st_ino,s.st_size,s.st_mode,s.st_mtime_ns,s.st_ctime_ns)!=before or identity(path)!=before:raise OwnershipError('file changed during pin')
   hash_budget.checkpoint()
  finally:os.close(fd)
  hash_budget.checkpoint()
  return h.hexdigest(),before
 except HashBudgetError as error:raise OwnershipError(error.code) from None
 except OSError:raise OwnershipError('HASH_IO_UNAVAILABLE') from None
class KernelOwnership:
 def __init__(self,token):
  if token is not _TOKEN:raise OwnershipError('kernel admission required')
 @classmethod
 def admit(cls,child,helper_pid,parser_pid,bridge_path,bridge_sha256,executable_pins,*,hash_budget):
  try:return cls._admit(child,helper_pid,parser_pid,bridge_path,bridge_sha256,executable_pins,hash_budget=hash_budget)
  except OwnershipError:raise
  except (OSError,AttributeError,TypeError,ValueError):raise OwnershipError('kernel admission unavailable') from None
 @classmethod
 def _admit(cls,child,helper_pid,parser_pid,bridge_path,bridge_sha256,executable_pins,*,hash_budget):
  if type(child) is not subprocess.Popen or child.poll() is not None:raise OwnershipError('live supervisor-owned Popen required')
  if type(executable_pins) is not dict or set(executable_pins)!={'consumer','helper','parser'}:raise OwnershipError('three named current executable pins required')
  for spec in executable_pins.values():
   if type(spec) is not dict or set(spec)!={'path','sha256'} or type(spec['path']) is not str or type(spec['sha256']) is not str:raise OwnershipError('exact executable pin shape required')
  if type(bridge_sha256) is not str or len(bridge_sha256)!=64 or any(c not in '0123456789abcdef' for c in bridge_sha256):raise OwnershipError('canonical bridge digest required')
  sha,ident=digest(bridge_path,hash_budget=hash_budget)
  if sha!=bridge_sha256:raise OwnershipError('bridge pin mismatch')
  w=cls(_TOKEN);w.child=child;w.bridge_file=(bridge_path,ident);w.bridge=C.CDLL(bridge_path,use_errno=True)
  w.bridge.pf_identity.argtypes=[C.c_int,C.POINTER(Row)];w.bridge.pf_identity.restype=C.c_int
  w.bridge.pf_abi_fact.argtypes=[C.c_int];w.bridge.pf_abi_fact.restype=C.c_uint64
  facts=[2,C.sizeof(Row),Row.pid.offset,Row.ppid.offset,Row.pgid.offset,Row.state.offset,Row.sec.offset,Row.usec.offset,Row.rss.offset,Row.status.offset,5,Row.rss_status.offset,Row.error.offset,Row.rss_error.offset,C.alignment(Row)]
  if C.sizeof(Row)!=56 or [w.bridge.pf_abi_fact(i) for i in range(15)]!=facts:raise OwnershipError('bridge ABI mismatch')
  w.abi_facts=tuple(facts);w.zombie=5;w.libproc=C.CDLL('/usr/lib/libproc.dylib',use_errno=True);w.libproc.proc_pidpath.argtypes=[C.c_int,C.c_void_p,C.c_uint32];w.libproc.proc_pidpath.restype=C.c_int
  w.pids=(os.getpid(),child.pid,helper_pid,parser_pid)
  if len(set(w.pids))!=4 or any(type(x) is not int or x<=0 for x in w.pids):raise OwnershipError('distinct positive kernel PIDs required')
  w.rows=tuple(w.observe(x) for x in w.pids);w.files={}
  for name,pid in zip(('consumer','helper','parser'),w.pids[1:]):
   spec=executable_pins[name];path=w.path(pid)
   if path!=spec['path']:raise OwnershipError('kernel executable path mismatch')
   sha,ident=digest(path,hash_budget=hash_budget)
   if sha!=spec['sha256']:raise OwnershipError('current executable hash mismatch')
   w.files[name]=(path,ident)
  if not w.revalidate():raise OwnershipError('kernel birth/parent/group relation changed')
  w.admitted_ns=time.monotonic_ns();return w
 def observe(self,pid):
  row=Row()
  if self.bridge.pf_identity(pid,C.byref(row))!=0 or row.status!=0 or row.pid!=pid or not row.sec or row.usec>=1000000 or row.state==self.zombie:raise OwnershipError('live kernel identity unavailable')
  return (row.pid,row.ppid,row.pgid,row.sec,row.usec)
 def path(self,pid):
  b=C.create_string_buffer(4096)
  if self.libproc.proc_pidpath(pid,b,4096)<=0:raise OwnershipError('kernel executable unavailable')
  return os.fsdecode(b.value)
 def revalidate(self):
  try:
   if self.child.poll() is not None or identity(self.bridge_file[0])!=self.bridge_file[1]:return False
   if tuple(self.bridge.pf_abi_fact(i) for i in range(15))!=self.abi_facts:return False
   current=tuple(self.observe(x) for x in self.pids)
   if current!=self.rows:return False
   parent,root,helper,parser=current
   from group_relation import split_group_relation
   if not split_group_relation(parent,root,helper,parser):return False
   for name,pid in zip(('consumer','helper','parser'),self.pids[1:]):
    path,ident=self.files[name]
    if self.path(pid)!=path or identity(path)!=ident:return False
   return True
  except (OSError,OwnershipError,AttributeError,TypeError,ValueError):return False
