use super::*;
use futures_util::StreamExt;
use pplx_space_common_core::types::GuestUserName;
use pplx_space_spaced_common::proto::bridge_guest::StartRequest;
use pplx_space_spaced_common::proto::bridge_guest::process_server::Process;

#[test]
fn dropping_a_pending_pty_read_releases_blocking_capacity() {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .max_blocking_threads(1)
        .build()
        .unwrap();
    runtime.block_on(async {
        let PreparedPty {
            mut reader,
            writer,
            resize_fd,
            control_fd,
        } = {
            let _spawn_guard = GUEST_CHILD_SPAWN_LOCK.lock().await;
            prepare_pty(None).unwrap()
        };
        let mut byte = [0];
        tokio::time::timeout(Duration::from_millis(20), reader.read(&mut byte))
            .await
            .expect_err("PTY without slave output must stay pending");
        drop(reader);
        let mut other_work = tokio::task::spawn_blocking(|| ());
        let released = tokio::time::timeout(Duration::from_millis(100), &mut other_work)
            .await
            .is_ok();
        // Always release the slave before asserting: the old blocking adapter
        // would otherwise hang the test runtime during unwinding.
        drop((control_fd, writer, resize_fd));
        if !released {
            other_work.await.unwrap();
        }
        assert!(released, "cancelled PTY read retained a blocking worker");
    });
}

#[tokio::test]
async fn pty_close_stdin_rejects_without_disabling_input() {
    let service = cancellation_service();
    let response = Process::start(
        &service,
        Request::new(StartRequest {
            command: vec!["/bin/cat".into()],
            pty: Some(pplx_space_spaced_common::proto::bridge_guest::PtyConfig { size: None }),
            idempotency_key: Some("pty-close".into()),
            ..Default::default()
        }),
    )
    .await
    .unwrap();
    let mut stream = response.into_inner();
    let started = stream.next().await.unwrap().unwrap();
    let result = Process::close_stdin(
        &service,
        Request::new(CloseStdinRequest {
            process_id: started.process_id.clone(),
        }),
    )
    .await;
    let input = Process::send_input(
        &service,
        Request::new(SendInputRequest {
            process_id: started.process_id,
            data: b"still-open\n".to_vec(),
        }),
    )
    .await;
    service.inner.shutdown.cancel();
    service.inner.process_tasks.close();
    service.inner.process_tasks.wait().await;
    assert_eq!(result.unwrap_err().code(), tonic::Code::FailedPrecondition);
    input.expect("unsupported close must preserve PTY input");
}

#[test]
fn process_tag_is_bounded_before_registry_retention() {
    validate_process_tag(Some("tag".to_string())).unwrap();
    validate_process_tag(Some("x".repeat(MAX_PROCESS_TAG_BYTES + 1))).unwrap_err();
    validate_process_tag(Some("bad\0tag".to_string())).unwrap_err();
}

fn output_slots() -> Arc<Semaphore> {
    Arc::new(Semaphore::new(PROCESS_OUTPUT_SHARED_BYTES))
}

fn cancellation_start_request() -> Request<StartRequest> {
    Request::new(StartRequest {
        command: vec!["/bin/sh".into(), "-c".into(), "exit 0".into()],
        idempotency_key: Some("cancel-after-spawn".into()),
        ..Default::default()
    })
}

fn cancellation_service() -> SpacedGuestService {
    let user = nix::unistd::User::from_uid(nix::unistd::Uid::current())
        .expect("current user lookup")
        .expect("process tests require a passwd entry for the current uid");
    let service = SpacedGuestService::with_config(
        CancellationToken::new(),
        SpacedGuestServiceConfig {
            local_socket_path: None,
            bridge_socket_path: None,
            default_operation_user: GuestUserName::parse(user.name).expect("valid current user"),
            filesystem_execution: FilesystemExecutionMode::Direct,
            ..SpacedGuestServiceConfig::default()
        },
    );
    service.ready();
    service
}

#[tokio::test]
async fn process_payload_admission_rejects_before_decode_and_releases_at_headers() {
    use pplx_space_spaced_common::process_limits;
    use tonic::codegen::{Service, http};
    let service = cancellation_service();
    let slots = service.inner.process_payload_slots.clone();
    let occupied = slots
        .clone()
        .acquire_many_owned(process_limits::PAYLOAD_SLOTS as u32)
        .await
        .unwrap();
    let mut grpc = service.process_grpc_service();
    for (method, _) in process_limits::PAYLOAD_METHODS {
        // An empty body is invalid gRPC. Admission must reject it before the
        // decoder (and consequently before any process effect) is entered.
        let request = http::Request::builder()
            .uri(format!(
                "/{}/{method}",
                <ProcessServer<SpacedGuestService> as tonic::server::NamedService>::NAME
            ))
            .header("content-type", "application/grpc")
            .body(tonic::body::Body::empty())
            .unwrap();
        let response = grpc.call(request).await.unwrap();
        assert_eq!(response.headers()["grpc-status"], "8");
    }
    assert!(service.inner.processes.records.is_empty());
    drop(occupied);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let shutdown = service.inner.shutdown.clone();
    let server = tokio::spawn(
        tonic::transport::Server::builder()
            .add_service(service.process_grpc_service())
            .serve_with_incoming_shutdown(
                tokio_stream::wrappers::TcpListenerStream::new(listener),
                shutdown.clone().cancelled_owned(),
            ),
    );
    let mut client =
        pplx_space_spaced_common::proto::bridge_guest::process_client::ProcessClient::connect(
            format!("http://{address}"),
        )
        .await
        .unwrap();
    let mut stream = client
        .start(StartRequest {
            command: vec!["/bin/cat".into()],
            stdin: true,
            idempotency_key: Some("admitted-input".into()),
            ..Default::default()
        })
        .await
        .unwrap()
        .into_inner();
    let started = stream.message().await.unwrap().unwrap();
    assert_eq!(
        slots.available_permits(),
        process_limits::PAYLOAD_SLOTS,
        "a live Start stream must release its request payload admission"
    );
    let record = service
        .inner
        .processes
        .get_running(&ProcessId::parse(started.process_id.clone()).unwrap())
        .unwrap();
    let ProcessInput::Pipe(stdin) = &record.input else {
        panic!("pipe stdin")
    };
    let held = stdin.lock().await;
    let mut writes = Vec::new();
    for _ in 0..process_limits::PAYLOAD_SLOTS {
        let mut client = client.clone();
        let process_id = started.process_id.clone();
        writes.push(tokio::spawn(async move {
            client
                .send_input(SendInputRequest {
                    process_id,
                    data: b"a".to_vec(),
                })
                .await
        }));
    }
    tokio::time::timeout(Duration::from_secs(2), async {
        while slots.available_permits() != 0 {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    let rejected = client
        .send_input(SendInputRequest {
            process_id: started.process_id.clone(),
            data: b"rejected".to_vec(),
        })
        .await
        .unwrap_err();
    assert_eq!(rejected.code(), tonic::Code::ResourceExhausted);
    drop(held);
    for write in writes {
        write.await.unwrap().unwrap();
    }
    client
        .close_stdin(CloseStdinRequest {
            process_id: started.process_id,
        })
        .await
        .unwrap();
    let mut output = Vec::new();
    tokio::time::timeout(Duration::from_secs(2), async {
        while let Some(event) = stream.message().await.unwrap() {
            if let Some(
                pplx_space_spaced_common::proto::bridge_guest::process_event::Event::Stdout(bytes),
            ) = event.event
            {
                output.extend(bytes.data);
            }
        }
    })
    .await
    .unwrap();
    assert_eq!(output, b"aaaaaaaa", "rejected input must not execute");
    assert_eq!(slots.available_permits(), process_limits::PAYLOAD_SLOTS);
    shutdown.cancel();
    server.await.unwrap().unwrap();
}

#[tokio::test]
async fn cancelling_start_before_spawn_releases_admission_and_allows_retry() {
    let service = cancellation_service();
    let spawn_guard = GUEST_CHILD_SPAWN_LOCK.lock().await;
    let mut start = Box::pin(Process::start(&service, cancellation_start_request()));
    tokio::time::timeout(Duration::from_secs(1), async {
        while service.inner.processes.record_slots.available_permits() == PROCESS_RECORD_LIMIT {
            assert!(futures_util::poll!(start.as_mut()).is_pending());
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("account lookup completes before spawn admission");
    assert_eq!(
        service.inner.processes.record_slots.available_permits(),
        PROCESS_RECORD_LIMIT - 1
    );
    assert!(service.inner.processes.records.is_empty());
    drop(start);
    assert_eq!(
        service.inner.processes.record_slots.available_permits(),
        PROCESS_RECORD_LIMIT
    );
    drop(spawn_guard);

    let retry = tokio::time::timeout(
        Duration::from_secs(1),
        Process::start(&service, cancellation_start_request()),
    )
    .await
    .expect("cancelled pre-spawn reservation blocked retry")
    .expect("same-key retry starts the process");
    let mut events = retry.into_inner();
    tokio::time::timeout(Duration::from_secs(1), async {
        while let Some(event) = events.next().await {
            event.expect("process stream remains successful");
        }
    })
    .await
    .expect("retried process exits");
    assert_eq!(service.inner.processes.records.len(), 1);
}

#[tokio::test]
async fn losing_start_response_preserves_output_supervision_and_idempotency() {
    use pplx_space_spaced_common::proto::bridge_guest::process_event::Event;

    for (completed, evicted) in [(false, false), (true, false), (false, true), (true, true)] {
        let service = cancellation_service();
        let request = StartRequest {
            command: vec![
                "/bin/sh".into(),
                "-c".into(),
                if evicted {
                    format!(
                        "printf stdout; printf stderr >&2; head -c {} /dev/zero; cat >/dev/null",
                        PROCESS_OUTPUT_RETENTION_BYTES + 65536
                    )
                } else {
                    "printf stdout; printf stderr >&2; cat >/dev/null".into()
                },
            ],
            stdin: true,
            idempotency_key: Some("lost-start-response".into()),
            ..Default::default()
        };
        let response = Process::start(&service, Request::new(request.clone()))
            .await
            .expect("process starts");
        // The transport can lose the response before delivering even its first
        // event. Output recovery cannot depend on consuming the original stream.
        drop(response);
        let record = service
            .inner
            .processes
            .records
            .iter()
            .next()
            .map(|entry| Arc::clone(entry.value()))
            .expect("spawned process is registered");
        if completed {
            record.input.close().await.unwrap();
        }
        tokio::time::timeout(Duration::from_secs(2), async {
            let mut changed = record.journal.subscribe();
            while record.journal.tail_cursor() < 2
                || (completed && !record.journal.is_completed())
                || (evicted && !matches!(record.journal.read(0), ProcessJournalRead::Lagged))
            {
                changed.changed().await.unwrap();
            }
        })
        .await
        .expect("output must precede the retry");
        assert_eq!(record.journal.is_completed(), completed);

        let replay = tokio::time::timeout(
            Duration::from_secs(1),
            Process::start(&service, Request::new(request)),
        )
        .await
        .expect("same-key retry waited for an abandoned reservation")
        .expect("same-key retry replays the registered process");
        record.input.close().await.unwrap();
        let mut replay = replay.into_inner();
        let started = replay.next().await.unwrap().unwrap();
        assert_eq!(started.process_id, record.info.process_id);
        assert_eq!(started.pid, Some(record.info.pid));
        assert!(matches!(started.event, Some(Event::Started(_))));
        let (stdout, stderr, exited, lagged) =
            tokio::time::timeout(Duration::from_secs(2), async {
                let mut stdout = Vec::new();
                let mut stderr = Vec::new();
                let mut exited = false;
                let mut lagged = false;
                while let Some(event) = replay.next().await {
                    let event = match event {
                        Ok(event) => event,
                        Err(error) => {
                            assert!(evicted);
                            assert_eq!(error.code(), tonic::Code::ResourceExhausted);
                            assert_eq!(error.message(), PROCESS_OUTPUT_LAGGED_MESSAGE);
                            lagged = true;
                            assert!(replay.next().await.is_none());
                            break;
                        }
                    };
                    match event.event {
                        Some(Event::Stdout(output)) => stdout.extend(output.data),
                        Some(Event::Stderr(output)) => stderr.extend(output.data),
                        Some(Event::Exit(_)) => exited = true,
                        other => panic!("unexpected Start replay event: {other:?}"),
                    }
                }
                (stdout, stderr, exited, lagged)
            })
            .await
            .expect("cancelled start left the spawned child unsupervised");
        assert_eq!(stdout, if evicted { b"".as_slice() } else { b"stdout" });
        assert_eq!(stderr, if evicted { b"".as_slice() } else { b"stderr" });
        assert_eq!(exited, !evicted);
        assert_eq!(lagged, evicted);
        // Losing the stream must not abandon supervision of a still-running child.
        let mut changed = record.journal.subscribe();
        tokio::time::timeout(Duration::from_secs(2), async {
            while !record.journal.is_completed() {
                changed.changed().await.unwrap();
            }
        })
        .await
        .unwrap();
        assert_eq!(service.inner.processes.records.len(), 1);
        let process_id = ProcessId::parse(record.info.process_id.clone()).unwrap();
        drop(service.inner.processes.records.remove(&process_id));
        assert_eq!(
            service.inner.processes.record_slots.available_permits(),
            PROCESS_RECORD_LIMIT - 1,
            "a handler retaining the evicted record must retain its admission"
        );
        drop(record);
        assert_eq!(
            service.inner.processes.record_slots.available_permits(),
            PROCESS_RECORD_LIMIT
        );
    }
}

#[tokio::test]
async fn pending_process_stream_stops_when_receiver_closes() {
    let journal = Arc::new(ProcessEventJournal::new(output_slots()));
    let mut stream = process_event_stream_with_prefix(
        Vec::new(),
        Some(ProcessJournalCursor {
            journal: Arc::downgrade(&journal),
            changed: journal.subscribe(),
            next_sequence: 0,
        }),
    );

    assert!(futures_util::poll!(stream.next()).is_pending());
    assert_eq!(journal.changed.receiver_count(), 1);
    drop(stream);
    assert_eq!(journal.changed.receiver_count(), 0);
}

#[tokio::test]
async fn failed_start_retains_admission_until_the_child_is_reaped() {
    for already_exited in [false, true] {
        let registry = ProcessRegistry::default();
        let reservation = registry.reserve().expect("process admission");
        let mut command = Command::new("/bin/sh");
        command.args([
            "-c",
            if already_exited {
                "exit 0"
            } else {
                "exec sleep 30"
            },
        ]);
        command.kill_on_drop(true);
        command.process_group(0);
        let mut child = {
            let _guard = GUEST_CHILD_SPAWN_LOCK.lock().await;
            command.spawn().expect("child spawned")
        };
        let pid = child.id().expect("spawned pid");
        if already_exited {
            child.wait().await.expect("child exits");
            assert!(child.id().is_none());
        }
        terminate_and_reap_failed_start(child, reservation);
        assert_eq!(
            registry.record_slots.available_permits(),
            PROCESS_RECORD_LIMIT - 1
        );
        tokio::time::timeout(Duration::from_secs(1), async {
            while registry.record_slots.available_permits() != PROCESS_RECORD_LIMIT {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("failed child was not reaped");
        // No waitable child remains once cleanup releases the admission permit.
        let result = nix::sys::wait::waitpid(
            nix::unistd::Pid::from_raw(pid.try_into().unwrap()),
            Some(nix::sys::wait::WaitPidFlag::WNOHANG),
        );
        assert_eq!(result, Err(nix::errno::Errno::ECHILD));
    }
}

#[test]
fn process_registry_bounds_retained_records() {
    let registry = ProcessRegistry::default();
    let mut reservations = Vec::with_capacity(PROCESS_RECORD_LIMIT);
    for _ in 0..PROCESS_RECORD_LIMIT {
        reservations.push(registry.reserve().expect("record slot"));
    }

    let error = match registry.reserve() {
        Ok(_) => panic!("registry must reject overflow"),
        Err(error) => error,
    };
    assert_eq!(error.code(), tonic::Code::ResourceExhausted);

    reservations.pop();
    registry
        .reserve()
        .expect("released record slot is reusable");
}

#[tokio::test]
async fn process_journal_reports_lag_when_local_ring_evicts_output() {
    let process_id = ProcessId::new();
    for (chunk_bytes, count) in [(8192, 600), (1, 100_000)] {
        let journal = Arc::new(ProcessEventJournal::new(output_slots()));
        let mut slow = process_event_stream_with_prefix(
            Vec::new(),
            Some(ProcessJournalCursor {
                journal: Arc::downgrade(&journal),
                changed: journal.subscribe(),
                next_sequence: 0,
            }),
        );
        for _ in 0..count {
            journal.append_output(process_stdout_event(
                &process_id,
                Some(1),
                vec![b'a'; chunk_bytes],
            ));
        }
        assert!(
            matches!(journal.read(0), ProcessJournalRead::Lagged),
            "retention must charge tiny event overhead as well as payloads"
        );
        assert!(matches!(
            journal.read(count - 1),
            ProcessJournalRead::Event(_)
        ));
        assert_eq!(
            slow.next().await.unwrap().unwrap_err().code(),
            tonic::Code::ResourceExhausted
        );
        assert!(slow.next().await.is_none());
        assert_eq!(journal.changed.receiver_count(), 0);
    }
}

#[test]
fn process_journal_drops_oversized_chunk_without_panicking() {
    let journal = ProcessEventJournal::new(output_slots());
    let process_id = ProcessId::new();

    journal.append_output(process_stdout_event(
        &process_id,
        Some(1),
        vec![0; PROCESS_OUTPUT_RETENTION_BYTES + 1],
    ));

    assert!(matches!(journal.read(0), ProcessJournalRead::Lagged));
}

#[test]
fn output_pressure_is_isolated_to_one_process() {
    let shared_output_slots = Arc::new(Semaphore::new(0));
    let noisy = ProcessEventJournal::new(Arc::clone(&shared_output_slots));
    let quiet = ProcessEventJournal::new(shared_output_slots);
    let noisy_id = ProcessId::new();
    let quiet_id = ProcessId::new();
    quiet.append_output(process_stdout_event(&quiet_id, Some(2), b"quiet".to_vec()));

    noisy.append_output(process_stdout_event(
        &noisy_id,
        Some(1),
        vec![0; PROCESS_OUTPUT_RETENTION_BYTES],
    ));
    noisy.append_output(process_stdout_event(&noisy_id, Some(1), vec![1]));

    assert!(matches!(noisy.read(0), ProcessJournalRead::Lagged));
    assert!(matches!(quiet.read(0), ProcessJournalRead::Event(_)));
}

#[test]
fn process_journal_releases_shared_burst_capacity_on_drop() {
    let shared_output_slots = Arc::new(Semaphore::new(1));
    let journal = ProcessEventJournal::new(Arc::clone(&shared_output_slots));
    let process_id = ProcessId::new();
    journal.append_output(process_stdout_event(
        &process_id,
        Some(1),
        vec![
            0;
            PROCESS_OUTPUT_GUARANTEED_BYTES + 1
                - std::mem::size_of::<SequencedProcessEvent>()
                - process_id.as_str().len()
        ],
    ));
    assert_eq!(shared_output_slots.available_permits(), 0);

    drop(journal);

    assert_eq!(shared_output_slots.available_permits(), 1);
}

#[tokio::test]
async fn completed_cursor_keeps_terminal_event_without_retaining_journal() {
    let journal = Arc::new(ProcessEventJournal::new(output_slots()));
    let process_id = ProcessId::new();
    let exit = process_stdout_event(&process_id, Some(1), b"terminal".to_vec());
    let cursor = ProcessJournalCursor {
        journal: Arc::downgrade(&journal),
        changed: journal.subscribe(),
        next_sequence: 0,
    };
    journal.complete(exit.clone());
    drop(journal);

    let events = process_event_stream_with_prefix(Vec::new(), Some(cursor))
        .collect::<Vec<_>>()
        .await;

    assert_eq!(events.len(), 1);
    assert_eq!(events[0].as_ref().expect("terminal event"), &exit);
}

#[tokio::test]
async fn evicted_cursor_reports_lag_before_terminal_event() {
    let journal = Arc::new(ProcessEventJournal::new(output_slots()));
    let process_id = ProcessId::new();
    journal.append_output(process_stdout_event(
        &process_id,
        Some(1),
        b"unread".to_vec(),
    ));
    let exit = process_stdout_event(&process_id, Some(1), b"terminal".to_vec());
    let cursor = ProcessJournalCursor {
        journal: Arc::downgrade(&journal),
        changed: journal.subscribe(),
        next_sequence: 0,
    };
    journal.complete(exit);
    drop(journal);

    let events = process_event_stream_with_prefix(Vec::new(), Some(cursor))
        .collect::<Vec<_>>()
        .await;

    assert_eq!(events.len(), 1);
    assert_eq!(
        events[0]
            .as_ref()
            .expect_err("lagged replay must fail")
            .code(),
        tonic::Code::ResourceExhausted
    );
}

#[tokio::test]
async fn login_tty_pty_supports_output_input_and_resize() {
    let prepared = {
        let _spawn_guard = GUEST_CHILD_SPAWN_LOCK.lock().await;
        prepare_pty(Some(PtySize { rows: 24, cols: 80 })).expect("open test pty")
    };
    let PreparedPty {
        mut reader,
        mut writer,
        resize_fd,
        control_fd,
    } = prepared;

    let mut command = Command::new("/bin/sh");
    command
        .arg("-c")
        .arg("printf 'ready\n'; IFS= read -r line; stty size; printf 'input:%s\n' \"$line\"");

    let control_fd_raw = control_fd.as_raw_fd();
    // SAFETY: the child inherits this live slave, and the callback only calls login_tty.
    unsafe {
        command.pre_exec(move || configure_child_pty(control_fd_raw));
    }
    let mut child = {
        let _spawn_guard = GUEST_CHILD_SPAWN_LOCK.lock().await;
        command.spawn().expect("spawn pty child")
    };
    drop(control_fd);

    set_pty_size(
        &resize_fd,
        PtySize {
            rows: 33,
            cols: 101,
        },
    )
    .expect("resize pty");
    writer
        .write_all(b"hello-login-tty\n")
        .await
        .expect("write pty input");
    writer.flush().await.expect("flush pty input");
    drop(writer);

    let output = tokio::time::timeout(Duration::from_secs(5), async {
        let mut output = Vec::new();
        let mut chunk = [0_u8; 1024];
        loop {
            match reader.read(&mut chunk).await {
                Ok(0) => break,
                Ok(read) => output.extend_from_slice(&chunk[..read]),
                Err(error) if error.raw_os_error() == Some(libc::EIO) => break,
                Err(error) => return Err(error),
            }
        }
        Ok::<_, io::Error>(output)
    })
    .await
    .expect("pty output timed out")
    .expect("read pty output");
    let output = String::from_utf8(output).expect("pty output is utf-8");
    let status = tokio::time::timeout(Duration::from_secs(5), child.wait())
        .await
        .expect("child wait timed out")
        .expect("wait child");

    assert!(
        status.success(),
        "child failed with {status:?}; output={output:?}"
    );
    assert!(output.contains("ready"), "missing ready output: {output:?}");
    assert!(
        output.contains("33 101"),
        "child did not observe resized pty: {output:?}"
    );
    assert!(
        output.contains("input:hello-login-tty"),
        "child did not receive pty input: {output:?}"
    );
}

#[tokio::test]
async fn cancelled_account_lookup_retains_admission_until_nss_returns() {
    let slots = Arc::new(Semaphore::new(
        pplx_space_spaced_common::process_limits::START_PAYLOAD_SLOTS as usize,
    ));
    let (started_tx, started_rx) = tokio::sync::oneshot::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    let lookup = tokio::spawn(resolve_process_account(slots.clone(), None, move || {
        let _ = started_tx.send(());
        release_rx.recv().unwrap();
        Err(Status::unavailable("lookup fixture finished"))
    }));
    started_rx.await.unwrap();
    lookup.abort();
    let _ = lookup.await;
    let retry = resolve_process_account(slots.clone(), None, || {
        Err(Status::unavailable("lookup ran"))
    })
    .await;
    release_tx.send(()).unwrap();
    assert_eq!(retry.unwrap_err().code(), tonic::Code::ResourceExhausted);
    drop(
        tokio::time::timeout(Duration::from_secs(1), slots.acquire())
            .await
            .unwrap()
            .unwrap(),
    );
}
