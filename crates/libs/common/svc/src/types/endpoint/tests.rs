use super::HttpsPollingUrl;

#[test]
fn https_polling_url_rejects_non_https_schemes() {
    HttpsPollingUrl::parse("https://api.example.com/poll").unwrap();
    HttpsPollingUrl::parse("http://api.example.com/poll").unwrap_err();
    HttpsPollingUrl::parse("https:///path").unwrap_err();
    HttpsPollingUrl::parse("file:///tmp/socket").unwrap_err();
    HttpsPollingUrl::parse("/relative/path").unwrap_err();
}
