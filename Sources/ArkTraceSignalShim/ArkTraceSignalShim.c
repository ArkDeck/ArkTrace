#include "ArkTraceSignalShim.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <unistd.h>

static volatile sig_atomic_t arktrace_signal_write_fd = -1;
static volatile sig_atomic_t arktrace_pending_signal_count = 0;
static struct sigaction arktrace_previous_sigint;
static struct sigaction arktrace_previous_sigterm;
static volatile sig_atomic_t arktrace_capture_started = 0;

static void arktrace_capture_signal(int signal_number)
{
    int saved_errno = errno;
    if (arktrace_pending_signal_count < 2) {
        arktrace_pending_signal_count += 1;
    }
    int descriptor = (int)arktrace_signal_write_fd;
    if (descriptor >= 0) {
        uint8_t value = (uint8_t)signal_number;
        (void)write(descriptor, &value, sizeof(value));
    }
    errno = saved_errno;
}

static int arktrace_configure_descriptor(int descriptor)
{
    int status_flags = fcntl(descriptor, F_GETFL);
    if (status_flags < 0 || fcntl(descriptor, F_SETFL, status_flags | O_NONBLOCK) < 0) {
        return -1;
    }
    int descriptor_flags = fcntl(descriptor, F_GETFD);
    if (descriptor_flags < 0 || fcntl(descriptor, F_SETFD, descriptor_flags | FD_CLOEXEC) < 0) {
        return -1;
    }
    return 0;
}

int arktrace_signal_capture_start(void)
{
    if (arktrace_capture_started) {
        errno = EALREADY;
        return -1;
    }

    int descriptors[2] = {-1, -1};
    if (pipe(descriptors) < 0) {
        return -1;
    }
    if (arktrace_configure_descriptor(descriptors[0]) < 0
        || arktrace_configure_descriptor(descriptors[1]) < 0) {
        int saved_errno = errno;
        close(descriptors[0]);
        close(descriptors[1]);
        errno = saved_errno;
        return -1;
    }

    struct sigaction action;
    action.sa_handler = arktrace_capture_signal;
    // Block both captured signals for the duration of the handler. Without
    // this, SIGTERM can nest inside the SIGINT handler and the read-modify-
    // write of the pending counter can lose an increment.
    sigemptyset(&action.sa_mask);
    sigaddset(&action.sa_mask, SIGINT);
    sigaddset(&action.sa_mask, SIGTERM);
    action.sa_flags = 0;
    arktrace_signal_write_fd = descriptors[1];
    arktrace_pending_signal_count = 0;

    if (sigaction(SIGINT, &action, &arktrace_previous_sigint) < 0) {
        int saved_errno = errno;
        arktrace_signal_write_fd = -1;
        close(descriptors[0]);
        close(descriptors[1]);
        errno = saved_errno;
        return -1;
    }
    if (sigaction(SIGTERM, &action, &arktrace_previous_sigterm) < 0) {
        int saved_errno = errno;
        (void)sigaction(SIGINT, &arktrace_previous_sigint, NULL);
        arktrace_signal_write_fd = -1;
        close(descriptors[0]);
        close(descriptors[1]);
        errno = saved_errno;
        return -1;
    }

    arktrace_capture_started = 1;
    return descriptors[0];
}

void arktrace_signal_capture_stop(void)
{
    if (!arktrace_capture_started) {
        return;
    }
    (void)sigaction(SIGINT, &arktrace_previous_sigint, NULL);
    (void)sigaction(SIGTERM, &arktrace_previous_sigterm, NULL);
    int descriptor = (int)arktrace_signal_write_fd;
    arktrace_signal_write_fd = -1;
    arktrace_capture_started = 0;
    if (descriptor >= 0) {
        (void)close(descriptor);
    }
    arktrace_pending_signal_count = 0;
}

int arktrace_signal_capture_pending_count(void)
{
    return arktrace_capture_started ? (int)arktrace_pending_signal_count : 0;
}
