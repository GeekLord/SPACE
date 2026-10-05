/// Default per-sandbox disk operation rate used when a warm-pool configuration
/// has no explicit assignment.
pub const DEFAULT_DISK_IO_MAX_OPERATIONS_PER_SEC: u64 = 1_000;

/// Default per-sandbox disk bandwidth used when a warm-pool configuration has
/// no explicit assignment.
pub const DEFAULT_DISK_IO_MAX_BANDWIDTH_MIB_PER_SEC: u64 = 100;

const MIB_BYTES: u64 = 1024 * 1024;
const MAX_OPERATIONS_PER_SEC: u64 = i64::MAX as u64;
const MAX_BANDWIDTH_MIB_PER_SEC: u64 = u64::MAX / MIB_BYTES;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DiskIoLimits {
    max_operations_per_sec: u64,
    max_bandwidth_mib_per_sec: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
pub enum DiskIoLimitsError {
    #[error("disk I/O {field} must be greater than zero")]
    Zero { field: &'static str },
    #[error("disk I/O {field} value {value} exceeds the supported maximum {maximum}")]
    OutOfRange {
        field: &'static str,
        value: u64,
        maximum: u64,
    },
    #[error("disk I/O operations and bandwidth must either both be present or both be absent")]
    PartialPair,
}

impl DiskIoLimits {
    pub fn try_new(
        max_operations_per_sec: u64,
        max_bandwidth_mib_per_sec: u64,
    ) -> Result<Self, DiskIoLimitsError> {
        validate_positive("max_operations_per_sec", max_operations_per_sec)?;
        validate_positive("max_bandwidth_mib_per_sec", max_bandwidth_mib_per_sec)?;
        validate_maximum(
            "max_operations_per_sec",
            max_operations_per_sec,
            MAX_OPERATIONS_PER_SEC,
        )?;
        validate_maximum(
            "max_bandwidth_mib_per_sec",
            max_bandwidth_mib_per_sec,
            MAX_BANDWIDTH_MIB_PER_SEC,
        )?;
        Ok(Self {
            max_operations_per_sec,
            max_bandwidth_mib_per_sec,
        })
    }

    /// Resolves an optional wire pair against the platform defaults. Older
    /// writers omit both fields; a partial pair is malformed rather than a
    /// mixed-version state and must not silently acquire one default value.
    pub fn try_from_optional(
        max_operations_per_sec: Option<u64>,
        max_bandwidth_mib_per_sec: Option<u64>,
    ) -> Result<Self, DiskIoLimitsError> {
        match (max_operations_per_sec, max_bandwidth_mib_per_sec) {
            (None, None) => Ok(Self::default()),
            (Some(operations), Some(bandwidth)) => Self::try_new(operations, bandwidth),
            _ => Err(DiskIoLimitsError::PartialPair),
        }
    }

    pub const fn max_operations_per_sec(self) -> u64 {
        self.max_operations_per_sec
    }

    pub const fn max_bandwidth_mib_per_sec(self) -> u64 {
        self.max_bandwidth_mib_per_sec
    }
}

impl Default for DiskIoLimits {
    fn default() -> Self {
        Self {
            max_operations_per_sec: DEFAULT_DISK_IO_MAX_OPERATIONS_PER_SEC,
            max_bandwidth_mib_per_sec: DEFAULT_DISK_IO_MAX_BANDWIDTH_MIB_PER_SEC,
        }
    }
}

fn validate_positive(field: &'static str, value: u64) -> Result<(), DiskIoLimitsError> {
    if value == 0 {
        return Err(DiskIoLimitsError::Zero { field });
    }
    Ok(())
}

fn validate_maximum(
    field: &'static str,
    value: u64,
    maximum: u64,
) -> Result<(), DiskIoLimitsError> {
    if value > maximum {
        return Err(DiskIoLimitsError::OutOfRange {
            field,
            value,
            maximum,
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests;
