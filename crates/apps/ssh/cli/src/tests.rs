use super::openssh_set_env_value;

#[test]
fn openssh_set_env_value_leaves_simple_values_unquoted() {
    assert_eq!(
        openssh_set_env_value("abc_123:/bin").as_deref(),
        Some("abc_123:/bin")
    );
}

#[test]
fn openssh_set_env_value_quotes_spaces_and_escapes_specials() {
    assert_eq!(
        openssh_set_env_value("hello world").as_deref(),
        Some("\"hello world\"")
    );
    assert_eq!(
        openssh_set_env_value("a\"b\\c").as_deref(),
        Some("\"a\\\"b\\\\c\"")
    );
}

#[test]
fn openssh_set_env_value_rejects_line_breaks() {
    assert_eq!(openssh_set_env_value("line 1\nline 2"), None);
    assert_eq!(openssh_set_env_value("line 1\r\nline 2"), None);
}
