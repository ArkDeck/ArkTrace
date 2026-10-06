#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/proc.h>
#include <stddef.h>
#include <stdint.h>
#include <errno.h>
#include <string.h>
/* Apple SDK libproc calls only. No argv/env/path queries or process mutation. */
struct pf_row {
    int32_t pid, ppid, pgid, state;
    uint64_t start_sec, start_usec, rss_bytes;
    int32_t info_status, rss_status, info_errno, rss_errno;
};
_Static_assert(sizeof(struct pf_row)==56, "pf_row ABI");
static int category(int error) {
    if (error==ESRCH || error==ENOENT) return 1;
    if (error==EPERM || error==EACCES) return 2;
    return 3;
}
int pf_identity(int pid, struct pf_row *out) {
    if (!out) return -1;
    memset(out,0,sizeof(*out));out->pid=pid;out->info_status=3;out->rss_status=3;
    if (pid<=0) {out->info_errno=EINVAL;return 3;}
    struct proc_bsdinfo info;memset(&info,0,sizeof(info));errno=0;
    int n=proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,(int)sizeof(info));
    int error=errno;
    if (n!=(int)sizeof(info)) {out->info_status=category(error);out->info_errno=error;return out->info_status;}
    if (info.pbi_pid!=(uint32_t)pid || !info.pbi_start_tvsec || info.pbi_start_tvusec>=1000000) {out->info_errno=EINVAL;return 3;}
    out->pid=(int32_t)info.pbi_pid;out->ppid=(int32_t)info.pbi_ppid;
    out->pgid=(int32_t)info.pbi_pgid;out->state=(int32_t)info.pbi_status;
    out->start_sec=info.pbi_start_tvsec;out->start_usec=info.pbi_start_tvusec;out->info_status=0;
    return 0;
}
int pf_observe(int pid,struct pf_row *out) {
    int s=pf_identity(pid,out);if (s) return s;
    if (out->state==SZOMB) {out->rss_status=5;return 0;}
    struct proc_taskinfo task;memset(&task,0,sizeof(task));errno=0;
    int n=proc_pidinfo(pid,PROC_PIDTASKINFO,0,&task,(int)sizeof(task));int error=errno;
    struct pf_row after;int a=pf_identity(pid,&after);
    if (a || after.start_sec!=out->start_sec || after.start_usec!=out->start_usec) {
        out->info_status=4;out->info_errno=after.info_errno;out->rss_status=4;return 4;
    }
    out->ppid=after.ppid;out->pgid=after.pgid;out->state=after.state;
    if (out->state==SZOMB) {out->rss_status=5;return 0;}
    if (n!=(int)sizeof(task)) {out->rss_status=category(error);out->rss_errno=error;return 0;}
    out->rss_bytes=task.pti_resident_size;out->rss_status=0;return 0;
}
int pf_list(int32_t *buffer,int capacity) {
    if (!buffer || capacity<1 || capacity>8192) {errno=EINVAL;return -1;}
    errno=0;return proc_listpids(PROC_ALL_PIDS,0,buffer,capacity*(int)sizeof(int32_t));
}
uint64_t pf_abi_fact(int fact) {
    switch(fact) {
        case 0:return 1;case 1:return sizeof(struct pf_row);
        case 2:return sizeof(struct proc_bsdinfo);case 3:return sizeof(struct proc_taskinfo);
        case 4:return offsetof(struct proc_bsdinfo,pbi_start_tvsec);
        case 5:return offsetof(struct proc_bsdinfo,pbi_start_tvusec);
        case 6:return offsetof(struct proc_taskinfo,pti_resident_size);
        case 7:return PROC_PIDTBSDINFO;case 8:return PROC_PIDTASKINFO;
        case 9:return PROC_ALL_PIDS;case 10:return SZOMB;default:return UINT64_MAX;
    }
}
