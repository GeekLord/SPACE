// VM boot and lifecycle for the template builder.
//
// Delegates to sbx-manager for sandbox lifecycle (Create/Start/Stop/Delete),
// which in turn delegates privileged operations to node-manager.

pub(crate) const TEMPLATE_DIR: &str = pplx_space_common_core::host::linux::paths::TEMPLATE_DIR;

/// Fixed guest IP — same for every sandbox, isolation via namespace NAT.
pub(crate) const GUEST_IP: &str = "169.254.0.21";

pub(crate) fn is_process_alive(pid: u32) -> bool {
    std::path::Path::new(&format!("/proc/{pid}")).exists()
}
