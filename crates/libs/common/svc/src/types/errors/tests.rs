use super::DomainParseError;

#[test]
fn field_context_prepends_paths() {
    let err = DomainParseError::new("invalid")
        .field("memory")
        .field("config");
    assert_eq!(err.to_string(), "config.memory: invalid");
}
