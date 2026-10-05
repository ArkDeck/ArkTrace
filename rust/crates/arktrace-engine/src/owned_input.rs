//! Admission credits for copied view-state inputs. Caller memory is borrowed
//! only during submit; the queued command owns and refunds its actual capacity.
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};

pub(crate) struct InputBudget {
    maximum: usize,
    used: AtomicUsize,
}
impl InputBudget {
    pub(crate) fn new(maximum: usize) -> Arc<Self> {
        Arc::new(Self {
            maximum,
            used: AtomicUsize::new(0),
        })
    }
    pub(crate) fn used(&self) -> usize {
        self.used.load(Ordering::Relaxed)
    }
    /// Reserve a bounded worker pipeline before enqueue, without allocating a
    /// dummy buffer. The queued command owns this credit through completion.
    pub(crate) fn charge(self: &Arc<Self>, bytes: usize) -> Result<InputCharge, ()> {
        self.reserve(bytes)?;
        Ok(InputCharge {
            budget: self.clone(),
            bytes,
        })
    }
    fn reserve(&self, bytes: usize) -> Result<(), ()> {
        self.used
            .try_update(Ordering::Relaxed, Ordering::Relaxed, |used| {
                used.checked_add(bytes).filter(|n| *n <= self.maximum)
            })
            .map(|_| ())
            .map_err(|_| ())
    }
}
pub(crate) struct InputCharge {
    budget: Arc<InputBudget>,
    bytes: usize,
}
impl Drop for InputCharge {
    fn drop(&mut self) {
        self.budget.used.fetch_sub(self.bytes, Ordering::Relaxed);
    }
}
pub(crate) struct OwnedInput {
    bytes: Vec<u8>,
    _charge: InputCharge,
}
impl OwnedInput {
    /// Reserve before allocation or copying, including allocator rounding.
    /// No waiting and no retained caller pointers, even on admission failure.
    pub(crate) fn copy(bytes: &[u8], budget: Arc<InputBudget>) -> Result<Self, ()> {
        budget.reserve(bytes.len())?;
        let mut charge = InputCharge {
            budget,
            bytes: bytes.len(),
        };
        let mut owned = Vec::new();
        owned.try_reserve_exact(bytes.len()).map_err(|_| ())?;
        let rounding = owned.capacity() - bytes.len();
        charge.budget.reserve(rounding)?;
        charge.bytes += rounding;
        owned.extend_from_slice(bytes);
        Ok(Self {
            bytes: owned,
            _charge: charge,
        })
    }
    pub(crate) fn bytes(&self) -> &[u8] {
        &self.bytes
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn worker_reservation_does_not_allocate_input_and_checked_add_refunds() {
        let budget = InputBudget::new(8);
        let held = budget.charge(8).unwrap();
        assert_eq!(budget.used(), 8);
        assert!(budget.charge(1).is_err());
        assert!(budget.charge(usize::MAX).is_err());
        assert_eq!(budget.used(), 8);
        drop(held);
        assert_eq!(budget.used(), 0);
        let held = budget.charge(8).unwrap();
        drop(held);
        assert_eq!(budget.used(), 0);
    }
    #[test]
    fn copied_bytes_are_independent_and_capacity_is_refunded_on_every_drop() {
        let budget = InputBudget::new(8);
        let mut caller = vec![1, 2, 3, 4];
        let first = OwnedInput::copy(&caller, budget.clone()).unwrap();
        caller.fill(9);
        assert_eq!(first.bytes(), [1, 2, 3, 4]);
        let second = OwnedInput::copy(&caller, budget.clone()).unwrap();
        assert_eq!(budget.used(), 8);
        assert!(OwnedInput::copy(&[0], budget.clone()).is_err());
        assert_eq!(budget.used(), 8);
        drop(first);
        assert_eq!(budget.used(), 4);
        drop(second);
        assert_eq!(budget.used(), 0);
        assert!(OwnedInput::copy(&[0; 9], budget.clone()).is_err());
        assert_eq!(budget.used(), 0);
    }
}
