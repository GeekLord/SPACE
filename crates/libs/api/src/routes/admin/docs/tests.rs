use super::{ADMIN_LLMS_TXT, admin_openapi_value};
use std::collections::BTreeMap;

#[test]
fn admin_openapi_stub_is_admin_only() {
    let spec = admin_openapi_value();

    assert_eq!(spec["openapi"], "3.1.0");
    assert_eq!(spec["servers"][0]["url"], "/v1");
    let paths = spec["paths"]
        .as_object()
        .expect("paths should be an object");

    // The admin mount never republishes the public-API-prefixed path.
    assert!(!paths.contains_key("/v1/sandboxes"));

    // Pin the full sorted path -> HTTP-method set. A superset of every
    // `contains_key`/`get(method).is_some()` check the old ladder ran: an
    // unexpected route (or a route missing an expected method) shows up as a
    // snapshot diff instead of silently compiling.
    let paths_by_method: BTreeMap<&str, Vec<&str>> = paths
        .iter()
        .map(|(path, item)| {
            let mut methods: Vec<&str> = item
                .as_object()
                .expect("path item should be an object")
                .keys()
                .map(String::as_str)
                .collect();
            methods.sort_unstable();
            (path.as_str(), methods)
        })
        .collect();
    insta::assert_json_snapshot!(paths_by_method);
}

#[test]
fn admin_llms_txt_advertises_admin_roots() {
    assert!(ADMIN_LLMS_TXT.contains("SPACE Admin API"));
    assert!(ADMIN_LLMS_TXT.contains("/openapi.json on admin.api.space hosts"));
    assert!(ADMIN_LLMS_TXT.contains("/admin/api/openapi.json on shared hosts"));
    assert!(ADMIN_LLMS_TXT.contains("/v1 on admin.api.space hosts"));
    assert!(ADMIN_LLMS_TXT.contains("/admin/api/v1 on shared hosts"));
    assert!(ADMIN_LLMS_TXT.contains("/e2b/api on shared hosts"));
}
