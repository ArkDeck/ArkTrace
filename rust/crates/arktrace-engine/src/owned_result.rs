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
    scene: Option<arktrace_viewer::HotSnapshot>,
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
    pub fn snapshot(&self) -> Option<&arktrace_viewer::HotSnapshot> {
        self.0.scene.as_ref()
    }
    pub fn retained_bytes(&self) -> usize {
        self.0._charge.bytes
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
    encode_with_scene(value, None, budget, limit)
}
pub(crate) fn encode_with_scene<T: Serialize>(
    value: &T,
    scene: Option<arktrace_viewer::HotSnapshot>,
    budget: Arc<ResultBudget>,
    limit: usize,
) -> Result<OwnedResult, ()> {
    let scene_bytes = match &scene {
        Some(scene) => scene.retained_bytes().ok_or(())?,
        None => 0,
    };
    let output_limit = limit.checked_sub(scene_bytes).ok_or(())?;
    let initial = scene_bytes.checked_add(64).ok_or(())?;
    budget.reserve(initial).map_err(|_| ())?;
    let mut writer = BoundedWriter {
        bytes: Vec::new(),
        limit: output_limit,
        charge: Charge {
            budget,
            bytes: initial,
        },
    };
    serde_json::to_writer(&mut writer, value).map_err(|_| ())?;
    Ok(OwnedResult(Arc::new(Data {
        bytes: writer.bytes,
        scene,
        _charge: writer.charge,
    })))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn scene_and_json_share_the_owned_budget_and_refund_only_after_last_owner() {
        use arktrace_contract::*;
        use arktrace_viewer::*;
        let snapshot = project(
            &Viewport::new(TraceTimeRange::query(0, 100).unwrap(), 100.0, 80.0, 0.0, 1).unwrap(),
            1,
            &[],
            1.0,
            &DataQuality::machine(QualityStatus::Ok, vec![]).unwrap(),
            &mut || Ok(()),
        )
        .unwrap();
        let pack = || HotSnapshot::pack(&snapshot, 4096, &mut || Ok(())).unwrap();
        let scene_bytes = pack().retained_bytes().unwrap();
        let budget = ResultBudget::new(4096);
        assert!(
            encode_with_scene(
                &"large".repeat(100),
                Some(pack()),
                budget.clone(),
                scene_bytes + 16
            )
            .is_err()
        );
        assert_eq!(budget.used(), 0);
        let owned = encode_with_scene(&7, Some(pack()), budget.clone(), scene_bytes + 32).unwrap();
        assert!(owned.retained_bytes() >= scene_bytes + owned.bytes().len());
        assert_eq!(owned.retained_bytes(), budget.used());
        let clone = owned.clone();
        drop(owned);
        assert_eq!(clone.bytes(), b"7");
        assert_eq!(clone.snapshot().unwrap().viewport.generation, 1);
        assert!(budget.used() > scene_bytes);
        drop(clone);
        assert_eq!(budget.used(), 0);
        assert!(encode_with_scene(&7, Some(pack()), ResultBudget::new(scene_bytes), 4096).is_err());
    }
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
