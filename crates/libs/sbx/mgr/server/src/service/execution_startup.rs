use super::*;

impl SandboxManagerService {
    /// Run under the process mutex and dependency work gate, before recovery.
    /// Never invent authority for an old row: the adoption baseline owns that
    /// one-time transition while both old and new receivers are available.
    pub(crate) async fn prepare_execution_authority(&self) -> Result<(), Status> {
        let mut client = pplx_space_node_mgr_client::connect()
            .await
            .map_err(|error| {
                Status::unavailable(format!("connect for execution preflight: {error}"))
            })?;
        pplx_space_node_mgr_client::execution_fence::inspect_execution(
            &mut client,
            SandboxId::new(),
        )
        .await?;
        let db = self.db.clone();
        tokio::task::spawn_blocking(move || {
            let db = db
                .lock()
                .map_err(|_| Status::unavailable("sandbox database mutex poisoned"))?;
            let unadopted = crate::db::unbound_node_executions(&db).map_err(|error| {
                Status::unavailable(format!("read execution preflight: {error}"))
            })?;
            pplx_space_node_mgr_client::execution_fence::execution_preflight_result(&unadopted)
        })
        .await
        .map_err(|error| Status::unavailable(format!("execution preflight task: {error}")))?
    }
}
