"""Pure bounded lexical admission before JSON parsing; no kernel authority."""
import math,time
CODES=frozenset(('wire_shape','wire_depth','wire_tokens','wire_string','wire_key','wire_atom','wire_integer','wire_syntax','wire_nonfinite','operation_deadline','operation_cancelled','cancel_provider','budget_arguments'))
class WireError(ValueError):
 def __init__(self,code):
  self.code=code if code in CODES else 'wire_shape';super().__init__(self.code)
class WireBudget:
 MAX_RECORD=65536;MAX_STREAM=131072;MAX_DEPTH=8;MAX_RECORD_TOKENS=1024;MAX_STREAM_TOKENS=8192
 MAX_STRING_WIRE=4096;MAX_KEY_WIRE=256;MAX_ATOM=64;MAX_INTEGER_DIGITS=20
 def __init__(self,absolute_deadline_ns,cancelled):
  if type(absolute_deadline_ns) is not int or not 0<absolute_deadline_ns<2**63 or not callable(cancelled):raise WireError('budget_arguments')
  self._deadline=absolute_deadline_ns;self._cancelled=cancelled;self.total_bytes=0;self.total_tokens=0;self.last_metrics=None
  self.check()
 @property
 def absolute_deadline_ns(self):return self._deadline
 def check(self):
  if time.monotonic_ns()>=self._deadline:raise WireError('operation_deadline')
  try:flag=self._cancelled()
  except Exception:raise WireError('cancel_provider') from None
  if type(flag) is not bool:raise WireError('cancel_provider')
  if time.monotonic_ns()>=self._deadline:raise WireError('operation_deadline')
  if flag:raise WireError('operation_cancelled')
 def scan(self,line):
  self.check()
  if type(line) is not bytes or not 0<len(line)<=self.MAX_RECORD:raise WireError('wire_shape')
  if self.total_bytes+len(line)>self.MAX_STREAM:raise WireError('wire_shape')
  self.total_bytes+=len(line);n=len(line);i=0;stack=[];tokens=0;max_depth=0;steps=0
  def token():
   nonlocal tokens
   tokens+=1;self.total_tokens+=1
   if tokens>self.MAX_RECORD_TOKENS or self.total_tokens>self.MAX_STREAM_TOKENS:raise WireError('wire_tokens')
  while i<n:
   steps+=1
   if steps%64==0:self.check()
   c=line[i]
   if c in (32,9,10,13):i+=1;continue
   if c==34:
    token();i+=1;start=i;escaped=False
    while i<n:
     if i%256==0:self.check()
     c=line[i]
     if i-start>self.MAX_STRING_WIRE:raise WireError('wire_string')
     if escaped:escaped=False;i+=1;continue
     if c==92:escaped=True;i+=1;continue
     if c==34:break
     if c<32:raise WireError('wire_syntax')
     i+=1
    if i==n:raise WireError('wire_syntax')
    width=i-start
    if width>self.MAX_STRING_WIRE:raise WireError('wire_string')
    i+=1;j=i
    while j<n and line[j] in (32,9,10,13):
     if j%256==0:self.check()
     j+=1
    if j<n and line[j]==58 and width>self.MAX_KEY_WIRE:raise WireError('wire_key')
    continue
   if c in (123,91):
    token();stack.append(c);max_depth=max(max_depth,len(stack))
    if len(stack)>self.MAX_DEPTH:raise WireError('wire_depth')
    i+=1;continue
   if c in (125,93):
    if not stack or stack.pop()!=(123 if c==125 else 91):raise WireError('wire_syntax')
    i+=1;continue
   if c in (44,58):i+=1;continue
   token();start=i
   while i<n and line[i] not in (32,9,10,13,44,58,123,125,91,93,34):
    if i-start>=self.MAX_ATOM:raise WireError('wire_atom')
    i+=1
   atom=line[start:i]
   if atom in (b'NaN',b'Infinity',b'-Infinity'):raise WireError('wire_nonfinite')
   if atom and all(48<=v<=57 for v in atom.lstrip(b'-')) and len(atom.lstrip(b'-'))>self.MAX_INTEGER_DIGITS:raise WireError('wire_integer')
  if stack:raise WireError('wire_syntax')
  self.check();self.last_metrics=dict(bytes=n,tokens=tokens,maxDepth=max_depth,totalBytes=self.total_bytes,totalTokens=self.total_tokens)
 def check_decoded(self,value):
  self.check();stack=[value];nodes=0
  while stack:
   nodes+=1
   if nodes>self.MAX_RECORD_TOKENS:raise WireError('wire_tokens')
   if nodes%64==0:self.check()
   v=stack.pop()
   if type(v) is dict:stack.extend(v.values())
   elif type(v) is list:stack.extend(v)
   elif type(v) is float and not math.isfinite(v):raise WireError('wire_nonfinite')
  self.check()
