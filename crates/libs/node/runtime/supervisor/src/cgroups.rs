use std::fs;

use pplx_space_common_core::types::SandboxId;
use pplx_space_node_runtime_core::cgroup;
use tokio::sync::OwnedSemaphorePermit;
use tonic::Status;

pub(crate) async fn apply_firecracker_cgroup_fixups(
    sandbox_id: SandboxId,
    fc_pid: u32,
    blocking_slot: OwnedSemaphorePermit,
) {
    let sandbox_id = sandbox_id.to_string();
    let sandbox_id_for_log = sandbox_id.clone();
    if let Err(error) = tokio::task::spawn_blocking(move || {
        let _blocking_slot = blocking_slot;
        let swap_max = format!("/sys/fs/cgroup/space/{sandbox_id}/memory.swap.max");
        if let Err(error) = fs::write(&swap_max, "0") {
            tracing::debug!(sandbox_id, path = %swap_max, error = %error, "failed to set firecracker swap limit");
        }

        let task_dir = format!("/proc/{fc_pid}/task");
        let cgroup_procs = format!("/sys/fs/cgroup/space/{sandbox_id}/cgroup.procs");
        let Ok(entries) = fs::read_dir(&task_dir) else {
            return;
        };
        for entry in entries.flatten() {
            let comm_path = entry.path().join("comm");
            if let Ok(name) = fs::read_to_string(&comm_path)
                && name.trim().starts_with("kvm-pit")
            {
                let tid = entry.file_name().to_string_lossy().to_string();
                if let Err(error) = fs::write(&cgroup_procs, &tid) {
                    tracing::debug!(sandbox_id, tid, path = %cgroup_procs, error = %error, "failed to move kvm-pit thread into firecracker cgroup");
                }
            }
        }
    })
    .await
    {
        tracing::debug!(sandbox_id = %sandbox_id_for_log, error = %error, "firecracker cgroup fixup task failed");
    }
}

pub(crate) async fn remove_sandbox_cgroups_blocking(
    sandbox_id: SandboxId,
    blocking_slot: OwnedSemaphorePermit,
) -> Result<Vec<String>, Status> {
    let sandbox_id = sandbox_id.to_string();
    let report = tokio::task::spawn_blocking({
        let sandbox_id = sandbox_id.clone();
        move || {
            let _blocking_slot = blocking_slot;
            cgroup::remove_sandbox_cgroups_with_report(&sandbox_id)
        }
    })
    .await
    .map_err(|error| Status::internal(format!("cgroup cleanup task failed: {error}")))?
    .map_err(|errors| Status::internal(format!("remove sandbox cgroups: {}", errors.join("; "))))?;

    if report.paths_present == 0 && report.killed_pids == 0 {
        return Ok(Vec::new());
    }

    tracing::info!(
        sandbox_id,
        cgroup_paths_present = report.paths_present,
        cgroup_paths_removed = report.paths_removed,
        cgroup_remove_attempts = report.attempts,
        cgroup_kill_requests = report.cgroup_kill_requests,
        cgroup_killed_pids = report.killed_pids,
        "runtime supervisor cgroup cleanup summary"
    );
    Ok(vec!["Removed sandbox cgroups".to_string()])
}

pub(crate) fn cgroup_update_error_to_status(error: cgroup::CgroupUpdateError) -> Status {
    match error {
        cgroup::CgroupUpdateError::NotFound(_) => Status::not_found(error.to_string()),
        cgroup::CgroupUpdateError::Invalid(_) => Status::invalid_argument(error.to_string()),
        cgroup::CgroupUpdateError::Read { .. } => Status::unavailable(error.to_string()),
        cgroup::CgroupUpdateError::Write { .. } => Status::internal(error.to_string()),
    }
}
