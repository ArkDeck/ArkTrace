#[cfg(any(target_os = "macos", test))]
use std::sync::atomic::{AtomicU32, Ordering};

#[cfg(any(target_os = "macos", test))]
static NEXT_ENGINE: AtomicU32 = AtomicU32::new(1);
#[cfg(any(target_os = "macos", test))]
const MAX_GENERATION: u32 = 0x00ff_ffff;

/// Engine tag (32), generation (24), slot (8). No pointers or Rust layout.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, serde::Serialize)]
#[serde(transparent)]
pub struct RuntimeHandle(u64);
impl RuntimeHandle {
    pub fn raw(self) -> u64 {
        self.0
    }
    pub fn from_raw(raw: u64) -> Self {
        Self(raw)
    }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize)]
pub enum HandleError {
    Invalid,
    Exhausted,
}
#[cfg(any(target_os = "macos", test))]
struct Slot<T> {
    generation: u32,
    value: Option<T>,
}
#[cfg(any(target_os = "macos", test))]
pub(crate) struct HandleTable<T> {
    engine: u32,
    slots: Vec<Slot<T>>,
}
#[cfg(any(target_os = "macos", test))]
impl<T> HandleTable<T> {
    pub(crate) fn new(maximum: usize) -> Result<Self, HandleError> {
        if !(1..=256).contains(&maximum) {
            return Err(HandleError::Exhausted);
        }
        let engine = NEXT_ENGINE
            .try_update(Ordering::Relaxed, Ordering::Relaxed, |n| n.checked_add(1))
            .map_err(|_| HandleError::Exhausted)?;
        Ok(Self {
            engine,
            slots: (0..maximum)
                .map(|_| Slot {
                    generation: 1,
                    value: None,
                })
                .collect(),
        })
    }
    pub(crate) fn insert(&mut self, value: T) -> Result<RuntimeHandle, HandleError> {
        let (index, slot) = self
            .slots
            .iter_mut()
            .enumerate()
            .find(|(_, s)| s.value.is_none() && s.generation <= MAX_GENERATION)
            .ok_or(HandleError::Exhausted)?;
        slot.value = Some(value);
        Ok(RuntimeHandle(
            (u64::from(self.engine) << 32) | (u64::from(slot.generation) << 8) | index as u64,
        ))
    }
    fn index(&self, handle: RuntimeHandle) -> Result<usize, HandleError> {
        if (handle.0 >> 32) as u32 != self.engine {
            return Err(HandleError::Invalid);
        }
        let index = (handle.0 & 255) as usize;
        let slot = self.slots.get(index).ok_or(HandleError::Invalid)?;
        if slot.generation != ((handle.0 >> 8) & u64::from(MAX_GENERATION)) as u32
            || slot.value.is_none()
        {
            return Err(HandleError::Invalid);
        }
        Ok(index)
    }
    pub(crate) fn get(&self, handle: RuntimeHandle) -> Result<&T, HandleError> {
        self.slots[self.index(handle)?]
            .value
            .as_ref()
            .ok_or(HandleError::Invalid)
    }
    pub(crate) fn get_mut(&mut self, handle: RuntimeHandle) -> Result<&mut T, HandleError> {
        let index = self.index(handle)?;
        self.slots[index].value.as_mut().ok_or(HandleError::Invalid)
    }
    pub(crate) fn remove(&mut self, handle: RuntimeHandle) -> Result<T, HandleError> {
        let index = self.index(handle)?;
        let slot = &mut self.slots[index];
        let value = slot.value.take().ok_or(HandleError::Invalid)?;
        slot.generation += 1; // exhausted slots retire; generation never wraps
        Ok(value)
    }
    pub(crate) fn values(&self) -> impl Iterator<Item = &T> {
        self.slots.iter().filter_map(|s| s.value.as_ref())
    }
    pub(crate) fn values_mut(&mut self) -> impl Iterator<Item = &mut T> {
        self.slots.iter_mut().filter_map(|s| s.value.as_mut())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn generation_and_engine_identity_reject_stale_foreign_and_repeated_release() {
        let mut a = HandleTable::new(1).unwrap();
        let mut b = HandleTable::new(1).unwrap();
        let old = a.insert(7).unwrap();
        let foreign = b.insert(8).unwrap();
        assert_eq!(a.get(foreign), Err(HandleError::Invalid));
        assert_eq!(a.remove(old), Ok(7));
        assert_eq!(a.remove(old), Err(HandleError::Invalid));
        let new = a.insert(9).unwrap();
        assert_ne!(old, new);
        assert_eq!(a.get(old), Err(HandleError::Invalid));
        assert_eq!(a.get(new), Ok(&9));
        *a.get_mut(new).unwrap() = 10;
        assert_eq!(a.values().copied().collect::<Vec<_>>(), vec![10]);
        for v in a.values_mut() {
            *v = 9;
        }
        assert_eq!(a.insert(10), Err(HandleError::Exhausted));
        assert_eq!(a.get(RuntimeHandle::from_raw(0)), Err(HandleError::Invalid));
        a.slots[0].generation = MAX_GENERATION;
        a.slots[0].value = None;
        let last = a.insert(11).unwrap();
        a.remove(last).unwrap();
        assert_eq!(a.insert(12), Err(HandleError::Exhausted));
    }
}
