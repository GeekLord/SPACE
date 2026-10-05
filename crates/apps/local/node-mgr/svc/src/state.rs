//! In-memory registry of sandboxes managed by the local runtime.
//!
//! The local runtime is intentionally stateless across restarts (a laptop/CI
//! harness, not a durable node); on-disk artifacts under `/space/cache` are the
//! only persistence and sandbox-manager owns recovery.

use std::sync::atomic::{AtomicU32, Ordering};

use dashmap::DashMap;

use crate::paths;

/// First synthetic slot. Slot `0` is reserved/unused so a zero never reads as a
/// real lease.
const FIRST_SLOT: u32 = 1;

/// Base for slot-derived sandbox UIDs. sandbox-manager validates that the UID is
/// `>= 10000` (the non-system range), so the base must clear that bar.
const UID_BASE: u32 = 10_000;

/// Per-sandbox state tracked by the runtime.
#[derive(Clone, Debug)]
pub struct SandboxEntry {
    pub slot: u32,
    pub uid: u32,
    pub machine: String,
    pub template: Option<String>,
    pub nspawn_pid: Option<u32>,
    pub spaced_host_pid: Option<u32>,
    /// The no-op net-gateway placeholder (`sleep`) PID, tracked so cleanup can
    /// reap it instead of leaking one per sandbox until the pod exits.
    pub netgtw_pid: Option<u32>,
    pub paused: bool,
}

/// Thread-safe sandbox registry with monotonic slot allocation.
#[derive(Default)]
pub struct Registry {
    execution_fences: DashMap<String, pplx_space_node_mgr_client::execution_fence::ExecutionFence>,
    sandboxes: DashMap<String, SandboxEntry>,
    next_slot: SlotCounter,
}

struct SlotCounter(AtomicU32);

impl Default for SlotCounter {
    fn default() -> Self {
        Self(AtomicU32::new(FIRST_SLOT))
    }
}

impl Registry {
    pub fn execution(
        &self,
        sandbox_id: &str,
    ) -> Option<pplx_space_node_mgr_client::execution_fence::ExecutionFence> {
        self.execution_fences.get(sandbox_id).map(|fence| *fence)
    }

    pub fn bind_execution(
        &self,
        sandbox_id: &str,
        fence: pplx_space_node_mgr_client::execution_fence::ExecutionFence,
    ) {
        self.execution_fences.insert(sandbox_id.to_owned(), fence);
    }

    pub fn retire_execution(&self, sandbox_id: &str) {
        self.execution_fences.remove(sandbox_id);
    }

    /// Allocate (idempotently) a slot + UID for a sandbox, returning the entry.
    pub fn allocate(&self, sandbox_id: &str) -> SandboxEntry {
        if let Some(existing) = self.sandboxes.get(sandbox_id) {
            return existing.clone();
        }
        let slot = self.next_slot.0.fetch_add(1, Ordering::Relaxed);
        let entry = SandboxEntry {
            slot,
            uid: UID_BASE + slot,
            machine: paths::machine_name(sandbox_id),
            template: None,
            nspawn_pid: None,
            spaced_host_pid: None,
            netgtw_pid: None,
            paused: false,
        };
        self.sandboxes.insert(sandbox_id.to_string(), entry.clone());
        entry
    }

    /// Ensure an entry exists for a sandbox (used by handlers that may run before
    /// `Allocate` during recovery), returning the current entry.
    pub fn ensure(&self, sandbox_id: &str) -> SandboxEntry {
        self.allocate(sandbox_id)
    }

    pub fn get(&self, sandbox_id: &str) -> Option<SandboxEntry> {
        self.sandboxes.get(sandbox_id).map(|e| e.clone())
    }

    pub fn set_template(&self, sandbox_id: &str, template: Option<String>) {
        if let Some(mut e) = self.sandboxes.get_mut(sandbox_id) {
            e.template = template;
        }
    }

    pub fn set_nspawn_pid(&self, sandbox_id: &str, pid: u32) {
        if let Some(mut e) = self.sandboxes.get_mut(sandbox_id) {
            e.nspawn_pid = Some(pid);
            e.paused = false;
        }
    }

    pub fn set_spaced_host_pid(&self, sandbox_id: &str, pid: u32) {
        if let Some(mut e) = self.sandboxes.get_mut(sandbox_id) {
            e.spaced_host_pid = Some(pid);
        }
    }

    pub fn set_netgtw_pid(&self, sandbox_id: &str, pid: u32) {
        if let Some(mut e) = self.sandboxes.get_mut(sandbox_id) {
            e.netgtw_pid = Some(pid);
        }
    }

    pub fn set_paused(&self, sandbox_id: &str, paused: bool) {
        if let Some(mut e) = self.sandboxes.get_mut(sandbox_id) {
            e.paused = paused;
        }
    }

    pub fn remove(&self, sandbox_id: &str) -> Option<SandboxEntry> {
        self.sandboxes.remove(sandbox_id).map(|(_, e)| e)
    }

    /// Snapshot of all live entries (id, entry).
    pub fn entries(&self) -> Vec<(String, SandboxEntry)> {
        self.sandboxes
            .iter()
            .map(|e| (e.key().clone(), e.value().clone()))
            .collect()
    }
}
