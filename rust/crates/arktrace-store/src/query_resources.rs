use crate::StoreError;

/// Session already retains its primary reader; this pool adds at most three
/// worker-owned connections. Policy stays outside the query JSON.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ReadPoolLimits {
    pub maximum_workers: usize,
    pub maximum_decoded_bytes: u64,
}
impl Default for ReadPoolLimits {
    fn default() -> Self {
        Self {
            maximum_workers: 3,
            maximum_decoded_bytes: 128 * 1024 * 1024,
        }
    }
}
impl ReadPoolLimits {
    pub fn validate(self) -> Result<(), StoreError> {
        if !(1..=3).contains(&self.maximum_workers)
            || !(1..=256 * 1024 * 1024).contains(&self.maximum_decoded_bytes)
        {
            return Err(StoreError::InvalidBudget);
        }
        Ok(())
    }
}

#[cfg(any(target_os = "macos", test))]
pub(crate) struct QueryResources {
    pub(crate) abort: arktrace_platform::CancellationToken,
    maximum_bytes: u64,
    used: std::sync::atomic::AtomicU64,
}
#[cfg(any(target_os = "macos", test))]
impl QueryResources {
    pub(crate) fn new(limits: ReadPoolLimits) -> Result<Self, StoreError> {
        limits.validate()?;
        Ok(Self {
            abort: Default::default(),
            maximum_bytes: limits.maximum_decoded_bytes,
            used: std::sync::atomic::AtomicU64::new(0),
        })
    }
    pub(crate) fn check(&self) -> Result<(), StoreError> {
        if self.abort.is_cancelled() {
            Err(StoreError::Cancelled)
        } else {
            Ok(())
        }
    }
    /// Monotonic allocation credit for the complete batch. Temporary and
    /// retained rows share one conservative budget; nothing is reset by SQL.
    pub(crate) fn reserve(&self, bytes: u64) -> Result<(), StoreError> {
        self.check()?;
        self.used
            .try_update(
                std::sync::atomic::Ordering::Relaxed,
                std::sync::atomic::Ordering::Relaxed,
                |used| used.checked_add(bytes).filter(|n| *n <= self.maximum_bytes),
            )
            .map(|_| ())
            .map_err(|_| StoreError::DecodedBudgetExceeded)
    }
    #[cfg(any(target_os = "macos", test))]
    pub(crate) fn used(&self) -> u64 {
        self.used.load(std::sync::atomic::Ordering::Relaxed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn concurrent_allocation_credit_is_shared_bounded_and_request_owned() {
        let limits = ReadPoolLimits {
            maximum_workers: 3,
            maximum_decoded_bytes: 1000,
        };
        let resources = QueryResources::new(limits).unwrap();
        std::thread::scope(|scope| {
            for _ in 0..3 {
                let resources = &resources;
                scope.spawn(move || {
                    for _ in 0..100 {
                        resources.reserve(3).unwrap();
                    }
                });
            }
        });
        assert_eq!(resources.used(), 900);
        resources.reserve(100).unwrap();
        assert_eq!(resources.reserve(1), Err(StoreError::DecodedBudgetExceeded));
        assert_eq!(resources.used(), 1000);
        resources.abort.cancel();
        assert_eq!(resources.reserve(0), Err(StoreError::Cancelled));
        QueryResources::new(limits).unwrap().reserve(1000).unwrap();
        for invalid in [
            ReadPoolLimits {
                maximum_workers: 0,
                ..limits
            },
            ReadPoolLimits {
                maximum_workers: 4,
                ..limits
            },
            ReadPoolLimits {
                maximum_decoded_bytes: 0,
                ..limits
            },
            ReadPoolLimits {
                maximum_decoded_bytes: 256 * 1024 * 1024 + 1,
                ..limits
            },
        ] {
            assert_eq!(invalid.validate(), Err(StoreError::InvalidBudget));
        }
    }
}
