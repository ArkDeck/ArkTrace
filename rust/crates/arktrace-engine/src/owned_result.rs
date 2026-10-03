use serde::Serialize;
use std::{
    io::{self, Write},
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
};

pub(crate) struct ResultBudget {
    maximum: usize,
    used: AtomicUsize,
}
impl ResultBudget {
    pub(crate) fn new(maximum: usize) -> Arc<Self> {
        Arc::new(Self {
            maximum,
            used: AtomicUsize::new(0),
        })
    }
    pub(crate) fn used(&self) -> usize {
        self.used.load(Ordering::Relaxed)
    }
    fn reserve(&self, bytes: usize) -> io::Result<()> {
        self.used
            .try_update(Ordering::Relaxed, Ordering::Relaxed, |used| {
                used.checked_add(bytes).filter(|n| *n <= self.maximum)
            })
            .map(|_| ())
            .map_err(|_| io::Error::other("result allocation limit"))
    }
}
struct Charge {
    budget: Arc<ResultBudget>,
    bytes: usize,
}
impl Drop for Charge {
    fn drop(&mut self) {
        self.budget.used.fetch_sub(self.bytes, Ordering::Relaxed);
    }
}
struct Data {
    bytes: Vec<u8>,
    _charge: Charge,
}
/// Rust-owned immutable UTF-8 result. It survives request release, the next
/// call and engine drain. Its actual Vec capacity stays charged until the last
/// owner drops it; retaining a clone cannot bypass the Engine result budget.
#[derive(Clone)]
pub struct OwnedResult(Arc<Data>);
impl OwnedResult {
    pub fn bytes(&self) -> &[u8] {
        &self.0.bytes
    }
}
struct BoundedWriter {
    bytes: Vec<u8>,
    limit: usize,
    charge: Charge,
}
impl Write for BoundedWriter {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        let length = self
            .bytes
            .len()
            .checked_add(bytes.len())
            .filter(|n| *n <= self.limit)
            .ok_or_else(|| io::Error::other("result output limit"))?;
        if length > self.bytes.capacity() {
            let target = length
                .max(self.bytes.capacity().saturating_mul(2))
                .min(self.limit);
            let extra = target - self.bytes.capacity();
            self.charge.budget.reserve(extra)?;
            self.charge.bytes += extra;
            self.bytes
                .try_reserve_exact(target - self.bytes.len())
                .map_err(|_| io::Error::other("result allocation failed"))?;
            // Vec may reserve more than requested. Reject oversized output
            // capacity and charge any allocator rounding before retention.
            if self.bytes.capacity() > self.limit {
                return Err(io::Error::other("result allocation limit"));
            }
            let rounding = self.bytes.capacity() - target;
            self.charge.budget.reserve(rounding)?;
            self.charge.bytes += rounding;
        }
        self.bytes.extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
pub(crate) fn encode<T: Serialize>(
    value: &T,
    budget: Arc<ResultBudget>,
    limit: usize,
) -> Result<OwnedResult, ()> {
    budget.reserve(64).map_err(|_| ())?;
    let mut writer = BoundedWriter {
        bytes: Vec::new(),
        limit,
        charge: Charge { budget, bytes: 64 },
    };
    serde_json::to_writer(&mut writer, value).map_err(|_| ())?;
    Ok(OwnedResult(Arc::new(Data {
        bytes: writer.bytes,
        _charge: writer.charge,
    })))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn retained_results_stay_charged_after_request_release_and_encoding_failure() {
        let budget = ResultBudget::new(128);
        let first = encode(&"hello", budget.clone(), 64).unwrap();
        let held = first.clone();
        drop(first);
        assert_eq!(held.bytes(), br#""hello""#);
        assert!(budget.used() > 64);
        assert!(encode(&"too much", budget.clone(), 64).is_err());
        drop(held);
        assert_eq!(budget.used(), 0);
        assert!(encode(&"large".repeat(100), budget.clone(), 16).is_err());
        assert_eq!(budget.used(), 0);
        let final_result = encode(&7, budget.clone(), 8).unwrap();
        assert_eq!(final_result.bytes(), b"7");
        drop(final_result);
        assert_eq!(budget.used(), 0);
    }
}
