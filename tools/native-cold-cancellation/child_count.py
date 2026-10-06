"""PID count decoding. proc_listchildpids takes bytes, returns PID count."""
from ownership import OwnershipError

def decode_count(raw_return,raw_errno,array):
 if type(raw_return) is not int or type(raw_errno) is not int:raise OwnershipError('integer kernel return and errno required')
 capacity=len(array)
 if raw_return<0 or raw_return>=capacity or raw_errno:raise OwnershipError('kernel child count unavailable, saturated or uncertain')
 pids=[int(array[i]) for i in range(raw_return)]
 if any(x<=0 for x in pids) or len(set(pids))!=len(pids):raise OwnershipError('kernel child count contains invalid PID slots')
 return pids
