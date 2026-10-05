use super::*;

#[test]
fn adoption_requires_all_uid_and_gid_credentials() {
    for (status, expected) in [
        (
            "Uid:\t10000 10000 10000 10000\nGid:\t10000 10000 10000 10000\n",
            true,
        ),
        (
            "Uid:\t10000 10000 10000 10000\nGid:\t2000000 2000000 2000000 2000000\n",
            false,
        ),
        (
            "Uid:\t10000 10000 0 10000\nGid:\t10000 10000 10000 10000\n",
            false,
        ),
        ("Uid:\t10000 10000\nGid:\t10000 10000 10000 10000\n", false),
        ("Uid:\t10000 10000 10000 10000\n", false),
    ] {
        assert_eq!(credentials_match(status, 10000, 10000), expected);
    }
}
