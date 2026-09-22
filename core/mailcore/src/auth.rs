//! OAuth2 helpers: PKCE challenge, Google authorization URL, XOAUTH2 SASL string.
//! Token exchange over HTTP lands with the Gmail provider in phase 1.

use base64::Engine;
use sha2::{Digest, Sha256};

pub const GOOGLE_AUTH_URL: &str = "https://accounts.google.com/o/oauth2/v2/auth";
pub const GOOGLE_TOKEN_URL: &str = "https://oauth2.googleapis.com/token";
pub const GMAIL_SCOPES: &[&str] = &["https://mail.google.com/", "openid", "email"];

#[derive(Debug, Clone)]
pub struct Pkce {
    pub verifier: String,
    pub challenge: String,
}

impl Pkce {
    pub fn new() -> Pkce {
        let verifier: String = (0..64)
            .map(|_| {
                const CHARS: &[u8] =
                    b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";
                CHARS[rand::random_range(0..CHARS.len())] as char
            })
            .collect();
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

/// Authorization URL for the loopback flow (RFC 8252) on desktop.
pub fn google_auth_url(client_id: &str, redirect_uri: &str, pkce: &Pkce, state: &str) -> String {
    let mut u = url::Url::parse(GOOGLE_AUTH_URL).expect("static url");
    u.query_pairs_mut()
        .append_pair("client_id", client_id)
        .append_pair("redirect_uri", redirect_uri)
        .append_pair("response_type", "code")
        .append_pair("scope", &GMAIL_SCOPES.join(" "))
        .append_pair("code_challenge", &pkce.challenge)
        .append_pair("code_challenge_method", "S256")
        .append_pair("access_type", "offline")
        .append_pair("prompt", "consent")
        .append_pair("state", state);
    u.to_string()
}

/// SASL XOAUTH2 initial client response, base64 encoded.
pub fn xoauth2_response(user: &str, access_token: &str) -> String {
    let raw = format!("user={user}\x01auth=Bearer {access_token}\x01\x01");
    base64::engine::general_purpose::STANDARD.encode(raw)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pkce_shape() {
        let p = Pkce::new();
        assert_eq!(p.verifier.len(), 64);
        assert_eq!(p.challenge.len(), 43);
    }

    #[test]
    fn auth_url_has_pkce() {
        let p = Pkce::new();
        let u = google_auth_url("cid", "http://127.0.0.1:1/cb", &p, "st");
        assert!(u.contains("code_challenge_method=S256"));
        assert!(u.contains("client_id=cid"));
    }
}
