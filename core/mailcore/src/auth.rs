//! OAuth 2.0 for Gmail and Microsoft mail: authorization URL with PKCE (RFC 7636), code
//! exchange and refresh at the token endpoint, the address from the ID token, and the
//! XOAUTH2 string IMAP and SMTP sign in with.

use crate::error::{Error, Result};
use base64::Engine;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// Who signs the user in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OAuthProvider {
    Google,
    Microsoft,
}

impl OAuthProvider {
    pub fn parse(s: &str) -> Option<OAuthProvider> {
        match s {
            "google" => Some(OAuthProvider::Google),
            "microsoft" => Some(OAuthProvider::Microsoft),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            OAuthProvider::Google => "google",
            OAuthProvider::Microsoft => "microsoft",
        }
    }

    fn auth_url(self) -> &'static str {
        match self {
            OAuthProvider::Google => "https://accounts.google.com/o/oauth2/v2/auth",
            OAuthProvider::Microsoft => {
                "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
            }
        }
    }

    fn token_url(self) -> String {
        #[cfg(test)]
        if let Some(u) = TEST_TOKEN_URL.lock().unwrap().clone() {
            return u;
        }
        match self {
            OAuthProvider::Google => "https://oauth2.googleapis.com/token",
            OAuthProvider::Microsoft => {
                "https://login.microsoftonline.com/common/oauth2/v2.0/token"
            }
        }
        .to_string()
    }

    /// Mail over IMAP and SMTP, the address (ID token), and a refresh token.
    pub fn scopes(self) -> &'static str {
        match self {
            OAuthProvider::Google => "https://mail.google.com/ openid email",
            OAuthProvider::Microsoft => {
                "https://outlook.office.com/IMAP.AccessAsUser.All \
                 https://outlook.office.com/SMTP.Send offline_access openid email profile"
            }
        }
    }
}

/// The authorization and token endpoints of [provider] (for a sign-in sheet that makes the
/// authorization request itself).
pub fn endpoints(provider: OAuthProvider) -> (&'static str, &'static str) {
    match provider {
        OAuthProvider::Google => (
            "https://accounts.google.com/o/oauth2/v2/auth",
            "https://oauth2.googleapis.com/token",
        ),
        OAuthProvider::Microsoft => (
            "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
            "https://login.microsoftonline.com/common/oauth2/v2.0/token",
        ),
    }
}

/// Tests point the token endpoint at their own server.
#[cfg(test)]
pub(crate) static TEST_TOKEN_URL: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

/// An app registration: the client ID (and, for Google's desktop clients, the secret that
/// is shipped in every copy of the app and is not a secret in the usual sense).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OAuthClient {
    pub provider: OAuthProvider,
    pub client_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub client_secret: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Pkce {
    pub verifier: String,
    pub challenge: String,
}

impl Pkce {
    pub fn new() -> Pkce {
        let verifier = random_string(64);
        let digest = Sha256::digest(verifier.as_bytes());
        let challenge = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(digest);
        Pkce {
            verifier,
            challenge,
        }
    }
}

impl Default for Pkce {
    fn default() -> Self {
        Self::new()
    }
}

/// Unreserved characters (RFC 3986), for PKCE verifiers and `state`.
pub fn random_string(len: usize) -> String {
    const CHARS: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";
    (0..len)
        .map(|_| CHARS[rand::random_range(0..CHARS.len())] as char)
        .collect()
}

/// Where the browser goes to sign in; it comes back to [redirect_uri] with `code` and
/// `state`.
pub fn authorization_url(
    client: &OAuthClient,
    redirect_uri: &str,
    pkce: &Pkce,
    state: &str,
    login_hint: Option<&str>,
) -> String {
    let mut u = url::Url::parse(client.provider.auth_url()).expect("static url");
    {
        let mut q = u.query_pairs_mut();
        q.append_pair("client_id", &client.client_id)
            .append_pair("redirect_uri", redirect_uri)
            .append_pair("response_type", "code")
            .append_pair("scope", client.provider.scopes())
            .append_pair("code_challenge", &pkce.challenge)
            .append_pair("code_challenge_method", "S256")
            .append_pair("state", state);
        match client.provider {
            // A refresh token every time, also for someone who signed in before.
            OAuthProvider::Google => {
                q.append_pair("access_type", "offline")
                    .append_pair("prompt", "consent");
            }
            OAuthProvider::Microsoft => {
                q.append_pair("prompt", "select_account");
            }
        }
        if let Some(hint) = login_hint.filter(|h| !h.is_empty()) {
            q.append_pair("login_hint", hint);
        }
    }
    u.to_string()
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Tokens {
    pub access_token: String,
    /// Absent from a refresh answer that keeps the old one.
    pub refresh_token: Option<String>,
    /// Unix seconds.
    pub expires_at: i64,
    pub id_token: Option<String>,
    /// What was granted (Google lets people untick the mail box on its consent page).
    #[serde(default)]
    pub scope: Option<String>,
}

#[derive(Deserialize)]
struct TokenAnswer {
    access_token: Option<String>,
    refresh_token: Option<String>,
    expires_in: Option<i64>,
    id_token: Option<String>,
    scope: Option<String>,
    error: Option<String>,
    error_description: Option<String>,
}

fn form(pairs: &[(&str, &str)]) -> String {
    url::form_urlencoded::Serializer::new(String::new())
        .extend_pairs(pairs)
        .finish()
}

async fn token_request(client: &OAuthClient, mut pairs: Vec<(&str, &str)>) -> Result<Tokens> {
    pairs.push(("client_id", &client.client_id));
    if let Some(secret) = &client.client_secret {
        pairs.push(("client_secret", secret));
    }
    let r = crate::http::post_form(&client.provider.token_url(), &form(&pairs)).await?;
    let answer: TokenAnswer = serde_json::from_str(&r.body).map_err(|_| {
        Error::Other(format!(
            "the sign-in server answered {} with something unreadable",
            r.status
        ))
    })?;
    if let Some(e) = answer.error {
        let text = match answer.error_description {
            Some(d) => format!("{e}: {d}"),
            None => e.clone(),
        };
        // The grant is gone (revoked, expired, password changed): sign in again.
        return Err(if e == "invalid_grant" || e == "unauthorized_client" {
            Error::Auth(text)
        } else if text.contains("AADSTS65001") || text.contains("AADSTS90094") {
            Error::Auth(format!("sign-in: admin: {text}"))
        } else {
            Error::Other(text)
        });
    }
    let access_token = answer
        .access_token
        .ok_or_else(|| Error::Other(format!("no access token in the answer ({})", r.status)))?;
    Ok(Tokens {
        access_token,
        refresh_token: answer.refresh_token,
        expires_at: chrono::Utc::now().timestamp() + answer.expires_in.unwrap_or(3600),
        id_token: answer.id_token,
        scope: answer.scope,
    })
}

/// Trade the code from the redirect for tokens.
pub async fn exchange_code(
    client: &OAuthClient,
    code: &str,
    verifier: &str,
    redirect_uri: &str,
) -> Result<Tokens> {
    token_request(
        client,
        vec![
            ("grant_type", "authorization_code"),
            ("code", code),
            ("code_verifier", verifier),
            ("redirect_uri", redirect_uri),
        ],
    )
    .await
}

/// A new access token from the refresh token.
pub async fn refresh(client: &OAuthClient, refresh_token: &str) -> Result<Tokens> {
    let scope = client.provider.scopes();
    let mut pairs = vec![
        ("grant_type", "refresh_token"),
        ("refresh_token", refresh_token),
    ];
    // Microsoft wants the scopes again; Google keeps the granted ones.
    if client.provider == OAuthProvider::Microsoft {
        pairs.push(("scope", scope));
    }
    token_request(client, pairs).await
}

/// The address an ID token names. The token came straight from the token endpoint over
/// TLS, so its payload is read, not verified.
pub fn email_from_id_token(id_token: &str) -> Option<String> {
    let payload = id_token.split('.').nth(1)?;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload.trim_end_matches('='))
        .ok()?;
    let claims: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
    ["email", "preferred_username", "upn"]
        .iter()
        .filter_map(|k| claims.get(*k)?.as_str())
        .find(|v| v.contains('@'))
        .map(|v| v.to_ascii_lowercase())
}

/// The `code` of a redirect URL, after checking its `state`. An `error` there (the user
/// said no) comes back as an error.
pub fn code_from_redirect(url: &str, state: &str) -> Result<String> {
    let u = url::Url::parse(url).map_err(|e| Error::Other(format!("redirect: {e}")))?;
    let get = |k: &str| {
        u.query_pairs()
            .find(|(key, _)| key == k)
            .map(|(_, v)| v.into_owned())
    };
    if let Some(e) = get("error") {
        let detail = get("error_description").unwrap_or_default();
        let kind = match e.as_str() {
            "access_denied" => "denied",
            "admin_policy_enforced" => "admin",
            _ if detail.contains("AADSTS65001") || detail.contains("AADSTS90094") => "admin",
            _ => "failed",
        };
        return Err(Error::Auth(format!("sign-in: {kind}: {e} {detail}")));
    }
    if get("state").as_deref() != Some(state) {
        return Err(Error::Auth(
            "sign-in: failed: the answer was not for this request".into(),
        ));
    }
    get("code").ok_or_else(|| Error::Auth("sign-in: failed: the answer had no code".into()))
}

/// A one-shot web server on 127.0.0.1 for the browser to come back to (RFC 8252, loopback
/// redirect): the way desktop apps sign in with Google and Microsoft.
pub struct Loopback {
    v4: tokio::net::TcpListener,
    /// The same port on ::1, where a browser may take `localhost`.
    v6: Option<tokio::net::TcpListener>,
    pub redirect_uri: String,
}

/// What the browser tab shows once the code is taken.
const DONE_PAGE: &str = "<!doctype html><meta charset=utf-8><title>Flomsi</title>\
<style>body{font:15px -apple-system,Segoe UI,sans-serif;background:#16181d;color:#d7dae0;\
display:grid;place-items:center;height:90vh;margin:0}</style>\
<p>Signed in. You can close this tab and go back to Flomsi.</p>";

impl Loopback {
    /// A free port on this computer. Google takes `http://127.0.0.1:<port>`; Microsoft has
    /// `http://localhost` registered and ignores the port, but not a path.
    pub async fn bind(provider: OAuthProvider) -> Result<Loopback> {
        let v4 = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await?;
        let port = v4.local_addr()?.port();
        let v6 = tokio::net::TcpListener::bind(("::1", port)).await.ok();
        let host = match provider {
            OAuthProvider::Google => "127.0.0.1",
            OAuthProvider::Microsoft => "localhost",
        };
        Ok(Loopback {
            v4,
            v6,
            redirect_uri: format!("http://{host}:{port}"),
        })
    }

    async fn accept(&self) -> std::io::Result<tokio::net::TcpStream> {
        match &self.v6 {
            Some(v6) => tokio::select! {
                r = self.v4.accept() => r.map(|(s, _)| s),
                r = v6.accept() => r.map(|(s, _)| s),
            },
            None => self.v4.accept().await.map(|(s, _)| s),
        }
    }

    /// Wait for the browser's redirect and return its code (checked against [state]).
    pub async fn code(self, state: &str, timeout: std::time::Duration) -> Result<String> {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let wait = async {
            loop {
                let mut sock = self.accept().await?;
                let mut buf = vec![0u8; 8192];
                let mut n = 0;
                // The request line and headers; nothing more is needed.
                while n < buf.len() {
                    let got = sock.read(&mut buf[n..]).await?;
                    if got == 0 {
                        break;
                    }
                    n += got;
                    if buf[..n].windows(4).any(|w| w == b"\r\n\r\n") {
                        break;
                    }
                }
                let head = String::from_utf8_lossy(&buf[..n]).into_owned();
                let path = head
                    .lines()
                    .next()
                    .and_then(|l| l.split_whitespace().nth(1))
                    .unwrap_or("/")
                    .to_string();
                // Browsers ask for a favicon too: only the answer carries code or error.
                let answer = path.contains("code=") || path.contains("error=");
                if !answer {
                    let _ = sock
                        .write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                        .await;
                    continue;
                }
                let r = code_from_redirect(&format!("http://127.0.0.1{path}"), state);
                let page = match &r {
                    Ok(_) => DONE_PAGE.to_string(),
                    Err(e) => DONE_PAGE.replace(
                        "Signed in. You can close this tab and go back to Flomsi.",
                        &format!("Not signed in: {e}. Go back to Flomsi and try again."),
                    ),
                };
                let reply = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\
                     Content-Length: {}\r\nConnection: close\r\n\r\n{page}",
                    page.len()
                );
                let _ = sock.write_all(reply.as_bytes()).await;
                let _ = sock.shutdown().await;
                return r;
            }
        };
        tokio::time::timeout(timeout, wait)
            .await
            .map_err(|_| Error::Auth("sign-in: timeout: the page was open too long".into()))?
    }
}

/// SASL XOAUTH2 initial client response, base64 encoded.
pub fn xoauth2_response(user: &str, access_token: &str) -> String {
    let raw = format!("user={user}\x01auth=Bearer {access_token}\x01\x01");
    base64::engine::general_purpose::STANDARD.encode(raw)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn google() -> OAuthClient {
        OAuthClient {
            provider: OAuthProvider::Google,
            client_id: "cid.apps.googleusercontent.com".into(),
            client_secret: None,
        }
    }

    #[test]
    fn pkce_shape() {
        let p = Pkce::new();
        assert_eq!(p.verifier.len(), 64);
        assert_eq!(p.challenge.len(), 43);
    }

    #[test]
    fn auth_url_asks_for_mail_with_pkce() {
        let p = Pkce::new();
        let u = authorization_url(&google(), "http://127.0.0.1:1/cb", &p, "st", Some("a@b.c"));
        let parsed = url::Url::parse(&u).unwrap();
        let q: std::collections::HashMap<_, _> = parsed.query_pairs().into_owned().collect();
        assert_eq!(q["code_challenge_method"], "S256");
        assert_eq!(q["code_challenge"], p.challenge);
        assert_eq!(q["scope"], "https://mail.google.com/ openid email");
        assert_eq!(q["access_type"], "offline");
        assert_eq!(q["login_hint"], "a@b.c");
        assert_eq!(q["state"], "st");
    }

    #[test]
    fn the_address_comes_from_the_id_token() {
        let claims =
            r#"{"iss":"https://accounts.google.com","email":"Z@Gmail.com","email_verified":true}"#;
        let token = format!(
            "e30.{}.sig",
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(claims)
        );
        assert_eq!(email_from_id_token(&token).as_deref(), Some("z@gmail.com"));
        let ms = r#"{"preferred_username":"z@outlook.com"}"#;
        let token = format!(
            "e30.{}.sig",
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(ms)
        );
        assert_eq!(
            email_from_id_token(&token).as_deref(),
            Some("z@outlook.com")
        );
        assert_eq!(email_from_id_token("not a token"), None);
    }

    #[test]
    fn a_redirect_gives_its_code_only_for_our_state() {
        assert_eq!(
            code_from_redirect("http://127.0.0.1:5/cb?state=s1&code=abc", "s1").unwrap(),
            "abc"
        );
        assert!(code_from_redirect("http://127.0.0.1:5/cb?state=other&code=abc", "s1").is_err());
        match code_from_redirect("x:/cb?error=access_denied&state=s1", "s1") {
            Err(Error::Auth(m)) => assert!(m.starts_with("sign-in: denied:"), "{m}"),
            other => panic!("{other:?}"),
        }
    }

    #[tokio::test]
    async fn the_loopback_takes_the_code_and_ignores_the_favicon() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let lb = Loopback::bind(OAuthProvider::Google).await.unwrap();
        let uri = lb.redirect_uri.clone();
        assert!(uri.starts_with("http://127.0.0.1:"), "{uri}");
        let port: u16 = uri.rsplit(':').next().unwrap().parse().unwrap();
        let browser = tokio::spawn(async move {
            for path in ["/favicon.ico", "/?state=s9&code=the-code"] {
                let mut s = tokio::net::TcpStream::connect(("127.0.0.1", port))
                    .await
                    .unwrap();
                s.write_all(format!("GET {path} HTTP/1.1\r\nHost: x\r\n\r\n").as_bytes())
                    .await
                    .unwrap();
                let mut page = String::new();
                s.read_to_string(&mut page).await.unwrap();
                if path.contains("code=") {
                    assert!(page.contains("Signed in"), "{page}");
                }
            }
        });
        let code = lb
            .code("s9", std::time::Duration::from_secs(5))
            .await
            .unwrap();
        assert_eq!(code, "the-code");
        browser.await.unwrap();
    }
}
