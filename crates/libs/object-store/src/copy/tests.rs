use super::*;

#[test]
fn copy_source_keeps_path_separators_and_encodes_digest_colons() {
    assert_eq!(
        copy_source_value(
            "example-template-artifacts",
            "templates/seed/sha256:3c36fb1e/rootfs.ext4.zst",
        ),
        "example-template-artifacts/templates/seed/sha256%3A3c36fb1e/rootfs.ext4.zst",
    );
}

#[test]
fn copy_source_encodes_characters_that_would_break_the_header() {
    // Not shapes a validated TemplateName/ContentHash can produce; the
    // encoder is the boundary that keeps that true even if a caller ever
    // hands over a raw key.
    assert_eq!(
        copy_source_value("bucket", "a b/c?d#e%f"),
        "bucket/a%20b/c%3Fd%23e%25f",
    );
}

/// The whole reason the threshold exists: every size above it must plan
/// into parts that are each themselves copyable.
#[test]
fn every_multipart_copy_part_stays_within_the_single_copy_limit() {
    let part_size = usize::try_from(MAX_SINGLE_COPY_BYTES).unwrap();
    for size in [
        MAX_SINGLE_COPY_BYTES + 1,
        6 * 1024 * 1024 * 1024,
        21 * 1024 * 1024 * 1024,
    ] {
        let ranges = multipart_part_ranges(size, part_size);
        assert!(
            ranges.len() > 1,
            "size={size} planned to {} part(s)",
            ranges.len()
        );
        let mut offset = 0;
        for range in &ranges {
            assert_eq!(range.offset, offset, "size={size} gap or overlap");
            assert!(
                range.length <= MAX_SINGLE_COPY_BYTES,
                "size={size} part {} is {} bytes",
                range.part_number,
                range.length,
            );
            offset += range.length;
        }
        assert_eq!(offset, size, "size={size} parts do not cover the object");
    }
}
