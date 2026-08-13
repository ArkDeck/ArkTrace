#ifndef ARKTRACE_SIGNAL_SHIM_H
#define ARKTRACE_SIGNAL_SHIM_H

// Installs async-signal-safe SIGINT/SIGTERM capture and returns the read side
// of a non-blocking, close-on-exec pipe. Signals received before the caller
// activates its event source remain buffered in the pipe.
int arktrace_signal_capture_start(void);

// Restores the dispositions captured by start and closes the signal-safe
// write side. The caller owns and must close the returned read descriptor.
void arktrace_signal_capture_stop(void);

// Returns the number of signals captured by the active shim, saturated at 2.
// Reading a sig_atomic_t is async-signal-safe and does not drain pipe bytes.
int arktrace_signal_capture_pending_count(void);

#endif
