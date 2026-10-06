//! Mendocino Remote Connectivity — session-broker client.
//!
//! The broker owns the policy the upstream server cannot express: at most 2 concurrent
//! viewers per machine and 5 concurrent sessions per user, plus superadmin break-glass
//! and the audit trail.
//!
//! Two sides, deliberately asymmetric:
//!
//! * **Target agent** calls [`authorize_inbound`] after the password check succeeds. It
//!   asks the broker whether a live ticket exists for the peer now connecting.
//! * **Operator client** calls [`request_session`] before connecting, then heartbeats so
//!   the slot is not reclaimed, and releases it on disconnect.
//!
//! The ticket never travels over the wire: `LoginRequest` has no field to carry one, and
//! adding one would mean changing the protobuf in the shared `hbb_common` submodule. The
//! agent knows who is connecting, so redemption is keyed on the peer's ID instead.
//!
//! Fail-closed: a configured broker that cannot be reached is a denial, never a waiver.
//! When no broker is configured at all the tool runs unmanaged — but the configuration
//! arrives inside a signed `custom.txt`, so it cannot be stripped to bypass the check.

use hbb_common::{
    bail,
    config::{Config, HARD_SETTINGS},
    lazy_static, log,
    tokio::{self, time::sleep},
    ResultType,
};
use serde_derive::Deserialize;
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::Duration,
};

/// Shown to the operator when the broker refuses the connection.
pub const LOGIN_MSG_SESSION_DENIED: &str = "Refused by Mendocino policy";

const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
const DEFAULT_VIEWER_CAP: usize = 2;
const DEFAULT_HEARTBEAT_SEC: u64 = 15;

lazy_static::lazy_static! {
    /// Bearer token for the logged-in operator. Memory only — never written to disk.
    static ref TOKEN: Arc<Mutex<Option<String>>> = Default::default();
    /// Live session tokens, keyed by the device they belong to.
    static ref LIVE_SESSIONS: Arc<Mutex<HashMap<String, String>>> = Default::default();
}

// --- configuration, from the signed custom.txt -----------------------------

fn hard(key: &str) -> String {
    HARD_SETTINGS
        .read()
        .unwrap()
        .get(key)
        .cloned()
        .unwrap_or_default()
}

pub fn broker_url() -> String {
    hard("mrc-broker-url").trim_end_matches('/').to_owned()
}

pub fn device_id() -> String {
    hard("mrc-device-id")
}

fn device_token() -> String {
    hard("mrc-device-token")
}

/// Whether this build has been provisioned to a broker.
pub fn is_enabled() -> bool {
    !broker_url().is_empty() && !device_id().is_empty() && !device_token().is_empty()
}

pub fn viewer_cap() -> usize {
    hard("mrc-max-viewers")
        .parse()
        .unwrap_or(DEFAULT_VIEWER_CAP)
}

fn heartbeat_interval() -> Duration {
    Duration::from_secs(
        hard("mrc-heartbeat-sec")
            .parse()
            .unwrap_or(DEFAULT_HEARTBEAT_SEC),
    )
}

// --- local enforcement -----------------------------------------------------

/// Remote-control connections currently authorized on this machine.
///
/// File transfer and port forwarding are deliberately excluded: the cap is about how many
/// people are watching the screen.
pub fn local_remote_viewers() -> usize {
    crate::server::AUTHED_CONNS
        .lock()
        .unwrap()
        .iter()
        .filter(|c| c.conn_type == crate::server::AuthConnType::Remote)
        .count()
}

/// The authoritative check. A tampered client could decline to call the broker at all, so
/// the limit has to be enforced on the machine being protected.
pub fn local_cap_reached() -> bool {
    local_remote_viewers() >= viewer_cap()
}

// --- wire types ------------------------------------------------------------

#[derive(Deserialize)]
struct ValidateResponse {
    allow: bool,
    #[serde(default)]
    reason: String,
    #[serde(default)]
    actor: String,
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
}

#[derive(Deserialize)]
pub struct SessionTicket {
    pub session_token: String,
    pub device_id: String,
    #[serde(default)]
    pub skip_device_password: bool,
}

fn http() -> ResultType<reqwest::Client> {
    Ok(reqwest::Client::builder()
        .timeout(REQUEST_TIMEOUT)
        .build()?)
}

// --- target agent ----------------------------------------------------------

async fn validate_by_peer(peer_id: &str) -> ResultType<ValidateResponse> {
    let resp = http()?
        .post(format!("{}/session/validate-by-peer", broker_url()))
        .header("X-Device-Id", device_id())
        .header("X-Device-Token", device_token())
        .json(&serde_json::json!({ "from_peer_id": peer_id, "via": "p2p" }))
        .send()
        .await?
        .error_for_status()?
        .json::<ValidateResponse>()
        .await?;
    Ok(resp)
}

/// Called by the target agent once the password check has passed.
///
/// Returns false to refuse the connection.
pub async fn authorize_inbound(peer_id: &str) -> bool {
    if local_cap_reached() {
        log::warn!(
            "Refusing {peer_id}: {} of {} viewer slots in use",
            local_remote_viewers(),
            viewer_cap()
        );
        return false;
    }

    if !is_enabled() {
        return true;
    }

    match validate_by_peer(peer_id).await {
        Ok(r) if r.allow => {
            log::info!("Broker authorized {peer_id} for {}", r.actor);
            true
        }
        Ok(r) => {
            log::warn!("Broker refused {peer_id}: {}", r.reason);
            false
        }
        Err(e) => {
            // Fail-closed: an unreachable policy engine denies, never waives.
            log::error!("Broker unreachable, refusing {peer_id}: {e}");
            false
        }
    }
}

// --- operator client -------------------------------------------------------

pub fn has_token() -> bool {
    TOKEN.lock().unwrap().is_some()
}

pub fn clear_token() {
    TOKEN.lock().unwrap().take();
}

fn token() -> ResultType<String> {
    match TOKEN.lock().unwrap().clone() {
        Some(t) => Ok(t),
        None => bail!("not signed in to the Mendocino broker"),
    }
}

/// Exchange credentials for a bearer token. The password is not retained.
pub async fn login(username: &str, password: &str, totp: &str) -> ResultType<()> {
    let resp = http()?
        .post(format!("{}/auth/login", broker_url()))
        .json(&serde_json::json!({
            "username": username,
            "password": password,
            "totp": totp,
        }))
        .send()
        .await?;

    if !resp.status().is_success() {
        bail!("sign-in failed");
    }

    let body = resp.json::<TokenResponse>().await?;
    *TOKEN.lock().unwrap() = Some(body.access_token);
    Ok(())
}

/// Exchange a break-glass key for a short-lived superadmin token.
pub async fn breakglass(key: &str, totp: &str) -> ResultType<()> {
    let resp = http()?
        .post(format!("{}/auth/breakglass", broker_url()))
        .json(&serde_json::json!({ "key": key, "totp": totp }))
        .send()
        .await?;

    if !resp.status().is_success() {
        bail!("break-glass key rejected");
    }

    let body = resp.json::<TokenResponse>().await?;
    *TOKEN.lock().unwrap() = Some(body.access_token);
    Ok(())
}

/// Reserve a slot before connecting. `429` means a cap was hit.
pub async fn request_session(target_device_id: &str, kind: &str) -> ResultType<SessionTicket> {
    let resp = http()?
        .post(format!("{}/session/request", broker_url()))
        .bearer_auth(token()?)
        .json(&serde_json::json!({
            "device_id": target_device_id,
            "kind": kind,
            "from_peer_id": Config::get_id(),
        }))
        .send()
        .await?;

    if resp.status() == reqwest::StatusCode::TOO_MANY_REQUESTS {
        let detail = resp
            .json::<serde_json::Value>()
            .await
            .ok()
            .and_then(|v| v.get("detail").and_then(|d| d.as_str()).map(str::to_owned))
            .unwrap_or_else(|| "session limit reached".to_owned());
        bail!("{detail}");
    }

    let ticket = resp.error_for_status()?.json::<SessionTicket>().await?;
    LIVE_SESSIONS
        .lock()
        .unwrap()
        .insert(ticket.device_id.clone(), ticket.session_token.clone());
    Ok(ticket)
}

async fn post_session_token(path: &str, session_token: &str) -> ResultType<()> {
    http()?
        .post(format!("{}{path}", broker_url()))
        .bearer_auth(token()?)
        .json(&serde_json::json!({ "session_token": session_token }))
        .send()
        .await?
        .error_for_status()?;
    Ok(())
}

/// Release the slot. Best-effort: the broker reclaims it on heartbeat timeout anyway.
pub async fn end_session(target_device_id: &str) {
    let session_token = LIVE_SESSIONS.lock().unwrap().remove(target_device_id);
    if let Some(session_token) = session_token {
        if let Err(e) = post_session_token("/session/end", &session_token).await {
            log::warn!("Failed to release broker session: {e}");
        }
    }
}

/// Keep the slot alive until the session ends.
///
/// The broker reclaims a slot after its TTL of heartbeat silence, so a client that dies
/// cannot wedge a user at their session limit.
pub fn start_heartbeat(target_device_id: String) {
    let interval = heartbeat_interval();
    tokio::spawn(async move {
        loop {
            sleep(interval).await;
            let session_token = LIVE_SESSIONS.lock().unwrap().get(&target_device_id).cloned();
            let Some(session_token) = session_token else {
                break;
            };
            if let Err(e) = post_session_token("/session/heartbeat", &session_token).await {
                // 410 means the slot is already gone; stop rather than spin.
                log::warn!("Broker heartbeat stopped for {target_device_id}: {e}");
                LIVE_SESSIONS.lock().unwrap().remove(&target_device_id);
                break;
            }
        }
    });
}
