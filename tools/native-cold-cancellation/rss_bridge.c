#include <libproc.h>
#include <sys/resource.h>
#include <stdint.h>
#include <stddef.h>
#include <errno.h>
#include <string.h>

/* Independent resource observations. Ownership/birth must be checked before
   and after the caller reads these samples. Unknown never becomes zero. */
uint64_t arktrace_rusage_fact(int key) {
    const uint64_t facts[] = {RUSAGE_INFO_V2, sizeof(struct rusage_info_v2),
        offsetof(struct rusage_info_v2, ri_resident_size),
        offsetof(struct rusage_info_v2, ri_phys_footprint)};
    return key >= 0 && (size_t)key < sizeof(facts) / sizeof(facts[0])
        ? facts[key] : UINT64_MAX;
}

int arktrace_memory(int pid, uint64_t *resident, uint64_t *footprint,
                    int *raw_result, int *raw_errno) {
    if (pid <= 0 || !resident || !footprint || !raw_result || !raw_errno) {
        errno = EINVAL;
        return -1;
    }
    struct rusage_info_v2 info;
    memset(&info, 0, sizeof(info));
    errno = 0;
    int result = proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&info);
    int error = errno;
    *raw_result = result;
    *raw_errno = error;
    if (result != 0 || error != 0) return -1;
    *resident = info.ri_resident_size;
    *footprint = info.ri_phys_footprint;
    return 0;
}
