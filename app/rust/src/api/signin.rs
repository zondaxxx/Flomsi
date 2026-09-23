//! Sign-in through the provider's own page (Google, Microsoft): the browser step is the
//! app's, everything else happens here. On a computer the browser comes back to a loopback
//! address this side listens on; on a phone the system's sign-in sheet comes back to the
//! app's own URL scheme and Dart hands that URL over.

use super::mail::{account_dto, core, AccountDto};
use anyhow::{anyhow, Result};
use flutter_rust_bridge::frb;
use mailcore::auth::{self, Loopback, OAuthClient, OAuthProvider, Pkce};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tokio::sync::Notify;
use std::time::Duration;

/// How long the browser step may take.
const SIGN_IN_TIMEOUT: Duration = Duration::from_secs(600);

/// The app registrations this build was given at build time: `FLOMSI_GOOGLE_CLIENT_ID`
/// and `FLOMSI_GOOGLE_CLIENT_SECRET` (desktop type), `FLOMSI_GOOGLE_IOS_CLIENT_ID`,
/// `FLOMSI_GOOGLE_ANDROID_CLIENT_ID`, `FLOMSI_MICROSOFT_CLIENT_ID`.
fn client(provider: OAuthProvider, mobile: bool) -> Option<OAuthClient> {
    let nonempty = |v: Option<&'static str>| v.map(str::trim).filter(|v| !v.is_empty());
    match provider {
        OAuthProvider::Google => {
            // Phones: the client of their own type, whose reversed ID is the URL scheme the
            // sign-in sheet returns to. Computers: the desktop type with its public secret.
            if mobile {
                let id = if cfg!(target_os = "android") {
                    nonempty(option_env!("FLOMSI_GOOGLE_ANDROID_CLIENT_ID"))
                } else {
                    nonempty(option_env!("FLOMSI_GOOGLE_IOS_CLIENT_ID"))
                };
                id.map(|id| OAuthClient {
                    provider,
                    client_id: id.into(),
                    client_secret: None,
                })
            } else {
                nonempty(option_env!("FLOMSI_GOOGLE_CLIENT_ID")).map(|id| OAuthClient {
                    provider,
                    client_id: id.into(),
                    client_secret: nonempty(option_env!("FLOMSI_GOOGLE_CLIENT_SECRET"))
                        .map(Into::into),
                })
            }
        }
        OAuthProvider::Microsoft => {
            nonempty(option_env!("FLOMSI_MICROSOFT_CLIENT_ID")).map(|id| OAuthClient {
                provider,
                client_id: id.into(),
                client_secret: None,
            })
        }
    }
}

/// The redirect a phone's sign-in sheet returns to (registered for the client).
fn mobile_redirect(client: &OAuthClient) -> String {
    match client.provider {
        OAuthProvider::Google => {
            let id = client
                .client_id
                .trim_end_matches(".apps.googleusercontent.com");
            format!("com.googleusercontent.apps.{id}:/oauth2redirect")
        }
        OAuthProvider::Microsoft => format!("msal{}://auth", client.client_id),
    }
}

/// Which providers this build can sign in with (`google`, `microsoft`).
#[frb(sync)]
pub fn oauth_providers(mobile: bool) -> Vec<String> {
    [OAuthProvider::Google, OAuthProvider::Microsoft]
        .into_iter()
        .filter(|p| client(*p, mobile).is_some())
        .map(|p| p.as_str().to_string())
        .collect()
}

struct Session {
    client: OAuthClient,
    pkce: Pkce,
    state: String,
    redirect_uri: String,
    loopback: Option<Loopback>,
    /// Signing an account in again: the address it must be.
    expect: Option<String>,
    /// Woken by [oauth_cancel] while [oauth_finish] waits.
    cancel: Arc<Notify>,
}

/// Sessions being waited on, for [oauth_cancel] to reach.
static WAITING: Mutex<Option<HashMap<String, Arc<Notify>>>> = Mutex::new(None);

static SESSIONS: Mutex<Option<HashMap<String, Session>>> = Mutex::new(None);

fn put(s: Session) -> String {
    let id = s.state.clone();
    SESSIONS
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .get_or_insert_with(HashMap::new)
        .insert(id.clone(), s);
    id
}

fn take(id: &str) -> Result<Session> {
    SESSIONS
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .as_mut()
        .and_then(|m| m.remove(id))
        .ok_or_else(|| anyhow!("this sign-in has ended; start again"))
}

pub struct OAuthStartDto {
    /// Handed back to [oauth_finish] / [oauth_finish_with_redirect].
    pub session: String,
    /// Open this in the browser (or the system's sign-in sheet).
    pub url: String,
    /// The URL scheme the sheet should watch for (phones).
    pub callback_scheme: String,
}

/// Start signing in with `provider` (`google`, `microsoft`). `mobile`: the phone flow with
/// the app's URL scheme; otherwise a loopback address on this computer. `expect_email`:
/// signing an existing account in again (also the hint for the provider's page).
pub async fn oauth_begin(provider: String, mobile: bool, expect_email: Option<String>) -> Result<OAuthStartDto> {
    let login_hint = expect_email.clone().unwrap_or_default();
    let p = OAuthProvider::parse(&provider).ok_or_else(|| anyhow!("unknown provider {provider}"))?;
    let client = client(p, mobile).ok_or_else(|| anyhow!("{provider} sign-in is not set up in this build"))?;
    let pkce = Pkce::new();
    let state = auth::random_string(32);
    let (redirect_uri, loopback) = if mobile {
        (mobile_redirect(&client), None)
    } else {
        let lb = Loopback::bind(p).await?;
        (lb.redirect_uri.clone(), Some(lb))
    };
    let url = auth::authorization_url(&client, &redirect_uri, &pkce, &state, Some(login_hint.trim()));
    let callback_scheme = redirect_uri.split(':').next().unwrap_or("").to_string();
    let session = put(Session {
        client,
        pkce,
        state,
        redirect_uri,
        loopback,
        expect: expect_email.filter(|e| !e.trim().is_empty()),
        cancel: Arc::new(Notify::new()),
    });
    Ok(OAuthStartDto {
        session,
        url,
        callback_scheme,
    })
}

async fn finish(s: Session, code: String) -> Result<AccountDto> {
    let tokens = auth::exchange_code(&s.client, &code, &s.pkce.verifier, &s.redirect_uri).await?;
    let a = core()?
        .add_oauth_account(&s.client, &tokens, s.expect.as_deref())
        .await?;
    Ok(account_dto(a, 0))
}

/// Computers: wait for the browser to come back to the loopback address, then add the
/// account.
pub async fn oauth_finish(session: String) -> Result<AccountDto> {
    let mut s = take(&session)?;
    let lb = s
        .loopback
        .take()
        .ok_or_else(|| anyhow!("this sign-in expects the redirect URL"))?;
    let cancel = s.cancel.clone();
    WAITING
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .get_or_insert_with(HashMap::new)
        .insert(session.clone(), cancel.clone());
    let code = tokio::select! {
        c = lb.code(&s.state, SIGN_IN_TIMEOUT) => c,
        _ = cancel.notified() => Err(mailcore::Error::Auth("sign-in: cancelled: closed in Flomsi".into())),
    };
    WAITING
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .as_mut()
        .map(|m| m.remove(&session));
    finish(s, code?).await
}

/// Phones: the URL the sign-in sheet came back with.
pub async fn oauth_finish_with_redirect(session: String, redirect: String) -> Result<AccountDto> {
    let s = take(&session)?;
    let code = auth::code_from_redirect(&redirect, &s.state)?;
    finish(s, code).await
}

/// What the phone's sign-in sheet (AppAuth) needs; the code it returns goes to
/// [oauth_complete], which trades it here.
pub struct MobileAuthDto {
    pub client_id: String,
    pub redirect_uri: String,
    pub authorization_endpoint: String,
    pub token_endpoint: String,
    pub scopes: Vec<String>,
    /// Extra query parameters, as `key=value`.
    pub parameters: Vec<String>,
}

pub fn oauth_mobile_request(provider: String) -> Result<MobileAuthDto> {
    let p = OAuthProvider::parse(&provider).ok_or_else(|| anyhow!("unknown provider {provider}"))?;
    let client = client(p, true).ok_or_else(|| anyhow!("{provider} sign-in is not set up in this build"))?;
    let (authorization_endpoint, token_endpoint) = auth::endpoints(p);
    let parameters = match p {
        // A refresh token every time, also for someone who signed in before.
        OAuthProvider::Google => vec!["access_type=offline".into(), "prompt=consent".into()],
        OAuthProvider::Microsoft => vec!["prompt=select_account".into()],
    };
    Ok(MobileAuthDto {
        redirect_uri: mobile_redirect(&client),
        client_id: client.client_id,
        authorization_endpoint: authorization_endpoint.into(),
        token_endpoint: token_endpoint.into(),
        scopes: p.scopes().split_whitespace().map(String::from).collect(),
        parameters,
    })
}

/// Phones: the code and PKCE verifier the sign-in sheet came back with. `expect_email`:
/// signing an existing account in again.
pub async fn oauth_complete(
    provider: String,
    code: String,
    verifier: String,
    redirect_uri: String,
    expect_email: Option<String>,
) -> Result<AccountDto> {
    let p = OAuthProvider::parse(&provider).ok_or_else(|| anyhow!("unknown provider {provider}"))?;
    let client = client(p, true).ok_or_else(|| anyhow!("{provider} sign-in is not set up in this build"))?;
    let tokens = auth::exchange_code(&client, &code, &verifier, &redirect_uri).await?;
    let a = core()?
        .add_oauth_account(&client, &tokens, expect_email.as_deref())
        .await?;
    Ok(account_dto(a, 0))
}

/// Give up a sign-in that was started: a waiting [oauth_finish] returns `cancelled` and
/// the loopback listener closes.
#[frb(sync)]
pub fn oauth_cancel(session: String) {
    let _ = take(&session);
    if let Some(n) = WAITING
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .as_mut()
        .and_then(|m| m.remove(&session))
    {
        n.notify_one();
    }
}
