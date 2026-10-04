use serde::{Deserialize, Serialize};

/// Same-host continuous system epoch. These integers are neither wall time
/// nor trace time; never persist them for reuse on another boot or machine.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ContinuousDeadline {
    pub seconds: i64,
    pub attoseconds: i64,
}
impl ContinuousDeadline {
    #[cfg(target_os = "macos")]
    pub fn now() -> Result<Self, crate::HostError> {
        let (seconds, nanoseconds) = crate::macos::continuous_time()?;
        Ok(Self {
            seconds,
            attoseconds: i64::from(nanoseconds) * 1_000_000_000,
        })
    }
    pub fn is_valid(self) -> bool {
        self.attoseconds.unsigned_abs() < 1_000_000_000_000_000_000
            && (self.seconds == 0
                || self.attoseconds == 0
                || self.seconds.signum() == self.attoseconds.signum())
    }
    pub fn expired_at(self, seconds: i64, nanoseconds: u32) -> Result<bool, crate::HostError> {
        if !self.is_valid() || seconds < 0 || nanoseconds >= 1_000_000_000 {
            return Err(crate::HostError::InvalidEvidence);
        }
        let deadline =
            i128::from(self.seconds) * 1_000_000_000_000_000_000 + i128::from(self.attoseconds);
        let now = i128::from(seconds) * 1_000_000_000_000_000_000
            + i128::from(nanoseconds) * 1_000_000_000;
        Ok(now >= deadline)
    }
    #[cfg(target_os = "macos")]
    pub fn expired(self) -> Result<bool, crate::HostError> {
        let (seconds, nanoseconds) = crate::macos::continuous_time()?;
        self.expired_at(seconds, nanoseconds)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn exact_signed_epoch_parts_keep_subnanosecond_and_extreme_boundaries() {
        let deadline = ContinuousDeadline {
            seconds: 1,
            attoseconds: 1,
        };
        assert!(!deadline.expired_at(1, 0).unwrap());
        assert!(deadline.expired_at(1, 1).unwrap());
        assert!(
            ContinuousDeadline {
                seconds: -1,
                attoseconds: -1
            }
            .expired_at(0, 0)
            .unwrap()
        );
        assert!(
            !ContinuousDeadline {
                seconds: i64::MAX,
                attoseconds: 999_999_999_999_999_999
            }
            .expired_at(i64::MAX, 999_999_999)
            .unwrap()
        );
        assert!(
            ContinuousDeadline {
                seconds: i64::MIN,
                attoseconds: -999_999_999_999_999_999
            }
            .expired_at(0, 0)
            .unwrap()
        );
    }
    #[test]
    fn noncanonical_parts_invalid_clock_values_and_unknown_fields_are_rejected() {
        for (seconds, attoseconds) in [
            (1, -1),
            (-1, 1),
            (0, i64::MIN),
            (0, 1_000_000_000_000_000_000),
        ] {
            assert!(
                !ContinuousDeadline {
                    seconds,
                    attoseconds
                }
                .is_valid()
            );
        }
        let value = ContinuousDeadline {
            seconds: 0,
            attoseconds: 0,
        };
        assert!(value.expired_at(-1, 0).is_err());
        assert!(value.expired_at(0, 1_000_000_000).is_err());
        assert!(
            serde_json::from_str::<ContinuousDeadline>(
                r#"{"seconds":0,"attoseconds":0,"clock":"wall"}"#
            )
            .is_err()
        );
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn native_continuous_epoch_read_is_ordered_and_zero_is_expired() {
        let first = crate::macos::continuous_time().unwrap();
        let second = crate::macos::continuous_time().unwrap();
        assert!(first <= second);
        assert!(
            ContinuousDeadline {
                seconds: 0,
                attoseconds: 0
            }
            .expired()
            .unwrap()
        );
        assert!(
            !ContinuousDeadline {
                seconds: i64::MAX,
                attoseconds: 0
            }
            .expired()
            .unwrap()
        );
    }
}
