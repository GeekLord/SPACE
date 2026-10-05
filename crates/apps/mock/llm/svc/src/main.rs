use std::sync::Arc;

use axum::Router;
use axum::extract::State;
use axum::http::{HeaderMap, Method};
use axum::response::{Html, IntoResponse, Json};
use clap::Parser;
use std::fmt::Write as _;
use tokio::sync::RwLock;

#[derive(Parser)]
#[command(
    name = "space-mock-llm-svc",
    about = "SPACE mock LLM provider",
    version,
    disable_version_flag = true
)]
struct Cli {
    /// Print version.
    #[arg(short = 'v', long = "version", action = clap::ArgAction::Version)]
    _version: (),

    #[arg(long, default_value = "0.0.0.0:80")]
    listen: String,
}

#[derive(Clone)]
struct RequestRecord {
    timestamp: String,
    method: String,
    path: String,
    headers: Vec<(String, String)>,
    body: Option<String>,
}

type RequestLog = Arc<RwLock<Vec<RequestRecord>>>;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let telemetry = pplx_space_common_svc::init_service("space-mock-llm")?;

    let cli = Cli::parse();
    let log: RequestLog = Arc::new(RwLock::new(Vec::new()));

    let app = Router::new()
        .route("/", axum::routing::get(index_handler))
        .route("/clear", axum::routing::post(clear_handler))
        .route(
            "/favicon.ico",
            axum::routing::get(|| async { axum::http::StatusCode::NOT_FOUND }),
        )
        .fallback(api_handler)
        .with_state(log);

    let listener = tokio::net::TcpListener::bind(&cli.listen).await?;
    tracing::info!(
        listen = %cli.listen,
        "mock LLM service listening"
    );
    axum::serve(listener, app).await?;
    pplx_space_common_svc::shutdown_telemetry(telemetry).await;
    Ok(())
}

fn now_iso() -> String {
    let secs = match std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) {
        Ok(duration) => duration.as_secs(),
        Err(error) => {
            tracing::warn!(%error, "system clock is before UNIX_EPOCH");
            0
        }
    };
    let Ok(secs_i64) = i64::try_from(secs) else {
        return format!("{secs}");
    };
    let Ok(dt) = time::OffsetDateTime::from_unix_timestamp(secs_i64) else {
        return format!("{secs}");
    };
    dt.format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_else(|_| format!("{secs}"))
}

async fn api_handler(
    State(log): State<RequestLog>,
    method: Method,
    uri: axum::http::Uri,
    headers: HeaderMap,
    body: axum::body::Bytes,
) -> impl IntoResponse {
    let record = RequestRecord {
        timestamp: now_iso(),
        method: method.to_string(),
        path: uri.to_string(),
        headers: headers
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_str().unwrap_or("<binary>").to_string()))
            .collect(),
        body: if body.is_empty() {
            None
        } else {
            Some(String::from_utf8_lossy(&body).to_string())
        },
    };
    log.write().await.push(record);
    Json(serde_json::json!({"message": "mock response", "model": "mock-1"}))
}

async fn clear_handler(State(log): State<RequestLog>) -> impl IntoResponse {
    log.write().await.clear();
    axum::response::Redirect::to("/")
}

async fn index_handler(State(log): State<RequestLog>) -> impl IntoResponse {
    let records = log.read().await;
    let mut html = String::from(
        r#"<!DOCTYPE html><html><head><title>Mock LLM - Request Log</title>
<meta http-equiv="refresh" content="3">
<style>
body { font-family: monospace; background: #1a1a2e; color: #e0e0e0; padding: 20px; }
h1 { color: #00d4ff; }
.entry { background: #16213e; border: 1px solid #0f3460; border-radius: 8px; padding: 16px; margin: 12px 0; }
.timestamp { color: #888; }
.method { color: #00d4ff; font-weight: bold; }
.path { color: #e94560; }
.header-name { color: #f9a826; }
.credential { background: #2a0a2a; border: 1px solid #e94560; padding: 2px 6px; border-radius: 4px; }
.body { background: #0a0a1a; padding: 8px; border-radius: 4px; white-space: pre-wrap; max-height: 200px; overflow: auto; }
</style></head><body><h1>Mock LLM Provider - Request Log</h1>"#,
    );
    write!(
        html,
        "<p>Showing {} request(s). Auto-refreshes every 3s. <form method=\"post\" action=\"/clear\" style=\"display:inline\"><button type=\"submit\" style=\"background:#e94560;color:#fff;border:none;padding:4px 12px;border-radius:4px;cursor:pointer;font-family:monospace\">Clear Log</button></form></p>",
        records.len()
    )
    .expect("writing to a String cannot fail");

    for record in records.iter().rev() {
        html.push_str("<div class=\"entry\">");
        write!(
            html,
            "<div><span class=\"timestamp\">{}</span> <span class=\"method\">{}</span> <span class=\"path\">{}</span></div>",
            record.timestamp,
            record.method,
            html_escape(&record.path)
        )
        .expect("writing to a String cannot fail");
        html.push_str("<div style=\"margin-top:8px\"><strong>Headers:</strong><br>");
        for (name, value) in &record.headers {
            let class = if name == "x-api-key" || name == "authorization" {
                "credential"
            } else {
                "header-name"
            };
            write!(
                html,
                "<span class=\"header-name\">{name}</span>: <span class=\"{class}\">{}</span><br>",
                html_escape(value)
            )
            .expect("writing to a String cannot fail");
        }
        html.push_str("</div>");
        if let Some(body) = &record.body {
            write!(
                html,
                "<div style=\"margin-top:8px\"><strong>Body:</strong><div class=\"body\">{}</div></div>",
                html_escape(body)
            )
            .expect("writing to a String cannot fail");
        }
        html.push_str("</div>");
    }
    html.push_str("</body></html>");
    Html(html)
}

fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}
