use super::*;

#[test]
fn constructor_accepts_supported_positive_limits() {
    let limits = DiskIoLimits::try_new(5_000, 200).unwrap();

    assert_eq!(limits.max_operations_per_sec(), 5_000);
    assert_eq!(limits.max_bandwidth_mib_per_sec(), 200);
}

#[test]
fn constructor_rejects_zero_and_unrepresentable_limits() {
    assert!(matches!(
        DiskIoLimits::try_new(0, 200),
        Err(DiskIoLimitsError::Zero {
            field: "max_operations_per_sec"
        })
    ));
    assert!(matches!(
        DiskIoLimits::try_new(5_000, 0),
        Err(DiskIoLimitsError::Zero {
            field: "max_bandwidth_mib_per_sec"
        })
    ));
    DiskIoLimits::try_new(MAX_OPERATIONS_PER_SEC, 200).unwrap();
    assert!(matches!(
        DiskIoLimits::try_new(MAX_OPERATIONS_PER_SEC + 1, 200),
        Err(DiskIoLimitsError::OutOfRange {
            field: "max_operations_per_sec",
            ..
        })
    ));
    DiskIoLimits::try_new(5_000, MAX_BANDWIDTH_MIB_PER_SEC).unwrap();
    assert!(matches!(
        DiskIoLimits::try_new(5_000, MAX_BANDWIDTH_MIB_PER_SEC + 1),
        Err(DiskIoLimitsError::OutOfRange {
            field: "max_bandwidth_mib_per_sec",
            ..
        })
    ));
}

#[test]
fn optional_wire_fields_are_paired() {
    assert_eq!(
        DiskIoLimits::try_from_optional(None, None).unwrap(),
        DiskIoLimits::default()
    );
    assert_eq!(
        DiskIoLimits::try_from_optional(Some(5_000), Some(200)).unwrap(),
        DiskIoLimits::try_new(5_000, 200).unwrap()
    );
    assert!(matches!(
        DiskIoLimits::try_from_optional(Some(5_000), None),
        Err(DiskIoLimitsError::PartialPair)
    ));
    assert!(matches!(
        DiskIoLimits::try_from_optional(None, Some(200)),
        Err(DiskIoLimitsError::PartialPair)
    ));
}
