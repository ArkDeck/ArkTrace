use crate::HostError;
use std::{
    sync::{Arc, Mutex},
    time::Instant,
};

/// Cancellation and the final publication syscall share a linearization lock.
#[derive(Clone, Debug, Default)]
pub struct CancellationToken(Arc<Mutex<bool>>);

impl CancellationToken {
    pub fn cancel(&self) {
        *self.0.lock().unwrap_or_else(|poison| poison.into_inner()) = true;
    }

    pub fn is_cancelled(&self) -> bool {
        *self.0.lock().unwrap_or_else(|poison| poison.into_inner())
    }

    #[cfg(target_os = "macos")]
    pub(crate) fn publication<T>(
        &self,
        action: impl FnOnce() -> Result<T, HostError>,
    ) -> Result<T, HostError> {
        let cancelled = self.0.lock().map_err(|_| HostError::CleanupFailed)?;
        if *cancelled {
            return Err(HostError::Cancelled);
        }
        action()
    }
}

#[derive(Clone, Debug)]
pub struct IoBudget {
    pub maximum_bytes: u64,
    pub deadline: Instant,
    pub cancellation: CancellationToken,
}

impl IoBudget {
    pub fn check(&self) -> Result<(), HostError> {
        if self.maximum_bytes == 0 {
            return Err(HostError::InvalidLimit);
        }
        if self.cancellation.is_cancelled() {
            return Err(HostError::Cancelled);
        }
        self.check_deadline()
    }

    pub(crate) fn check_deadline(&self) -> Result<(), HostError> {
        if Instant::now() >= self.deadline {
            return Err(HostError::DeadlineExceeded);
        }
        Ok(())
    }
}
