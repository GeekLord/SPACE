use super::*;

fn labels(role: &str) -> BTreeMap<String, String> {
    BTreeMap::from([(NODE_ROLE_LABEL.to_string(), role.to_string())])
}

#[test]
fn node_role_label_defaults_to_worker() {
    assert_eq!(
        node_role_from_labels("node-a", None),
        Some(NodeRole::Worker)
    );
    assert_eq!(
        node_role_from_labels("node-a", Some(&BTreeMap::new())),
        Some(NodeRole::Worker)
    );
}

#[test]
fn node_role_label_parses_known_roles() {
    assert_eq!(
        node_role_from_labels("node-a", Some(&labels("worker"))),
        Some(NodeRole::Worker)
    );
    assert_eq!(
        node_role_from_labels("node-a", Some(&labels("builder"))),
        Some(NodeRole::Builder)
    );
    assert_eq!(
        node_role_from_labels("node-a", Some(&labels("cluster"))),
        Some(NodeRole::Cluster)
    );
}

#[test]
fn node_role_label_rejects_unknown_roles() {
    assert_eq!(node_role_from_labels("node-a", Some(&labels("gpu"))), None);
}

#[test]
fn demotion_snapshot_includes_live_nodes_outside_worker_selector() {
    let selected_workers = vec!["worker-a".to_string()];
    let all_live_nodes = HashSet::from(["builder-a".to_string(), "worker-a".to_string()]);

    let snapshot = demotion_membership_snapshot(&selected_workers, Some(all_live_nodes));

    assert_eq!(
        snapshot,
        Some(vec!["builder-a".to_string(), "worker-a".to_string()])
    );
}

#[test]
fn demotion_snapshot_fails_closed_without_both_credible_snapshots() {
    let selected_workers = vec!["worker-a".to_string()];
    let live_nodes = HashSet::from(["worker-a".to_string()]);

    assert_eq!(
        demotion_membership_snapshot(&[], Some(live_nodes.clone())),
        None
    );
    assert_eq!(demotion_membership_snapshot(&selected_workers, None), None);
    assert_eq!(
        demotion_membership_snapshot(&selected_workers, Some(HashSet::new())),
        None
    );
}
