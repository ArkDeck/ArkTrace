#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/proc.h>
#include <stdint.h>
#include <stddef.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
/* Controlled fixture bridge. Kernel rows always come from proc_pidinfo.
   N38_FIXTURE_ABI_FAULT can only invalidate an ABI fact; it never fabricates rows. */
typedef struct {
 int32_t pid,ppid,pgid,state;
 uint64_t sec,usec,rss;
 int32_t status,rss_status,error,rss_error;
} PFRow;
_Static_assert(sizeof(PFRow)==56,"PFRow ABI");
uint64_t pf_abi_fact(int key) {
 const uint64_t facts[]={2,sizeof(PFRow),offsetof(PFRow,pid),offsetof(PFRow,ppid),offsetof(PFRow,pgid),offsetof(PFRow,state),offsetof(PFRow,sec),offsetof(PFRow,usec),offsetof(PFRow,rss),offsetof(PFRow,status),SZOMB,offsetof(PFRow,rss_status),offsetof(PFRow,error),offsetof(PFRow,rss_error),_Alignof(PFRow),sizeof(struct proc_bsdinfo),_Alignof(struct proc_bsdinfo)};
 if(key==0 && getenv("N38_FIXTURE_ABI_FAULT"))return 999;
 return key>=0 && (size_t)key<sizeof(facts)/sizeof(facts[0])?facts[key]:UINT64_MAX;
}
int pf_identity_detail(int pid,PFRow *out,int *raw_return,int *raw_errno) {
 if(!out || pid<=0){errno=EINVAL;return -1;}
 memset(out,0,sizeof(*out));out->status=-1;out->rss_status=-1;
 struct proc_bsdinfo b;memset(&b,0,sizeof(b));
 errno=0;int n=proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&b,sizeof(b));int e=errno;
 if(raw_return)*raw_return=n;if(raw_errno)*raw_errno=e;
 if(n!=(int)sizeof(b)){out->error=e;return -1;}
 out->pid=(int32_t)b.pbi_pid;out->ppid=(int32_t)b.pbi_ppid;out->pgid=(int32_t)b.pbi_pgid;out->state=(int32_t)b.pbi_status;out->sec=b.pbi_start_tvsec;out->usec=b.pbi_start_tvusec;out->status=0;
 /* RSS not needed for ownership. Unqueried RSS is explicitly unavailable. */
 return 0;
}

int pf_identity(int pid,PFRow *out){return pf_identity_detail(pid,out,NULL,NULL);}
