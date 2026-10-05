use std::{
    io::Write,
    process::{Command, Stdio},
};

use axum::{
    Json, Router,
    http::{HeaderMap, StatusCode},
    routing::{get, post},
};
use serde_json::json;
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};

fn command_with_proxy(proxy_url: &str) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_space"));
    for variable in ["HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"] {
        command.env(variable, proxy_url);
    }
    command.env_remove("NO_PROXY").env_remove("no_proxy");
    command
}

#[tokio::test]
async fn login_reads_the_api_environment_and_prints_only_a_verified_token() {
    let router = Router::new()
        .route(
            "/auth/v1/sessions",
            post(|Json(body): Json<serde_json::Value>| async move {
                assert_eq!(body["email"], "operator@example.com");
                let status = if body["password"] == "synthetic-password" {
                    StatusCode::OK
                } else {
                    StatusCode::UNAUTHORIZED
                };
                (status, Json(json!({"token": "synthetic-session"})))
            }),
        )
        .route(
            "/admin/api/v1/templates",
            get(|headers: HeaderMap| async move {
                assert_eq!(headers["authorization"], "Bearer synthetic-session");
                StatusCode::OK
            }),
        )
        .route(
            "/admin/api/v1/nodes",
            get(|headers: HeaderMap| async move {
                assert_eq!(headers["authorization"], "Bearer synthetic-session");
                Json(json!([]))
            }),
        );
    let auth_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let auth_url = format!("http://{}", auth_listener.local_addr().unwrap());
    let auth_router = router.clone();
    let auth_server =
        tokio::spawn(async move { axum::serve(auth_listener, auth_router).await.unwrap() });
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    let proxy_requests = Arc::new(AtomicUsize::new(0));
    let received = proxy_requests.clone();
    let proxy_router = Router::new().fallback(move || {
        let received = received.clone();
        async move {
            received.fetch_add(1, Ordering::SeqCst);
            StatusCode::BAD_GATEWAY
        }
    });
    let proxy_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let proxy_url = format!("http://{}", proxy_listener.local_addr().unwrap());
    let proxy = tokio::spawn(async move {
        axum::serve(proxy_listener, proxy_router).await.unwrap();
    });

    for (print_token, password, api_flag, succeeds, expected_stdout) in [
        (
            true,
            "synthetic-password",
            false,
            true,
            "synthetic-session\n",
        ),
        (
            true,
            "synthetic-password",
            true,
            true,
            "synthetic-session\n",
        ),
        (false, "synthetic-password", false, true, ""),
        (true, "wrong-password", false, false, ""),
        (false, "wrong-password", false, false, ""),
    ] {
        let url = url.clone();
        let auth_url = auth_url.clone();
        let proxy_url = proxy_url.clone();
        let output = tokio::task::spawn_blocking(move || {
            let mut command = command_with_proxy(&proxy_url);
            command.args([
                "login",
                "--email",
                "operator@example.com",
                "--password-stdin",
            ]);
            if print_token {
                command.arg("--print-token");
            }
            if api_flag {
                command.arg("--api-url").arg(&url);
                command.arg("--auth-url").arg(auth_url);
                command.env("SPACE_API_URL", "http://127.0.0.1:1");
            } else {
                command.env("SPACE_API_URL", &url);
            }
            let mut child = command
                .env_remove("SPACE_API_TOKEN")
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap();
            writeln!(child.stdin.take().unwrap(), "{password}").unwrap();
            child.wait_with_output().unwrap()
        })
        .await
        .unwrap();

        assert_eq!(
            output.status.success(),
            succeeds,
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(String::from_utf8(output.stdout).unwrap(), expected_stdout);
        let stderr = String::from_utf8(output.stderr).unwrap();
        assert!(!stderr.contains("synthetic-session"));
        assert!(!stderr.contains(password));
    }
    let output = tokio::task::spawn_blocking(move || {
        command_with_proxy(&proxy_url)
            .args(["list-nodes", "--json"])
            .env("SPACE_API_URL", url)
            .env("SPACE_API_TOKEN", "synthetic-session")
            .output()
            .unwrap()
    })
    .await
    .unwrap();

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&output.stdout).unwrap(),
        json!([])
    );
    assert_eq!(proxy_requests.load(Ordering::SeqCst), 0);
    proxy.abort();
    assert!(proxy.await.unwrap_err().is_cancelled());
    auth_server.abort();
    assert!(auth_server.await.unwrap_err().is_cancelled());
    server.abort();
    assert!(server.await.unwrap_err().is_cancelled());
}

#[cfg(unix)]
#[test]
fn password_prompt_restores_terminal_settings_after_eof_read_error_or_signal() {
    use std::{fs::File, io::Read};

    use nix::{
        pty::openpty,
        sys::{
            signal::{Signal, kill},
            termios::{LocalFlags, tcgetattr},
        },
        unistd::Pid,
    };

    for (input, signal) in [
        (b"\x04".as_slice(), None),
        (b"\xff\n".as_slice(), None),
        (b"".as_slice(), Some(Signal::SIGINT)),
        (b"".as_slice(), Some(Signal::SIGTERM)),
        (b"".as_slice(), Some(Signal::SIGTSTP)),
    ] {
        let terminal = openpty(None, None).unwrap();
        let original = tcgetattr(&terminal.slave).unwrap();
        let mut master = File::from(terminal.master);
        let child = Command::new(env!("CARGO_BIN_EXE_space"))
            .args(["login", "--email", "operator@example.com", "--print-token"])
            .env("SPACE_API_URL", "http://127.0.0.1:1")
            .env_remove("SPACE_API_TOKEN")
            .stdin(Stdio::from(terminal.slave.try_clone().unwrap()))
            .stderr(Stdio::from(terminal.slave.try_clone().unwrap()))
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut prompt = vec![0; b"SPACE password: ".len()];
        master.read_exact(&mut prompt).unwrap();
        assert_eq!(prompt, b"SPACE password: ");
        assert!(
            !tcgetattr(&terminal.slave)
                .unwrap()
                .local_flags
                .contains(LocalFlags::ECHO)
        );

        if let Some(signal) = signal {
            kill(Pid::from_raw(child.id() as i32), signal).unwrap();
        } else {
            master.write_all(input).unwrap();
        }
        let output = child.wait_with_output().unwrap();

        assert!(!output.status.success());
        if let Some(signal) = signal {
            assert_eq!(output.status.code(), Some(128 + signal as i32));
        }
        assert!(output.stdout.is_empty());
        assert_eq!(tcgetattr(&terminal.slave).unwrap(), original, "{signal:?}");
    }
}

#[cfg(unix)]
#[test]
fn password_stdin_rejects_a_terminal() {
    use nix::{pty::openpty, sys::termios::tcgetattr};
    use std::fs::File;

    let terminal = openpty(None, None).unwrap();
    let original = tcgetattr(&terminal.slave).unwrap();
    let mut master = File::from(terminal.master);
    let child = Command::new(env!("CARGO_BIN_EXE_space"))
        .args([
            "login",
            "--email",
            "operator@example.com",
            "--password-stdin",
        ])
        .env("SPACE_API_URL", "http://127.0.0.1:1")
        .stdin(Stdio::from(terminal.slave.try_clone().unwrap()))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();

    master.write_all(b"\x04").unwrap();
    let output = child.wait_with_output().unwrap();

    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    assert!(
        String::from_utf8(output.stderr)
            .unwrap()
            .contains("--password-stdin requires piped input")
    );
    assert_eq!(tcgetattr(&terminal.slave).unwrap(), original);
}
