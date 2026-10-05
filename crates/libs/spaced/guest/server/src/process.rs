use super::*;
use crate::filesystem::map_io_error;
use crate::guest_path;
use crate::idempotency::{IdempotencyLookup, IdempotencyRecord, require_idempotency_key};
use crate::identity::GuestAccount;
use dashmap::DashMap;
use pplx_space_common_core::types::{GuestUserName, Pii, ProcessCommand, ProcessId, ProcessSignal};
use std::os::fd::{AsFd, AsRawFd, OwnedFd, RawFd};
use std::sync::Weak;
use std::{collections::VecDeque, io};
use tokio::io::AsyncRead;
use tokio::sync::{OwnedSemaphorePermit, Semaphore, TryAcquireError};

mod pty;
use pty::PtyIo;

const DEFAULT_LOGIN_PATH: &str = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
const DEFAULT_PTY_ROWS: u32 = 24;
const DEFAULT_PTY_COLS: u32 = 80;

// Charge payloads and event storage, including each repeated process ID: tiny
// writes must not turn a bounded output window into millions of allocations.
// A lagging stream fails explicitly without blocking completion or other clients.
const PROCESS_OUTPUT_RETENTION_TOTAL_BYTES: usize = 64 * 1024 * 1024;
// Process records retain command/env metadata and task-owned descriptors, so
// cap them as well as the output bytes. Completed records are evicted first
// under pressure; if every slot belongs to a running process, admission fails.
const PROCESS_RECORD_LIMIT: usize = 128;
const PROCESS_OUTPUT_RETENTION_BYTES: usize = 4 * 1024 * 1024;
// Every admitted record can retain a useful stream-sized floor without
// competing globally. Larger replay windows borrow from the shared burst pool;
// exhaustion evicts only that process's older output.
const PROCESS_OUTPUT_GUARANTEED_BYTES: usize = 256 * 1024;
const PROCESS_OUTPUT_SHARED_BYTES: usize =
    PROCESS_OUTPUT_RETENTION_TOTAL_BYTES - PROCESS_RECORD_LIMIT * PROCESS_OUTPUT_GUARANTEED_BYTES;
const PROCESS_OUTPUT_DRAIN_TIMEOUT: Duration = Duration::from_secs(1);
const PROCESS_OUTPUT_LAGGED_MESSAGE: &str =
    "process output stream fell behind retained output buffer";
const PROCESS_CAPACITY_MESSAGE: &str = "too many retained processes";

impl SpacedGuestService {
    pub(super) fn process_grpc_service(
        &self,
    ) -> pplx_space_common_grpc::RequestAdmission<ProcessServer<Self>> {
        use pplx_space_spaced_common::process_limits;
        pplx_space_common_grpc::RequestAdmission::new(
            ProcessServer::new(self.clone())
                .max_decoding_message_size(process_limits::MAX_MESSAGE_BYTES),
            self.inner.process_payload_slots.clone(),
            process_limits::PAYLOAD_METHODS,
        )
    }
}

#[derive(Debug)]
enum ProcessStartAdmission {
    Ingress {
        _permit: pplx_space_common_grpc::RequestPermit,
    },
    Direct {
        _permit: OwnedSemaphorePermit,
    },
}

async fn resolve_process_account(
    slots: Arc<Semaphore>,
    ingress: Option<pplx_space_common_grpc::RequestPermit>,
    resolve: impl FnOnce() -> Result<GuestAccount, Status> + Send + 'static,
) -> Result<(GuestAccount, ProcessStartAdmission), Status> {
    let admission = match ingress {
        Some(permit) => ProcessStartAdmission::Ingress { _permit: permit },
        None => ProcessStartAdmission::Direct {
            _permit: slots
                .try_acquire_many_owned(
                    pplx_space_spaced_common::process_limits::START_PAYLOAD_SLOTS,
                )
                .map_err(|_| Status::resource_exhausted("payload request capacity exhausted"))?,
        },
    };
    // NSS may block on external account providers. Keep the existing Start
    // admission with the physical lookup even if its requesting future drops.
    tokio::task::spawn_blocking(move || resolve().map(|account| (account, admission)))
        .await
        .map_err(|error| Status::internal(format!("guest account lookup task failed: {error}")))?
}

// TODO(spaced): persist or reconstruct the process registry if callers need
// connect/list/process-id stability across guest-svc restart. Today process IDs
// are process-local UUIDs, so a guest-svc crash loses pid→process_id mappings.
#[derive(Clone)]
pub(super) struct ProcessRegistry {
    records: Arc<DashMap<ProcessId, Arc<ProcessRecord>>>,
    record_slots: Arc<Semaphore>,
    shared_output_slots: Arc<Semaphore>,
}

struct ProcessRecord {
    // RPCs can retain a completed record beyond registry eviction.
    _record_slot: OwnedSemaphorePermit,
    started: ProcessEvent,
    info: ProcessInfo,
    input: ProcessInput,
    signal_handle: ProcessSignalHandle,
    journal: Arc<ProcessEventJournal>,
}

impl ProcessRecord {
    fn new(
        started: ProcessEvent,
        info: ProcessInfo,
        input: ProcessInput,
        signal_handle: ProcessSignalHandle,
        reservation: ProcessRecordReservation,
    ) -> Self {
        Self {
            _record_slot: reservation.record_slot,
            started,
            info,
            input,
            signal_handle,
            journal: Arc::new(ProcessEventJournal::new(reservation.shared_output_slots)),
        }
    }

    async fn write_stdin(&self, data: &[u8]) -> Result<(), Status> {
        self.input.write(data).await
    }

    async fn close_stdin(&self) -> Result<(), Status> {
        self.input.close().await
    }

    fn resize_pty(&self, size: PtySize) -> Result<(), Status> {
        self.input.resize_pty(size)
    }
}

impl Default for ProcessRegistry {
    fn default() -> Self {
        Self {
            records: Arc::new(DashMap::new()),
            record_slots: Arc::new(Semaphore::new(PROCESS_RECORD_LIMIT)),
            shared_output_slots: Arc::new(Semaphore::new(PROCESS_OUTPUT_SHARED_BYTES)),
        }
    }
}

struct ProcessRecordReservation {
    record_slot: OwnedSemaphorePermit,
    shared_output_slots: Arc<Semaphore>,
}

enum ProcessInput {
    Disabled,
    Pipe(Mutex<Option<tokio::process::ChildStdin>>),
    Pty(PtyInput),
}

struct PtyInput {
    writer: Mutex<PtyIo>,
    resize_fd: PtyIo,
}

impl ProcessInput {
    async fn write(&self, data: &[u8]) -> Result<(), Status> {
        match self {
            Self::Disabled => Err(Status::failed_precondition(
                "process stdin is not enabled or closed",
            )),
            Self::Pipe(stdin) => {
                let mut stdin = stdin.lock().await;
                let stdin = stdin.as_mut().ok_or_else(|| {
                    Status::failed_precondition("process stdin is not enabled or closed")
                })?;
                stdin.write_all(data).await.map_err(map_io_error)?;
                stdin.flush().await.map_err(map_io_error)
            }
            Self::Pty(pty) => {
                let mut writer = pty.writer.lock().await;
                writer.write_all(data).await.map_err(map_io_error)?;
                writer.flush().await.map_err(map_io_error)
            }
        }
    }

    async fn close(&self) -> Result<(), Status> {
        match self {
            Self::Disabled => Ok(()),
            Self::Pipe(stdin) => {
                if let Some(mut stdin) = stdin.lock().await.take() {
                    stdin.shutdown().await.map_err(map_io_error)?;
                }
                Ok(())
            }
            Self::Pty(_) => Err(Status::failed_precondition(
                "PTY input cannot be half-closed; send terminal EOF or signal the process",
            )),
        }
    }

    fn resize_pty(&self, size: PtySize) -> Result<(), Status> {
        match self {
            Self::Pty(pty) => set_pty_size(&pty.resize_fd, size),
            Self::Disabled | Self::Pipe(_) => {
                Err(Status::failed_precondition("process is not pty-backed"))
            }
        }
    }
}

struct PreparedPty {
    reader: PtyIo,
    writer: PtyIo,
    resize_fd: PtyIo,
    control_fd: OwnedFd,
}

fn prepare_pty(size: Option<PtySize>) -> Result<PreparedPty, Status> {
    let winsize = pty_winsize(size)?;
    let nix::pty::OpenptyResult {
        master,
        slave: control_fd,
    } = nix::pty::openpty(Some(&winsize), None).map_err(|error| map_io_error(error.into()))?;
    set_cloexec(&master)?;
    set_cloexec(&control_fd)?;
    let master = PtyIo::new(master).map_err(map_io_error)?;

    Ok(PreparedPty {
        reader: master.clone(),
        writer: master.clone(),
        resize_fd: master,
        control_fd,
    })
}

fn pty_winsize(size: Option<PtySize>) -> Result<libc::winsize, Status> {
    let rows = size.as_ref().map_or(DEFAULT_PTY_ROWS, |size| size.rows);
    let cols = size.as_ref().map_or(DEFAULT_PTY_COLS, |size| size.cols);
    if rows == 0 || cols == 0 {
        return Err(Status::invalid_argument(
            "pty rows and cols must be non-zero",
        ));
    }
    let rows =
        u16::try_from(rows).map_err(|_| Status::invalid_argument("pty rows is too large"))?;
    let cols =
        u16::try_from(cols).map_err(|_| Status::invalid_argument("pty cols is too large"))?;
    Ok(libc::winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    })
}

fn set_pty_size(fd: impl AsFd, size: PtySize) -> Result<(), Status> {
    let size = pty_winsize(Some(size))?;
    rustix::termios::tcsetwinsize(
        fd,
        rustix::termios::Winsize {
            ws_row: size.ws_row,
            ws_col: size.ws_col,
            ws_xpixel: size.ws_xpixel,
            ws_ypixel: size.ws_ypixel,
        },
    )
    .map_err(|error| map_io_error(error.into()))
}

fn configure_child_pty(control_fd: RawFd) -> io::Result<()> {
    // SAFETY: `control_fd` is the pty slave fd inherited by the forked child.
    // `login_tty` creates a new session, makes the slave the controlling
    // terminal, duplicates it onto stdin/stdout/stderr, and closes the original
    // fd before exec.
    let result = unsafe { libc::login_tty(control_fd) };
    if result < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

struct ProcessSignalHandle {
    pid: u32,
    #[cfg(target_os = "linux")]
    pidfd: OwnedFd,
}

#[cfg(target_os = "linux")]
struct ProcessExitObserver {
    pidfd: tokio::io::unix::AsyncFd<OwnedFd>,
}

impl ProcessSignalHandle {
    #[cfg(target_os = "linux")]
    fn open(pid: u32) -> io::Result<(Self, ProcessExitObserver)> {
        let raw_pid = i32::try_from(pid)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;
        let process_pid = rustix::process::Pid::from_raw(raw_pid)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "pid must be positive"))?;
        let pidfd = rustix::process::pidfd_open(process_pid, rustix::process::PidfdFlags::empty())?;
        // Keep independent ownership for signal delivery and exit observation.
        let observer_fd = pidfd.try_clone()?;
        let observer = ProcessExitObserver {
            pidfd: tokio::io::unix::AsyncFd::new(observer_fd)?,
        };
        Ok((Self { pid, pidfd }, observer))
    }

    #[cfg(not(target_os = "linux"))]
    fn open(pid: u32) -> io::Result<(Self, ())> {
        i32::try_from(pid).map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;
        Ok((Self { pid }, ()))
    }

    fn signal(&self, signal: ProcessSignal) -> Result<(), Status> {
        #[cfg(target_os = "linux")]
        {
            match pplx_space_common_core::host::linux::signal_pidfd(&self.pidfd, signal) {
                Ok(()) => Ok(()),
                Err(error) if error.raw_os_error() == Some(libc::ESRCH) => {
                    Err(Status::not_found("process not found"))
                }
                Err(error) => Err(Status::internal(error.to_string())),
            }
        }
        #[cfg(not(target_os = "linux"))]
        {
            nix::sys::signal::kill(
                nix::unistd::Pid::from_raw(self.pid as i32),
                nix::sys::signal::Signal::try_from(signal.as_i32())
                    .map_err(|_| Status::invalid_argument("invalid signal"))?,
            )
            .map_err(|error| Status::internal(error.to_string()))
        }
    }

    fn terminate_group(&self) -> io::Result<()> {
        let process_group = i32::try_from(self.pid)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;
        // Linux callers keep the leader unreaped, pinning the group identity.
        match nix::sys::signal::killpg(
            nix::unistd::Pid::from_raw(process_group),
            nix::sys::signal::Signal::SIGKILL,
        ) {
            Ok(()) | Err(nix::errno::Errno::ESRCH) => Ok(()),
            Err(error) => Err(error.into()),
        }
    }
}

#[cfg(target_os = "linux")]
impl ProcessExitObserver {
    async fn exited(&self) -> io::Result<()> {
        // pidfds become readable when the child exits and stay readable. We do
        // not reap here, so its pid continues to pin the process-group id until
        // descendants have been terminated.
        self.pidfd.readable().await.map(|_| ())
    }
}

fn set_cloexec(fd: impl AsFd) -> Result<(), Status> {
    use nix::fcntl::{FcntlArg, FdFlag, fcntl};
    let flags = FdFlag::from_bits_retain(
        fcntl(fd.as_fd(), FcntlArg::F_GETFD).map_err(|error| map_io_error(error.into()))?,
    );
    fcntl(fd, FcntlArg::F_SETFD(flags | FdFlag::FD_CLOEXEC))
        .map_err(|error| map_io_error(error.into()))?;
    Ok(())
}

struct ProcessEventJournal {
    state: std::sync::Mutex<ProcessJournalState>,
    changed: watch::Sender<ProcessJournalChange>,
    shared_output_slots: Arc<Semaphore>,
}

impl ProcessEventJournal {
    fn new(shared_output_slots: Arc<Semaphore>) -> Self {
        let (changed, _) = watch::channel(ProcessJournalChange::OutputChanged);
        Self {
            state: std::sync::Mutex::new(ProcessJournalState::default()),
            changed,
            shared_output_slots,
        }
    }

    fn subscribe(&self) -> watch::Receiver<ProcessJournalChange> {
        self.changed.subscribe()
    }

    fn tail_cursor(&self) -> u64 {
        self.state
            .lock()
            .expect("process output journal lock poisoned")
            .next_sequence
    }

    fn exit(&self) -> Option<ProcessEvent> {
        self.state
            .lock()
            .expect("process output journal lock poisoned")
            .exit
            .clone()
    }

    fn is_completed(&self) -> bool {
        self.state
            .lock()
            .expect("process output journal lock poisoned")
            .exit
            .is_some()
    }

    fn is_expired(&self) -> bool {
        self.state
            .lock()
            .expect("process output journal lock poisoned")
            .completed_at
            .is_some_and(|completed_at| completed_at.elapsed() > IDEMPOTENCY_RECORD_TTL)
    }

    fn completed_at(&self) -> Option<Instant> {
        self.state
            .lock()
            .expect("process output journal lock poisoned")
            .completed_at
    }

    fn append_output(&self, event: ProcessEvent) {
        let output_bytes = match event.event.as_ref() {
            Some(pplx_space_spaced_common::proto::bridge_guest::process_event::Event::Stdout(
                output,
            ))
            | Some(pplx_space_spaced_common::proto::bridge_guest::process_event::Event::Stderr(
                output,
            )) => {
                output.data.capacity()
                    + event.process_id.capacity()
                    + std::mem::size_of::<SequencedProcessEvent>()
            }
            _ => unreachable!("process journal only retains output events"),
        };
        if output_bytes > PROCESS_OUTPUT_RETENTION_BYTES {
            {
                let mut state = self
                    .state
                    .lock()
                    .expect("process output journal lock poisoned");
                state.output.clear();
                state.retained_bytes = 0;
                state.guaranteed_bytes = 0;
                state.next_sequence += 1;
                state.first_sequence = state.next_sequence;
            }
            self.changed
                .send_replace(ProcessJournalChange::OutputChanged);
            return;
        }
        {
            let mut state = self
                .state
                .lock()
                .expect("process output journal lock poisoned");
            let sequence = state.next_sequence;
            while state.retained_bytes.saturating_add(output_bytes) > PROCESS_OUTPUT_RETENTION_BYTES
            {
                evict_oldest_process_output(&mut state);
            }
            state.next_sequence += 1;
            let shared_output_slot = loop {
                let guaranteed_bytes = output_bytes
                    .min(PROCESS_OUTPUT_GUARANTEED_BYTES.saturating_sub(state.guaranteed_bytes));
                let shared_bytes = output_bytes - guaranteed_bytes;
                let shared_output_slot = if shared_bytes == 0 {
                    None
                } else {
                    match self
                        .shared_output_slots
                        .clone()
                        .try_acquire_many_owned(shared_bytes as u32)
                    {
                        Ok(slot) => Some(slot),
                        Err(TryAcquireError::NoPermits | TryAcquireError::Closed)
                            if !state.output.is_empty() =>
                        {
                            evict_oldest_process_output(&mut state);
                            continue;
                        }
                        Err(TryAcquireError::NoPermits | TryAcquireError::Closed) => {
                            state.first_sequence = state.next_sequence;
                            break None;
                        }
                    }
                };
                state.guaranteed_bytes += guaranteed_bytes;
                break Some((guaranteed_bytes, shared_output_slot));
            };
            let Some((guaranteed_bytes, shared_output_slot)) = shared_output_slot else {
                drop(state);
                self.changed
                    .send_replace(ProcessJournalChange::OutputChanged);
                return;
            };
            state.retained_bytes += output_bytes;
            state.output.push_back(SequencedProcessEvent {
                sequence,
                event,
                output_bytes,
                guaranteed_bytes,
                _shared_output_slot: shared_output_slot,
            });
        }
        self.changed
            .send_replace(ProcessJournalChange::OutputChanged);
    }

    fn complete(&self, exit: ProcessEvent) {
        let next_sequence = {
            let mut state = self
                .state
                .lock()
                .expect("process output journal lock poisoned");
            state.exit = Some(exit.clone());
            state.completed_at = Some(Instant::now());
            state.next_sequence
        };
        self.changed.send_replace(ProcessJournalChange::Exit {
            event: exit,
            next_sequence,
        });
    }

    fn read(&self, cursor: u64) -> ProcessJournalRead {
        let state = self
            .state
            .lock()
            .expect("process output journal lock poisoned");
        if cursor < state.first_sequence {
            return ProcessJournalRead::Lagged;
        }
        if cursor < state.next_sequence {
            let offset = (cursor - state.first_sequence) as usize;
            return ProcessJournalRead::Event(
                state
                    .output
                    .get(offset)
                    .expect("process cursor within retained output window")
                    .event
                    .clone(),
            );
        }
        state
            .exit
            .clone()
            .map_or(ProcessJournalRead::Pending, ProcessJournalRead::Exit)
    }
}

#[derive(Default)]
struct ProcessJournalState {
    output: VecDeque<SequencedProcessEvent>,
    first_sequence: u64,
    next_sequence: u64,
    retained_bytes: usize,
    guaranteed_bytes: usize,
    exit: Option<ProcessEvent>,
    completed_at: Option<Instant>,
}

struct SequencedProcessEvent {
    sequence: u64,
    event: ProcessEvent,
    output_bytes: usize,
    guaranteed_bytes: usize,
    _shared_output_slot: Option<OwnedSemaphorePermit>,
}

fn evict_oldest_process_output(state: &mut ProcessJournalState) {
    let removed = state
        .output
        .pop_front()
        .expect("retained byte count requires a process output event");
    state.retained_bytes -= removed.output_bytes;
    state.guaranteed_bytes -= removed.guaranteed_bytes;
    state.first_sequence = removed.sequence + 1;
}

#[derive(Clone)]
enum ProcessJournalChange {
    OutputChanged,
    Exit {
        event: ProcessEvent,
        next_sequence: u64,
    },
}

enum ProcessJournalRead {
    Event(ProcessEvent),
    Exit(ProcessEvent),
    Pending,
    Lagged,
}

#[derive(Clone, Copy)]
enum ProcessOutputKind {
    Stdout,
    Stderr,
}

impl ProcessOutputKind {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Stdout => "stdout",
            Self::Stderr => "stderr",
        }
    }
}

struct ProcessJournalCursor {
    journal: Weak<ProcessEventJournal>,
    changed: watch::Receiver<ProcessJournalChange>,
    next_sequence: u64,
}

enum ProcessReplay {
    Running {
        started: ProcessEvent,
        cursor: ProcessJournalCursor,
    },
    Completed {
        started: ProcessEvent,
        exit: ProcessEvent,
    },
}

impl ProcessRegistry {
    fn reserve(&self) -> Result<ProcessRecordReservation, Status> {
        loop {
            match self.record_slots.clone().try_acquire_owned() {
                Ok(record_slot) => {
                    return Ok(ProcessRecordReservation {
                        record_slot,
                        shared_output_slots: Arc::clone(&self.shared_output_slots),
                    });
                }
                Err(TryAcquireError::Closed) => {
                    return Err(Status::unavailable("process registry is closed"));
                }
                Err(TryAcquireError::NoPermits) => {}
            }

            let completed = self
                .records
                .iter()
                .filter_map(|entry| {
                    entry
                        .journal
                        .completed_at()
                        .map(|completed_at| (entry.key().clone(), completed_at))
                })
                .min_by_key(|(_, completed_at)| *completed_at);
            let Some((process_id, _)) = completed else {
                return Err(Status::resource_exhausted(PROCESS_CAPACITY_MESSAGE));
            };
            self.records.remove(&process_id);
        }
    }

    fn get_record(&self, process_id: &ProcessId) -> Option<Arc<ProcessRecord>> {
        let record = self
            .records
            .get(process_id)
            .map(|entry| Arc::clone(entry.value()))?;
        if record.journal.is_expired() {
            self.records.remove(process_id);
            return None;
        }
        Some(record)
    }

    fn get_running(&self, process_id: &ProcessId) -> Option<Arc<ProcessRecord>> {
        let record = self.get_record(process_id)?;
        if record.journal.is_completed() {
            return None;
        }
        Some(record)
    }

    fn replay(&self, process_id: &ProcessId, output_cursor: Option<u64>) -> Option<ProcessReplay> {
        let record = self.get_record(process_id)?;
        if output_cursor.is_none()
            && let Some(exit) = record.journal.exit()
        {
            return Some(ProcessReplay::Completed {
                started: record.started.clone(),
                exit,
            });
        }
        let next_sequence = output_cursor.unwrap_or_else(|| record.journal.tail_cursor());
        Some(ProcessReplay::Running {
            started: record.started.clone(),
            cursor: ProcessJournalCursor {
                journal: Arc::downgrade(&record.journal),
                changed: record.journal.subscribe(),
                next_sequence,
            },
        })
    }

    fn remove_if_expired(&self, process_id: &ProcessId) {
        if self
            .records
            .get(process_id)
            .is_some_and(|entry| entry.journal.is_expired())
        {
            self.records.remove(process_id);
        }
    }

    fn list(&self) -> Vec<ProcessInfo> {
        let mut expired = Vec::new();
        let running = self
            .records
            .iter()
            .filter_map(|entry| {
                if entry.journal.is_expired() {
                    expired.push(entry.key().clone());
                    return None;
                }
                (!entry.journal.is_completed()).then(|| entry.info.clone())
            })
            .collect();
        for process_id in expired {
            self.records.remove(&process_id);
        }
        running
    }
}

fn replay_process_event_stream(
    replay: ProcessReplay,
) -> std::pin::Pin<Box<dyn futures_util::Stream<Item = Result<ProcessEvent, Status>> + Send>> {
    match replay {
        ProcessReplay::Running {
            started, cursor, ..
        } => process_event_stream_with_prefix(vec![started], Some(cursor)),
        ProcessReplay::Completed { started, exit } => {
            process_event_stream_with_prefix(vec![started, exit], None)
        }
    }
}

fn process_event_stream_with_prefix(
    prefix: Vec<ProcessEvent>,
    cursor: Option<ProcessJournalCursor>,
) -> std::pin::Pin<Box<dyn futures_util::Stream<Item = Result<ProcessEvent, Status>> + Send>> {
    // Pull directly from the bounded journal: a stalled subscriber owns only
    // its cursor, without a second payload queue or a detached pump task.
    Box::pin(futures_util::stream::unfold(
        (prefix.into_iter(), cursor),
        |(mut prefix, mut cursor)| async move {
            if let Some(event) = prefix.next() {
                return Some((Ok(event), (prefix, cursor)));
            }
            let current = cursor.as_mut()?;
            let result = loop {
                let Some(journal) = current.journal.upgrade() else {
                    break evicted_process_journal_result(current);
                };
                let read = journal.read(current.next_sequence);
                drop(journal);
                match read {
                    ProcessJournalRead::Event(event) => {
                        current.next_sequence += 1;
                        return Some((Ok(event), (prefix, cursor)));
                    }
                    ProcessJournalRead::Exit(exit) => break Ok(exit),
                    ProcessJournalRead::Lagged => {
                        break Err(Status::resource_exhausted(PROCESS_OUTPUT_LAGGED_MESSAGE));
                    }
                    ProcessJournalRead::Pending => {
                        if current.changed.changed().await.is_err() {
                            break evicted_process_journal_result(current);
                        }
                    }
                }
            };
            Some((result, (prefix, None)))
        },
    ))
}

fn evicted_process_journal_result(cursor: &ProcessJournalCursor) -> Result<ProcessEvent, Status> {
    match cursor.changed.borrow().clone() {
        ProcessJournalChange::Exit {
            event,
            next_sequence,
        } if cursor.next_sequence >= next_sequence => Ok(event),
        ProcessJournalChange::Exit { .. } => {
            Err(Status::resource_exhausted(PROCESS_OUTPUT_LAGGED_MESSAGE))
        }
        ProcessJournalChange::OutputChanged => Err(Status::resource_exhausted(
            "process replay state was evicted",
        )),
    }
}

fn process_started_event(process_id: &ProcessId, pid: Option<u32>) -> Result<ProcessEvent, Status> {
    let start_time = pplx_space_spaced_common::system_time_to_proto(SystemTime::now())?;
    Ok(ProcessEvent {
        process_id: process_id.as_str().to_string(),
        pid,
        event: Some(
            pplx_space_spaced_common::proto::bridge_guest::process_event::Event::Started(
                pplx_space_spaced_common::proto::bridge_guest::ProcessStarted {
                    start_time: Some(start_time),
                },
            ),
        ),
    })
}

fn process_connected_event(process_id: &ProcessId, pid: Option<u32>) -> ProcessEvent {
    ProcessEvent {
        process_id: process_id.as_str().to_string(),
        pid,
        event: Some(
            pplx_space_spaced_common::proto::bridge_guest::process_event::Event::Connected(
                pplx_space_spaced_common::proto::bridge_guest::ProcessConnected {},
            ),
        ),
    }
}

fn process_stdout_event(process_id: &ProcessId, pid: Option<u32>, data: Vec<u8>) -> ProcessEvent {
    ProcessEvent {
        process_id: process_id.as_str().to_string(),
        pid,
        event: Some(
            pplx_space_spaced_common::proto::bridge_guest::process_event::Event::Stdout(
                pplx_space_spaced_common::proto::bridge_guest::ProcessOutput { data },
            ),
        ),
    }
}

fn process_stderr_event(process_id: &ProcessId, pid: Option<u32>, data: Vec<u8>) -> ProcessEvent {
    ProcessEvent {
        process_id: process_id.as_str().to_string(),
        pid,
        event: Some(
            pplx_space_spaced_common::proto::bridge_guest::process_event::Event::Stderr(
                pplx_space_spaced_common::proto::bridge_guest::ProcessOutput { data },
            ),
        ),
    }
}

fn spawn_process_output_reader<R>(
    mut reader: R,
    record: Arc<ProcessRecord>,
    process_id: ProcessId,
    pid: u32,
    kind: ProcessOutputKind,
) -> tokio::task::JoinHandle<()>
where
    R: AsyncRead + Unpin + Send + 'static,
{
    tokio::spawn(async move {
        let mut buffer = vec![0; 8192];
        loop {
            match reader.read(&mut buffer).await {
                Ok(0) => break,
                Ok(n) => {
                    let Some(data) = buffer.get(..n) else {
                        break;
                    };
                    let event = match kind {
                        ProcessOutputKind::Stdout => {
                            process_stdout_event(&process_id, Some(pid), data.to_vec())
                        }
                        ProcessOutputKind::Stderr => {
                            process_stderr_event(&process_id, Some(pid), data.to_vec())
                        }
                    };
                    record.journal.append_output(event);
                }
                Err(error) => {
                    tracing::warn!(
                        %error,
                        process_id = process_id.as_str(),
                        pid,
                        stream = kind.as_str(),
                        "process output reader failed"
                    );
                    break;
                }
            }
        }
    })
}

async fn drain_process_output_tasks(
    output_tasks: &mut VecDeque<tokio::task::JoinHandle<()>>,
    process_id: &ProcessId,
    pid: u32,
    abort_on_timeout: bool,
) -> bool {
    let drain = async {
        while let Some(task) = output_tasks.front_mut() {
            if let Err(error) = task.await {
                tracing::warn!(%error, pid, "process output task failed");
            }
            output_tasks.pop_front();
        }
    };
    if tokio::time::timeout(PROCESS_OUTPUT_DRAIN_TIMEOUT, drain)
        .await
        .is_ok()
    {
        return true;
    }

    tracing::warn!(
        process_id = process_id.as_str(),
        pid,
        drain_timeout_ms = PROCESS_OUTPUT_DRAIN_TIMEOUT.as_millis() as u64,
        abort_on_timeout,
        "process output drain timed out"
    );
    if !abort_on_timeout {
        return false;
    }
    for task in output_tasks.iter() {
        task.abort();
    }
    while let Some(task) = output_tasks.pop_front() {
        match task.await {
            Ok(()) => {}
            Err(error) if error.is_cancelled() => {}
            Err(error) => tracing::warn!(%error, pid, "process output task failed after abort"),
        }
    }
    false
}

enum ProcessExitOutcome {
    Exited(i32),
    Signaled(i32),
    TimedOut(i32),
    Unknown,
}

fn process_id_in_use() -> Status {
    Status::already_exists("process id is already in use by a running or retained process")
}

fn validate_process_tag(tag: Option<String>) -> Result<Option<String>, Status> {
    if tag
        .as_ref()
        .is_some_and(|tag| tag.len() > MAX_PROCESS_TAG_BYTES || tag.contains('\0'))
    {
        return Err(Status::invalid_argument(
            "process tag must be NUL-free and at most 4096 bytes",
        ));
    }
    Ok(tag)
}

fn process_status_outcome(status: Option<std::process::ExitStatus>) -> ProcessExitOutcome {
    let Some(status) = status else {
        return ProcessExitOutcome::Unknown;
    };
    if let Some(code) = status.code() {
        return ProcessExitOutcome::Exited(code);
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        if let Some(signal) = status.signal() {
            return ProcessExitOutcome::Signaled(signal);
        }
    }
    ProcessExitOutcome::Unknown
}

fn terminate_and_reap_failed_start(
    mut child: tokio::process::Child,
    process_reservation: ProcessRecordReservation,
) {
    let pid = child.id();
    if let Some(pid) = pid {
        // The child has not been waited, so its process-group identity cannot
        // have been reused, including when opening the pidfd failed.
        if let Ok(process_group) = i32::try_from(pid) {
            if let Err(error) = nix::sys::signal::killpg(
                nix::unistd::Pid::from_raw(process_group),
                nix::sys::signal::Signal::SIGKILL,
            ) && error != nix::errno::Errno::ESRCH
            {
                tracing::warn!(%error, pid, "failed to terminate process group after start failure");
            }
        } else {
            tracing::error!(pid, "child pid is outside the Unix process-group range");
        }
    }
    // Also address the Child directly if group signalling failed or no numeric
    // group identity was available. A completed Child makes this a no-op.
    if let Err(error) = child.start_kill() {
        tracing::warn!(%error, ?pid, "failed to kill child after start failure");
    }

    // Cleanup outlives the request and retains admission until reaping finishes.
    // A slow or failed kill must not allow unbounded unreaped failed starts.
    tokio::spawn(async move {
        let _process_reservation = process_reservation;
        if let Err(error) = child.wait().await {
            tracing::warn!(%error, ?pid, "failed to reap child after start failure");
        }
    });
}

fn process_exit_event(
    process_id: &ProcessId,
    pid: Option<u32>,
    outcome: ProcessExitOutcome,
) -> ProcessEvent {
    let outcome = match outcome {
        ProcessExitOutcome::Exited(exit_code) => {
            pplx_space_spaced_common::proto::bridge_guest::process_exit::Outcome::Exited(
                pplx_space_spaced_common::proto::bridge_guest::ProcessExited { exit_code },
            )
        }
        ProcessExitOutcome::Signaled(signal) => {
            pplx_space_spaced_common::proto::bridge_guest::process_exit::Outcome::Signaled(
                pplx_space_spaced_common::proto::bridge_guest::ProcessSignaled {
                    signal: Some(signal),
                },
            )
        }
        ProcessExitOutcome::TimedOut(signal) => {
            pplx_space_spaced_common::proto::bridge_guest::process_exit::Outcome::TimedOut(
                pplx_space_spaced_common::proto::bridge_guest::ProcessTimedOut {
                    signal: Some(signal),
                },
            )
        }
        ProcessExitOutcome::Unknown => {
            pplx_space_spaced_common::proto::bridge_guest::process_exit::Outcome::Unknown(
                pplx_space_spaced_common::proto::bridge_guest::ProcessUnknown {},
            )
        }
    };
    ProcessEvent {
        process_id: process_id.as_str().to_string(),
        pid,
        event: Some(
            pplx_space_spaced_common::proto::bridge_guest::process_event::Event::Exit(
                pplx_space_spaced_common::proto::bridge_guest::ProcessExit {
                    outcome: Some(outcome),
                },
            ),
        ),
    }
}

#[tonic::async_trait]
impl Process for SpacedGuestService {
    type StartStream =
        std::pin::Pin<Box<dyn futures_util::Stream<Item = Result<ProcessEvent, Status>> + Send>>;
    type ConnectProcessStream =
        std::pin::Pin<Box<dyn futures_util::Stream<Item = Result<ProcessEvent, Status>> + Send>>;
    type ListProcessesStream =
        std::pin::Pin<Box<dyn futures_util::Stream<Item = Result<ProcessInfo, Status>> + Send>>;

    async fn start(
        &self,
        mut request: Request<StartRequest>,
    ) -> Result<Response<Self::StartStream>, Status> {
        self.require_ready()?;
        let ingress = request
            .extensions_mut()
            .remove::<pplx_space_common_grpc::RequestPermit>();
        let request = request.into_inner();
        let process_command =
            ProcessCommand::new(request.command).map_err(invalid_argument_status)?;
        let listed_command = process_command.argv().to_vec();
        let requested_cwd = request.cwd;
        let env = parse_env(request.env);
        let listed_env = proto_env(&env);
        let user = request
            .user
            .map(GuestUserName::parse)
            .transpose()
            .map_err(invalid_argument_status)?;
        let listed_user = user.as_ref().map(|user| user.as_str().to_string());
        let listed_tag = validate_process_tag(request.tag)?;
        let account_name = user.unwrap_or_else(|| self.inner.default_operation_user.clone());
        let (account, _start_admission) = resolve_process_account(
            self.inner.process_payload_slots.clone(),
            ingress,
            move || {
                GuestAccount::resolve(account_name)
                    .map_err(crate::identity::ResolveGuestAccountError::into_status)
            },
        )
        .await?;
        let cwd = requested_cwd
            .as_deref()
            .map(|cwd| guest_path::normalize_for_account(cwd, &account))
            .transpose()?;
        let listed_cwd = requested_cwd.map(|_| {
            cwd.as_ref()
                .expect("requested cwd produced normalized cwd")
                .expose()
                .to_string()
        });
        let timeout = validate_optional_timeout(request.timeout)?;
        let background = request.background;
        let stdin_enabled = request.stdin;
        let pty_config = request.pty;
        let clean_env = request.clean_env;
        let idempotency_key =
            require_idempotency_key(request.idempotency_key.clone(), "process_start")?;

        // A caller-assigned id lets the control plane name the process before it
        // starts. A minted id cannot collide, so both cases share one identity
        // and one uniqueness check, taken below under the spawn lock.
        let process_id = request
            .process_id
            .map(ProcessId::parse)
            .transpose()
            .map_err(invalid_argument_status)?
            .unwrap_or_else(ProcessId::new);
        let process_command = Pii::new(&process_command);
        let argv = process_command.expose_pii().argv();
        let Some((program, args)) = argv.split_first() else {
            return Err(Status::invalid_argument("command argv must not be empty"));
        };
        let mut command = Command::new(program);
        command.args(args);
        if let Some(cwd) = &cwd {
            command.current_dir(cwd.expose());
        } else {
            command.current_dir(account.home());
        }
        command.env_clear();
        command.env("PATH", DEFAULT_LOGIN_PATH);
        command.env("HOME", account.home());
        command.env("USER", account.name().as_str());
        command.env("LOGNAME", account.name().as_str());
        command.env("SHELL", account.shell());
        if !clean_env {
            let process_env = self.inner.process_env.read().await.clone();
            if !process_env.as_map().is_empty() {
                command.envs(
                    process_env
                        .as_map()
                        .iter()
                        .map(|(key, value)| (key.as_str(), Pii::new(value).expose_pii().expose())),
                );
            }
        }
        if !env.as_map().is_empty() {
            command.envs(
                env.as_map()
                    .iter()
                    .map(|(key, value)| (key.as_str(), Pii::new(value).expose_pii().expose())),
            );
        }
        // Place the workload in the capped `workloads/` cgroup before exec, and
        // before dropping credentials: the move writes a root-owned
        // `cgroup.procs`, and these pre_exec hooks run in registration order.
        if let Some(cgroups) = self.inner.guest_cgroups.as_ref() {
            cgroups.place_spawned_workload(&mut command);
        }
        let uses_pty = pty_config.is_some();
        if !uses_pty {
            command.process_group(0);
        }
        account.configure_child_credentials(&mut command)?;
        let mut prepared_pty = if let Some(pty_config) = pty_config {
            let _spawn_guard = GUEST_CHILD_SPAWN_LOCK.lock().await;
            Some(prepare_pty(pty_config.size)?)
        } else {
            None
        };
        if let Some(pty) = prepared_pty.as_mut() {
            let control_fd = pty.control_fd.as_raw_fd();
            // SAFETY: the pre_exec hook calls libc `login_tty` and captures a
            // pty slave fd kept open until `spawn` completes.
            unsafe {
                command.pre_exec(move || configure_child_pty(control_fd));
            }
        } else {
            if stdin_enabled {
                command.stdin(std::process::Stdio::piped());
            } else {
                command.stdin(std::process::Stdio::null());
            }
            command.stdout(std::process::Stdio::piped());
            command.stderr(std::process::Stdio::piped());
        }

        // An assigned id that is already live is a definitive answer, so give it
        // precedence over every other rejection on this path. Both of the
        // rejections it precedes are reachable for a retry of a still-running
        // process: `reserve_or_get` fails an idempotency key past
        // `IDEMPOTENCY_RECORD_TTL`, and `reserve` reports exhaustion when every
        // record slot holds a running process. The data plane reconnects only
        // on `AlreadyExists`, so either one would fail the attach instead of
        // recovering. Answering here also keeps the outcome independent of the
        // idempotency record's lifetime.
        if self.inner.processes.records.contains_key(&process_id) {
            return Err(process_id_in_use());
        }

        let reservation = match self
            .inner
            .idempotency
            .reserve_or_get(idempotency_key)
            .await?
        {
            IdempotencyLookup::Completed(Ok(IdempotencyRecord::ProcessStarted { process_id })) => {
                // A lost Start response may hide both identity and earlier output.
                // Recover the original stream, rather than attaching at its tail.
                let replay = self
                    .inner
                    .processes
                    .replay(&process_id, Some(0))
                    .ok_or_else(|| Status::failed_precondition("process replay state expired"))?;
                return Ok(Response::new(
                    replay_process_event_stream(replay) as Self::StartStream
                ));
            }
            IdempotencyLookup::Completed(Err(status)) => return Err(status),
            IdempotencyLookup::Reserved(reservation) => reservation,
        };

        let process_reservation = self.inner.processes.reserve()?;

        // Cancellation while waiting for admission has no effect to replay:
        // the unstarted reservation releases its key on Drop. From begin through
        // supervisor handoff and publication there are no suspension points.
        let spawn_guard = GUEST_CHILD_SPAWN_LOCK.lock().await;
        self.require_ready()?;
        // Re-claim the identity inside the same suspension-free region that
        // publishes the record. The check above is reachable across a
        // suspension point, so on its own it would let two starts carrying the
        // same assigned id both pass and have the second publication replace
        // the first, leaving its live process unreachable. This one is
        // authoritative, and it still runs before `spawn` so a refused start
        // never leaves a child behind.
        if self.inner.processes.records.contains_key(&process_id) {
            return Err(process_id_in_use());
        }
        let operation = reservation.begin()?;
        let spawn_result = command.spawn();
        let mut child = match spawn_result {
            Ok(child) => child,
            Err(error) => {
                let status = map_io_error(error);
                operation.complete(Err(status.clone()));
                return Err(status);
            }
        };
        let pid = match child.id() {
            Some(pid) => pid,
            None => {
                let status = Status::internal("spawned child has no pid");
                terminate_and_reap_failed_start(child, process_reservation);
                operation.complete(Err(status.clone()));
                return Err(status);
            }
        };
        let (signal_handle, _exit_observer) = match ProcessSignalHandle::open(pid) {
            Ok(handle) => handle,
            Err(error) => {
                let status = Status::internal(format!(
                    "failed to create safe handle for spawned process: {error}"
                ));
                terminate_and_reap_failed_start(child, process_reservation);
                operation.complete(Err(status.clone()));
                return Err(status);
            }
        };
        let (input, pty_reader, stdout, stderr) = if let Some(pty) = prepared_pty.take() {
            (
                ProcessInput::Pty(PtyInput {
                    writer: Mutex::new(pty.writer),
                    resize_fd: pty.resize_fd,
                }),
                Some(pty.reader),
                None,
                None,
            )
        } else {
            let stdin = if stdin_enabled {
                child.stdin.take()
            } else {
                None
            };
            let input = if stdin_enabled {
                ProcessInput::Pipe(Mutex::new(stdin))
            } else {
                ProcessInput::Disabled
            };
            (input, None, child.stdout.take(), child.stderr.take())
        };
        let started = match process_started_event(&process_id, Some(pid)) {
            Ok(started) => started,
            Err(status) => {
                terminate_and_reap_failed_start(child, process_reservation);
                operation.complete(Err(status.clone()));
                return Err(status);
            }
        };
        let record = Arc::new(ProcessRecord::new(
            started.clone(),
            ProcessInfo {
                process_id: process_id.as_str().to_string(),
                pid,
                command: listed_command,
                cwd: listed_cwd,
                env: listed_env,
                user: listed_user,
                tag: listed_tag,
                pty: Some(matches!(input, ProcessInput::Pty(_))),
            },
            input,
            signal_handle,
            process_reservation,
        ));
        self.inner
            .processes
            .records
            .insert(process_id.clone(), Arc::clone(&record));

        let mut output_tasks = VecDeque::new();
        if let Some(reader) = pty_reader {
            output_tasks.push_back(spawn_process_output_reader(
                reader,
                Arc::clone(&record),
                process_id.clone(),
                pid,
                ProcessOutputKind::Stdout,
            ));
        }
        if let Some(stdout) = stdout {
            output_tasks.push_back(spawn_process_output_reader(
                stdout,
                Arc::clone(&record),
                process_id.clone(),
                pid,
                ProcessOutputKind::Stdout,
            ));
        }
        if let Some(stderr) = stderr {
            output_tasks.push_back(spawn_process_output_reader(
                stderr,
                Arc::clone(&record),
                process_id.clone(),
                pid,
                ProcessOutputKind::Stderr,
            ));
        }
        let registry = self.inner.processes.clone();
        let record_for_wait = Arc::clone(&record);
        let process_id_for_wait = process_id.clone();
        let shutdown = self.inner.shutdown.clone();
        self.inner.process_tasks.spawn(async move {
            let completion = async {
                #[cfg(target_os = "linux")]
                match _exit_observer.exited().await {
                    // Preserve the leader's identity until descendants have
                    // released its output, but stop its execution deadline now.
                    Ok(()) => return Ok(None),
                    Err(error) => tracing::warn!(%error, pid, "pidfd observation failed; falling back to child wait"),
                }
                child.wait().await.map(Some)
            };
            let deadline = async {
                match timeout {
                    Some(timeout) => tokio::time::sleep(timeout.as_duration()).await,
                    None => std::future::pending::<()>().await,
                }
            };
            let waited = tokio::select! {
                biased;
                status = completion => Ok(status),
                _ = shutdown.cancelled() => Err(ProcessExitOutcome::Signaled(libc::SIGKILL)),
                _ = deadline => Err(ProcessExitOutcome::TimedOut(libc::SIGKILL)),
            };
            let outcome = match waited {
                Ok(Ok(None)) => {
                    let drained = tokio::select! {
                        drained = drain_process_output_tasks(
                            &mut output_tasks, &process_id_for_wait, pid, false,
                        ) => drained,
                        _ = shutdown.cancelled() => false,
                    };
                    if !drained && let Err(error) = record_for_wait.signal_handle.terminate_group() {
                        tracing::warn!(%error, pid, "failed to terminate descendants holding output open");
                    }
                    process_status_outcome(child.wait().await.ok())
                }
                Ok(status) => process_status_outcome(status.ok().flatten()),
                Err(outcome) => {
                    if let Err(error) = record_for_wait.signal_handle.terminate_group() {
                        tracing::warn!(%error, pid, "failed to terminate process group");
                    }
                    if let Err(error) = child.wait().await {
                        tracing::warn!(%error, pid, "failed to reap terminated child");
                    }
                    outcome
                }
            };

            if !output_tasks.is_empty() {
                drain_process_output_tasks(&mut output_tasks, &process_id_for_wait, pid, true)
                    .await;
            }
            let exit = process_exit_event(&process_id_for_wait, Some(pid), outcome);
            record_for_wait.journal.complete(exit);
            // Release supervisor ownership. Eviction can free this record's
            // permit once any in-flight stdin/control handlers also release it.
            drop(record_for_wait);
            tokio::select! {
                _ = shutdown.cancelled() => {},
                _ = tokio::time::sleep(IDEMPOTENCY_RECORD_TTL) => {},
            }
            registry.remove_if_expired(&process_id_for_wait);
        });

        operation.complete(Ok(IdempotencyRecord::ProcessStarted {
            process_id: process_id.clone(),
        }));
        drop(spawn_guard);

        tracing::debug!(
            command = "bridge_guest_process_start",
            process_id = %process_id,
            pid,
            background,
            "spaced bridge guest command succeeded"
        );
        Ok(Response::new(process_event_stream_with_prefix(
            vec![started],
            Some(ProcessJournalCursor {
                journal: Arc::downgrade(&record.journal),
                changed: record.journal.subscribe(),
                next_sequence: 0,
            }),
        ) as Self::StartStream))
    }

    async fn connect_process(
        &self,
        request: Request<ConnectProcessRequest>,
    ) -> Result<Response<Self::ConnectProcessStream>, Status> {
        self.require_ready()?;
        let request = request.into_inner();
        let process_id = ProcessId::parse(request.process_id).map_err(invalid_argument_status)?;
        // Validate the field for wire compatibility, but do not turn it into a
        // total stream-lifetime deadline here. ECW and native callers own
        // their outer stream budgets; enforcing the same value again in the
        // guest can truncate a healthy, continuously producing process.
        validate_optional_timeout(request.timeout)?;
        let replay = self
            .inner
            .processes
            .replay(&process_id, request.output_cursor)
            .ok_or_else(|| Status::not_found("process not found"))?;
        let pid = match &replay {
            ProcessReplay::Running { started, .. } | ProcessReplay::Completed { started, .. } => {
                started.pid
            }
        };
        let stream = match replay {
            ProcessReplay::Running { cursor, .. } => process_event_stream_with_prefix(
                vec![process_connected_event(&process_id, pid)],
                Some(cursor),
            ),
            replay @ ProcessReplay::Completed { .. } => replay_process_event_stream(replay),
        };
        tracing::debug!(
            command = "bridge_guest_process_connect",
            process_id = %process_id,
            ?pid,
            "spaced bridge guest command succeeded"
        );
        Ok(Response::new(stream as Self::ConnectProcessStream))
    }

    async fn list_processes(
        &self,
        _request: Request<ListProcessesRequest>,
    ) -> Result<Response<Self::ListProcessesStream>, Status> {
        self.require_ready()?;
        let processes = self.inner.processes.list();
        tracing::debug!(
            command = "bridge_guest_process_list",
            count = processes.len(),
            "spaced bridge guest command succeeded"
        );
        Ok(Response::new(
            Box::pin(tokio_stream::iter(processes.into_iter().map(Ok)))
                as Self::ListProcessesStream,
        ))
    }

    async fn send_signal(
        &self,
        request: Request<SendSignalRequest>,
    ) -> Result<Response<SendSignalResponse>, Status> {
        self.require_ready()?;
        let request = request.into_inner();
        let process_id = ProcessId::parse(request.process_id).map_err(invalid_argument_status)?;
        let signal =
            ProcessSignal::try_from_i32(request.signal).map_err(invalid_argument_status)?;
        let handle = self
            .inner
            .processes
            .get_running(&process_id)
            .ok_or_else(|| Status::not_found("process not found"))?;
        handle.signal_handle.signal(signal)?;
        tracing::debug!(
            command = "bridge_guest_process_send_signal",
            process_id = %process_id,
            pid = handle.info.pid,
            "spaced bridge guest command succeeded"
        );
        Ok(Response::new(SendSignalResponse {}))
    }

    async fn send_input(
        &self,
        request: Request<SendInputRequest>,
    ) -> Result<Response<SendInputResponse>, Status> {
        self.require_ready()?;
        let mut request = request.into_inner();
        let process_id = ProcessId::parse(std::mem::take(&mut request.process_id))
            .map_err(invalid_argument_status)?;
        let record = self
            .inner
            .processes
            .get_running(&process_id)
            .ok_or_else(|| Status::not_found("process not found"))?;
        record.write_stdin(&request.data).await?;
        tracing::debug!(
            command = "bridge_guest_process_send_input",
            process_id = %process_id,
            bytes = request.data.len(),
            "spaced bridge guest command succeeded"
        );
        Ok(Response::new(SendInputResponse {}))
    }

    async fn close_stdin(
        &self,
        request: Request<CloseStdinRequest>,
    ) -> Result<Response<CloseStdinResponse>, Status> {
        self.require_ready()?;
        let request = request.into_inner();
        let process_id = ProcessId::parse(request.process_id).map_err(invalid_argument_status)?;
        let record = self
            .inner
            .processes
            .get_running(&process_id)
            .ok_or_else(|| Status::not_found("process not found"))?;
        record.close_stdin().await?;
        tracing::debug!(
            command = "bridge_guest_process_close_stdin",
            process_id = %process_id,
            "spaced bridge guest command succeeded"
        );
        Ok(Response::new(CloseStdinResponse {}))
    }

    async fn resize_pty(
        &self,
        request: Request<ResizePtyRequest>,
    ) -> Result<Response<ResizePtyResponse>, Status> {
        self.require_ready()?;
        let request = request.into_inner();
        let process_id = ProcessId::parse(request.process_id).map_err(invalid_argument_status)?;
        let size = request
            .size
            .ok_or_else(|| Status::invalid_argument("pty size is required"))?;
        let record = self
            .inner
            .processes
            .get_running(&process_id)
            .ok_or_else(|| Status::not_found("process not found"))?;
        record.resize_pty(size)?;
        tracing::debug!(
            command = "bridge_guest_process_resize_pty",
            process_id = %process_id,
            "spaced bridge guest command succeeded"
        );
        Ok(Response::new(ResizePtyResponse {}))
    }
}

#[cfg(all(test, unix))]
mod tests;
