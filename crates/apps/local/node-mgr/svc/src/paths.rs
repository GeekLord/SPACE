//! Path + name derivation for local sandboxes.
//!
//! Reuses the canonical `pplx-space-common-core` host path helpers so the
//! instance/run directories line up exactly with what sandbox-manager writes
//! (e.g. the Full-codec rootfs reflink lands in the same `instance/rootfs.ext4`
//! this runtime reads and boots).

use std::path::PathBuf;

use pplx_space_common_svc::core::host::linux::paths;

/// Directory holding the per-sandbox bridge sockets (`bridge-guest.sock`,
/// `bridge-host.sock`). Bind-mounted into the nspawn guest so spaced-host and
/// spaced-guest can exchange the bridge over UDS instead of vsock.
pub fn bridge_dir(sandbox_id: &str) -> PathBuf {
    PathBuf::from(paths::sandbox_run_dir(sandbox_id)).join("bridge")
}

/// Host-side path of the bridge-guest socket (guest listens, spaced-host dials).
pub fn bridge_guest_socket(sandbox_id: &str) -> PathBuf {
    bridge_dir(sandbox_id).join("bridge-guest.sock")
}

/// Host-side path of the bridge-host socket (spaced-host listens, guest dials).
pub fn bridge_host_socket(sandbox_id: &str) -> PathBuf {
    bridge_dir(sandbox_id).join("bridge-host.sock")
}

/// Per-sandbox instance rootfs ext4 image that nspawn boots.
pub fn instance_rootfs(sandbox_id: &str) -> PathBuf {
    PathBuf::from(paths::sandbox_rootfs_path(sandbox_id))
}

/// Per-sandbox instance directory.
pub fn instance_dir(sandbox_id: &str) -> PathBuf {
    PathBuf::from(paths::sandbox_instance_dir(sandbox_id))
}

/// Per-sandbox cache root (`/space/cache/firecracker/sandboxes/<id>`), the
/// parent of `instance/` and `snapshots/`. The sandbox-manager cache reconciler
/// scans `SANDBOX_CACHE_DIR` and treats every UUID-named child as a live
/// sandbox, so a delete must remove this whole root — not just `instance/` — or
/// the leftover root resurrects the deleted sandbox as an orphan behind quarantine.
pub fn sandbox_cache_dir(sandbox_id: &str) -> PathBuf {
    PathBuf::from(paths::sandbox_cache_dir(sandbox_id))
}

/// Per-sandbox extracted rootfs tree that `systemd-nspawn --directory` boots.
/// Materialized from `rootfs.ext4` via `debugfs rdump` (no loop device / udev,
/// which `nspawn --image` would require and which kind pods don't provide).
pub fn instance_rootdir(sandbox_id: &str) -> PathBuf {
    instance_dir(sandbox_id).join("root")
}

/// nspawn `--directory` overlay root used to bind the bridge dir into the guest.
///
/// The guest's systemd unit binds its bridge sockets here (see the guest image),
/// so the host and guest agree on a single mount point.
pub const GUEST_BRIDGE_MOUNT: &str = "/run/space-bridge";

/// Short, collision-resistant sandbox label derived from the **trailing** hex of
/// the `id`. For `UUIDv7` ids the leading bytes are a millisecond timestamp — shared
/// by every sandbox created in the same ~65 s window — so a leading-prefix label
/// collides; the trailing bytes are the random `rand_b` field, so the tail is
/// unique. Used only for the nspawn machine name + synthetic namespace.
pub fn short_id(sandbox_id: &str) -> String {
    let compact: String = sandbox_id.chars().filter(|c| *c != '-').collect();
    let n = compact.len();
    compact[n.saturating_sub(12)..].to_string()
}

/// systemd-nspawn machine name for a sandbox. Machine names must be valid
/// hostnames (<=64 chars, `[a-z0-9-]`); the `space-` prefix + short id fits.
pub fn machine_name(sandbox_id: &str) -> String {
    format!("space-{}", short_id(sandbox_id))
}
