//! Mendocino Remote Connectivity — update channel.
//!
//! Upstream checks `https://api.rustdesk.com/version/latest`, which would report our fleet
//! to a third party and offer us RustDesk's builds. This module points the same machinery
//! at our own GitHub Releases instead.
//!
//! Nothing downstream changes. `updater.rs` takes whatever URL lands in
//! `SOFTWARE_UPDATE_URL`, rewrites `/tag/` to `/download/` and appends the asset name —
//! which is exactly how GitHub Releases is laid out:
//!
//!     https://github.com/<repo>/releases/tag/1.1.0       <- what we publish here
//!     https://github.com/<repo>/releases/download/1.1.0/<asset>
//!
//! `updater.rs` already refuses any download URL that is not on github.com, so the
//! transport stays as restricted as upstream intended.
//!
//! The repo is read from the signed custom.txt (`mrc-update-repo`), so a fleet can be
//! repointed without a rebuild — and because that file is signature-checked, an attacker
//! who can write next to the binary still cannot aim updates at their own repository.

use hbb_common::{bail, config::HARD_SETTINGS, log, ResultType};
use serde_derive::Deserialize;
use std::time::Duration;

/// Overridable via the signed config; this is the fleet default.
pub const DEFAULT_REPO: &str = "manujautomation/remotesession";

/// Release assets are named `<ASSET_PREFIX>-<version>-<arch>.<ext>`, matching what
/// packaging/make-deb.sh and the Windows CI job produce.
pub const ASSET_PREFIX: &str = "mendocino-apcela-remote";

const TIMEOUT: Duration = Duration::from_secs(15);

fn hard(key: &str) -> String {
    HARD_SETTINGS
        .read()
        .unwrap()
        .get(key)
        .cloned()
        .unwrap_or_default()
}

pub fn repo() -> String {
    let configured = hard("mrc-update-repo");
    if configured.is_empty() {
        DEFAULT_REPO.to_owned()
    } else {
        configured
    }
}

/// False disables our channel and lets the upstream check run, which is only useful when
/// building an unbranded client.
pub fn is_enabled() -> bool {
    hard("mrc-disable-update-check") != "Y"
}

/// Release asset filename for this platform: `<prefix>-<version>-<arch>.<ext>`.
///
/// Upstream only ever builds this for Windows and macOS, so on Linux the download URL was
/// left pointing at the release *directory* rather than a file.
pub fn asset_name(version: &str) -> String {
    let arch = if cfg!(target_arch = "aarch64") {
        "aarch64"
    } else {
        "x86_64"
    };
    let ext = if cfg!(target_os = "windows") {
        "exe"
    } else if cfg!(target_os = "macos") {
        "dmg"
    } else {
        "deb"
    };
    format!("{ASSET_PREFIX}-{version}-{arch}.{ext}")
}

/// Install a downloaded .deb.
///
/// The updater may run either in the root service or in the user session. As root we can
/// call apt directly; otherwise pkexec raises the usual desktop authentication prompt.
/// A remote-access tool silently self-elevating with no prompt would be worse.
#[cfg(target_os = "linux")]
pub fn install_deb(file_path: &std::path::Path) -> ResultType<()> {
    use std::process::Command;

    let path = file_path.to_string_lossy().to_string();
    let is_root = unsafe { hbb_common::libc::geteuid() } == 0;

    // apt resolves dependencies; dpkg -i would fail on a new one.
    let output = if is_root {
        Command::new("apt-get")
            .args(["install", "-y", "--allow-downgrades", &path])
            .output()?
    } else {
        Command::new("pkexec")
            .args(["apt-get", "install", "-y", "--allow-downgrades", &path])
            .output()?
    };

    if output.status.success() {
        log::info!("Update installed from {path}");
        Ok(())
    } else {
        // Not fatal: the user can still install it by hand, and the file is already local.
        bail!(
            "apt-get failed ({}): {}",
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        )
    }
}

#[derive(Deserialize)]
struct GithubRelease {
    #[serde(default)]
    tag_name: String,
    #[serde(default)]
    draft: bool,
    #[serde(default)]
    prerelease: bool,
}

/// Query our releases and publish the result through the same global the updater reads.
///
/// Mirrors the contract of upstream's `do_check_software_update`: set the URL when a newer
/// version exists, clear it otherwise. The last path segment must be the version, because
/// that is how `updater.rs` derives it.
pub async fn check_github_release() -> ResultType<()> {
    let repo = repo();
    let api = format!("https://api.github.com/repos/{repo}/releases/latest");

    let client = reqwest::Client::builder().timeout(TIMEOUT).build()?;
    let resp = client
        .get(&api)
        // GitHub rejects requests without one.
        .header("User-Agent", ASSET_PREFIX)
        .header("Accept", "application/vnd.github+json")
        .send()
        .await?;

    if resp.status() == reqwest::StatusCode::NOT_FOUND {
        // No releases published yet. Not an error: a fresh fleet has nothing to update to.
        *crate::common::SOFTWARE_UPDATE_URL.lock().unwrap() = "".to_owned();
        return Ok(());
    }
    if !resp.status().is_success() {
        bail!("update check failed: HTTP {}", resp.status());
    }

    let release: GithubRelease = resp.json().await?;
    if release.draft || release.prerelease || release.tag_name.is_empty() {
        *crate::common::SOFTWARE_UPDATE_URL.lock().unwrap() = "".to_owned();
        return Ok(());
    }

    // Tags may be written as "v1.1.0"; the version comparison wants bare digits.
    let latest = release.tag_name.trim_start_matches('v').to_owned();
    let url = format!("https://github.com/{repo}/releases/tag/{}", release.tag_name);

    if hbb_common::get_version_number(&latest) > hbb_common::get_version_number(crate::VERSION) {
        log::info!("Update available: {} -> {}", crate::VERSION, latest);
        #[cfg(feature = "flutter")]
        {
            let mut m = std::collections::HashMap::new();
            m.insert("name", "check_software_update_finish");
            m.insert("url", &url);
            if let Ok(data) = serde_json::to_string(&m) {
                let _ = crate::flutter::push_global_event(crate::flutter::APP_TYPE_MAIN, data);
            }
        }
        *crate::common::SOFTWARE_UPDATE_URL.lock().unwrap() = url;
    } else {
        *crate::common::SOFTWARE_UPDATE_URL.lock().unwrap() = "".to_owned();
    }
    Ok(())
}
