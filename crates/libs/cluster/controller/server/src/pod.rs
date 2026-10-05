use pplx_space_common_core::types::SandboxId;

use k8s_openapi::api::core::v1::Pod;
use pplx_space_cluster_pool::PoolSlot;
use pplx_space_common_core::kubernetes::{
    NodeGroupPlacement, SandboxPodCommon, SandboxPodConfigValues, SandboxPodRequest,
    SandboxPoolPodMetadata, build_sandbox_pod, sandbox_pod_name,
};
use pplx_space_common_core::types::SandboxActivationAttemptId;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReadyPodMetadata {
    pub uid: String,
    pub pod_ip: String,
    pub node_name: String,
}

pub fn pool_pod_name(sandbox_id: SandboxId) -> String {
    sandbox_pod_name(sandbox_id, 1)
}

pub fn build_pool_pod(
    config: &SandboxPodConfigValues,
    slot: &PoolSlot,
    node_group_placement: Option<&NodeGroupPlacement>,
) -> Pod {
    let env = std::collections::BTreeMap::new();
    let content_hash = slot.content_hash.to_string();
    let shared_config = config.for_namespace(&slot.pod_namespace);
    build_sandbox_pod(
        &shared_config,
        SandboxPodRequest::Pooled {
            common: SandboxPodCommon {
                pod_name: &slot.pod_name,
                sandbox_id: slot.reserved_sandbox_id,
                execution_generation: 1,
                // A pool slot is one control-plane activation attempt: its ID
                // remains stable across Create/Wake retries and a replacement
                // slot receives a distinct ID.
                activation_attempt_id: Some(SandboxActivationAttemptId::from_uuid(slot.id)),
                template: slot.template_name.as_str(),
                content_hash: Some(&content_hash),
                env: &env,
                traceparent: None,
            },
            pool: SandboxPoolPodMetadata {
                slot_id: slot.id,
                config_id: slot.config_id,
                vcpu: slot.vcpu,
                memory: slot.memory,
                disk_mib: slot.disk_mib,
                disk_io_limits: slot.disk_io_limits,
            },
            // Warm pools are generic-only: a pooled pod carries no org
            // identity, so the caller resolves this set against no org at all
            // and it therefore names only generic groups and never a dedicated
            // target — which is exactly what the pod builder requires of an
            // org-less pod. `None` (the gate off, or a cluster with no generic
            // group) renders no node-group constraints.
            node_group_placement,
        },
    )
}

pub fn ready_pod_metadata(pod: &Pod) -> Option<ReadyPodMetadata> {
    if pod.metadata.deletion_timestamp.is_some() {
        return None;
    }

    let status = pod.status.as_ref()?;
    if status.phase.as_deref() != Some("Running") {
        return None;
    }
    if !pod_ready(status.conditions.as_deref()) {
        return None;
    }

    Some(ReadyPodMetadata {
        uid: pod.metadata.uid.clone()?,
        pod_ip: status.pod_ip.clone()?,
        node_name: pod.spec.as_ref()?.node_name.clone()?,
    })
}

pub(crate) fn pod_ready(conditions: Option<&[k8s_openapi::api::core::v1::PodCondition]>) -> bool {
    conditions
        .into_iter()
        .flatten()
        .any(|condition| condition.type_ == "Ready" && condition.status == "True")
}

#[cfg(test)]
mod tests;
