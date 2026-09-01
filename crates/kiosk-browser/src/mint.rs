// Copyright (c) 2026 Just a Nerd
// SPDX-License-Identifier: BUSL-1.1

//! Minimal framed mint client for `/run/evo/kiosk.sock`.
//!
//! Wire: 4-byte big-endian length + UTF-8 JSON body (same as evo-core
//! Unix socket v0). Request shape:
//!
//! ```json
//! { "op": "mint_local_kiosk_session", "reason": "kiosk-boot" }
//! ```
//!
//! Success response (untagged ClientResponse):
//!
//! ```json
//! {
//!   "local_kiosk_session_minted": true,
//!   "token": "...",
//!   "token_id": "...",
//!   "expires_at_ms": 123
//! }
//! ```
//!
//! Never logs the bearer. Never connects to `/run/evo/evo.sock`.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Deserialize;
use serde_json::json;
use socket2::{Domain, SockAddr, Socket, Type};
use thiserror::Error;

/// Canonical mint socket. Overridable via `EVO_KIOSK_SOCK` for tests.
pub const DEFAULT_KIOSK_SOCK: &str = "/run/evo/kiosk.sock";

/// localStorage / cookie key consumed by the UI shell (`storedBearer`).
pub const BEARER_STORAGE_KEY: &str = "evoBearer";

/// Bounded connect deadline for the mint socket. Stdlib's
/// `UnixStream::connect` has no timeout — a `SIGSTOP`'d steward
/// process or a pathologically-slow accept path would otherwise block
/// the shell indefinitely.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const RW_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MintedSession {
    pub token: String,
    pub token_id: String,
    pub expires_at_ms: u64,
}

#[derive(Debug, Error)]
pub enum MintError {
    #[error("kiosk socket connect failed: {0}")]
    Connect(#[source] std::io::Error),
    #[error("kiosk socket I/O failed: {0}")]
    Io(#[source] std::io::Error),
    #[error("mint response JSON invalid: {0}")]
    Parse(#[source] serde_json::Error),
    #[error("mint refused: {subclass}: {message}")]
    Refused { subclass: String, message: String },
    #[error("mint response missing token fields")]
    Incomplete,
    #[error("frame too large ({len} bytes)")]
    FrameTooLarge { len: usize },
}

#[derive(Debug, Deserialize)]
struct MintOk {
    #[serde(default)]
    local_kiosk_session_minted: bool,
    token: Option<String>,
    token_id: Option<String>,
    expires_at_ms: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct MintErrBody {
    error: MintErrFields,
}

#[derive(Debug, Deserialize)]
struct MintErrFields {
    #[serde(default)]
    message: String,
    #[serde(default)]
    subclass: Option<String>,
    #[serde(default)]
    details: Option<serde_json::Value>,
}

/// Resolve socket path: `$EVO_KIOSK_SOCK` or [`DEFAULT_KIOSK_SOCK`].
pub fn kiosk_sock_path() -> PathBuf {
    std::env::var_os("EVO_KIOSK_SOCK")
        .map(PathBuf::from)
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| PathBuf::from(DEFAULT_KIOSK_SOCK))
}

/// Mint once against `socket_path` with the given audit `reason`.
pub fn mint_once(socket_path: &Path, reason: &str) -> Result<MintedSession, MintError> {
    let reason = reason.trim();
    if reason.is_empty() {
        return Err(MintError::Refused {
            subclass: "blank_reason".to_string(),
            message: "mint reason must be non-empty".to_string(),
        });
    }

    // Bounded connect. socket2's `connect_timeout` sets a temporary
    // non-blocking mode, calls `connect(2)`, polls for the deadline,
    // then restores blocking mode. Failure classifies the same way as
    // stdlib's connect (`ETIMEDOUT`, `ECONNREFUSED`, `ENOENT`, …).
    let addr = SockAddr::unix(socket_path).map_err(MintError::Connect)?;
    let sock = Socket::new(Domain::UNIX, Type::STREAM, None).map_err(MintError::Connect)?;
    sock.connect_timeout(&addr, CONNECT_TIMEOUT)
        .map_err(MintError::Connect)?;
    let mut stream: UnixStream = sock.into();
    stream
        .set_read_timeout(Some(RW_TIMEOUT))
        .map_err(MintError::Io)?;
    stream
        .set_write_timeout(Some(RW_TIMEOUT))
        .map_err(MintError::Io)?;

    let body = serde_json::to_vec(&json!({
        "op": "mint_local_kiosk_session",
        "reason": reason,
    }))
    .expect("mint request serialises");

    write_frame(&mut stream, &body)?;
    let resp = read_frame(&mut stream)?;
    parse_mint_response(&resp)
}

/// Retry mint until success or `attempts` exhausted. Exponential backoff
/// starting at `initial_backoff` (capped at 2 s).
pub fn mint_with_retry(
    socket_path: &Path,
    reason: &str,
    attempts: u32,
    initial_backoff: Duration,
) -> Result<MintedSession, MintError> {
    let attempts = attempts.max(1);
    let mut backoff = initial_backoff;
    let mut last = MintError::Incomplete;
    for i in 0..attempts {
        match mint_once(socket_path, reason) {
            Ok(ok) => return Ok(ok),
            Err(e) => {
                last = e;
                if i + 1 == attempts {
                    break;
                }
                std::thread::sleep(backoff);
                backoff = (backoff * 2).min(Duration::from_secs(2));
            }
        }
    }
    Err(last)
}

/// Wall-clock ms when the shell should remint (5 minutes before expiry,
/// or halfway through the remaining TTL when TTL is shorter than 10 min).
pub fn renew_at_ms(expires_at_ms: u64, now_ms: u64) -> u64 {
    if expires_at_ms <= now_ms {
        return now_ms;
    }
    let remaining = expires_at_ms - now_ms;
    let lead = (5 * 60 * 1000).min(remaining / 2);
    expires_at_ms.saturating_sub(lead)
}

fn write_frame(stream: &mut UnixStream, body: &[u8]) -> Result<(), MintError> {
    if body.len() > u32::MAX as usize {
        return Err(MintError::FrameTooLarge { len: body.len() });
    }
    let len = (body.len() as u32).to_be_bytes();
    stream.write_all(&len).map_err(MintError::Io)?;
    stream.write_all(body).map_err(MintError::Io)?;
    stream.flush().map_err(MintError::Io)?;
    Ok(())
}

fn read_frame(stream: &mut UnixStream) -> Result<Vec<u8>, MintError> {
    let mut len_buf = [0u8; 4];
    stream.read_exact(&mut len_buf).map_err(MintError::Io)?;
    let len = u32::from_be_bytes(len_buf) as usize;
    if len == 0 {
        return Err(MintError::Incomplete);
    }
    // Match steward MAX_FRAME_SIZE order of magnitude; kiosk mint
    // responses are tiny. Cap at 1 MiB to avoid unbounded alloc.
    const MAX: usize = 1 << 20;
    if len > MAX {
        return Err(MintError::FrameTooLarge { len });
    }
    let mut body = vec![0u8; len];
    stream.read_exact(&mut body).map_err(MintError::Io)?;
    Ok(body)
}

pub(crate) fn parse_mint_response(body: &[u8]) -> Result<MintedSession, MintError> {
    // Prefer error shape when present (untagged ClientResponse::Error).
    if let Ok(err) = serde_json::from_slice::<MintErrBody>(body) {
        let has_error_fields = !err.error.message.is_empty()
            || err.error.subclass.is_some()
            || err.error.details.is_some();
        if has_error_fields {
            let subclass = err
                .error
                .subclass
                .or_else(|| {
                    err.error
                        .details
                        .as_ref()
                        .and_then(|d| d.get("subclass"))
                        .and_then(|v| v.as_str())
                        .map(str::to_string)
                })
                .unwrap_or_else(|| "error".to_string());
            return Err(MintError::Refused {
                subclass,
                message: err.error.message,
            });
        }
    }

    let ok: MintOk = serde_json::from_slice(body).map_err(MintError::Parse)?;
    if !ok.local_kiosk_session_minted {
        return Err(MintError::Incomplete);
    }
    match (ok.token, ok.token_id, ok.expires_at_ms) {
        (Some(token), Some(token_id), Some(expires_at_ms))
            if !token.is_empty() && !token_id.is_empty() =>
        {
            Ok(MintedSession {
                token,
                token_id,
                expires_at_ms,
            })
        }
        _ => Err(MintError::Incomplete),
    }
}

/// Escape a bearer for embedding in a JS string literal (single-quoted).
///
/// Also escapes `</` as `<\/` so a token containing the literal
/// substring `</script` cannot break out of the surrounding
/// `<script>` block when the injected snippet is rendered inline.
/// Tokens today are minted by evo-core (controlled input) but the
/// defensive escape hardens against future token-shape changes.
pub fn js_string_literal(token: &str) -> String {
    let mut out = String::with_capacity(token.len() + 8);
    let mut prev = '\0';
    for ch in token.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '\'' => out.push_str("\\'"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\u{2028}' => out.push_str("\\u2028"),
            '\u{2029}' => out.push_str("\\u2029"),
            '/' if prev == '<' => out.push_str("\\/"),
            c => out.push(c),
        }
        prev = ch;
    }
    out
}

/// JS snippet that writes the bearer into localStorage under
/// [`BEARER_STORAGE_KEY`]. Does not echo the token to console.
pub fn local_storage_inject_script(token: &str) -> String {
    format!(
        "(function(){{try{{localStorage.setItem('{key}','{tok}');}}catch(_e){{}}}})();",
        key = BEARER_STORAGE_KEY,
        tok = js_string_literal(token),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::os::unix::net::UnixListener;
    use std::thread;

    #[test]
    fn mint_success_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let sock = dir.path().join("kiosk.sock");
        let resp = br#"{"local_kiosk_session_minted":true,"token":"abc.TOK-1","token_id":"tid1","expires_at_ms":999}"#;
        let listener = UnixListener::bind(&sock).unwrap();
        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut len_buf = [0u8; 4];
            stream.read_exact(&mut len_buf).unwrap();
            let n = u32::from_be_bytes(len_buf) as usize;
            let mut req = vec![0u8; n];
            stream.read_exact(&mut req).unwrap();
            assert!(String::from_utf8_lossy(&req).contains("mint_local_kiosk_session"));
            assert!(String::from_utf8_lossy(&req).contains("kiosk-boot"));
            let len = (resp.len() as u32).to_be_bytes();
            stream.write_all(&len).unwrap();
            stream.write_all(resp).unwrap();
        });
        let minted = mint_once(&sock, "kiosk-boot").expect("mint");
        assert_eq!(minted.token, "abc.TOK-1");
        assert_eq!(minted.token_id, "tid1");
        assert_eq!(minted.expires_at_ms, 999);
        handle.join().unwrap();
    }

    #[test]
    fn mint_refused_surfaces_subclass() {
        let dir = tempfile::tempdir().unwrap();
        let sock = dir.path().join("kiosk.sock");
        let resp = br#"{"error":{"class":"permission_denied","message":"peer not admitted","subclass":"peer_not_admitted"}}"#;
        let listener = UnixListener::bind(&sock).unwrap();
        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut len_buf = [0u8; 4];
            stream.read_exact(&mut len_buf).unwrap();
            let n = u32::from_be_bytes(len_buf) as usize;
            let mut req = vec![0u8; n];
            stream.read_exact(&mut req).unwrap();
            let len = (resp.len() as u32).to_be_bytes();
            stream.write_all(&len).unwrap();
            stream.write_all(resp).unwrap();
        });
        let err = mint_once(&sock, "kiosk-boot").unwrap_err();
        match err {
            MintError::Refused { subclass, .. } => {
                assert_eq!(subclass, "peer_not_admitted");
            }
            other => panic!("unexpected {other:?}"),
        }
        handle.join().unwrap();
    }

    #[test]
    fn renew_at_ms_leads_expiry() {
        let now = 1_000_000u64;
        let exp = now + 24 * 60 * 60 * 1000;
        let renew = renew_at_ms(exp, now);
        assert_eq!(renew, exp - 5 * 60 * 1000);
    }

    #[test]
    fn js_escape_quotes() {
        assert_eq!(js_string_literal("a'b\\c"), "a\\'b\\\\c");
        let script = local_storage_inject_script("tok'en");
        assert!(script.contains("localStorage.setItem('evoBearer','tok\\'en')"));
    }

    #[test]
    fn parse_mint_ok_unit() {
        let body =
            br#"{"local_kiosk_session_minted":true,"token":"t","token_id":"i","expires_at_ms":1}"#;
        let ok = parse_mint_response(body).unwrap();
        assert_eq!(ok.token, "t");
    }

    #[test]
    fn parse_mint_response_incomplete_when_flag_true_but_fields_empty() {
        // `minted: true` but empty token / token_id / expires_at_ms
        // must not surface as success (`Incomplete` is the honest
        // classification — the server did not deliver a session).
        let body =
            br#"{"local_kiosk_session_minted":true,"token":"","token_id":"","expires_at_ms":1}"#;
        let err = parse_mint_response(body).unwrap_err();
        matches!(err, MintError::Incomplete);
    }

    #[test]
    fn parse_mint_response_incomplete_when_flag_false() {
        let body =
            br#"{"local_kiosk_session_minted":false,"token":"t","token_id":"i","expires_at_ms":1}"#;
        matches!(
            parse_mint_response(body).unwrap_err(),
            MintError::Incomplete
        );
    }

    #[test]
    fn js_escape_closes_script_tag() {
        // Token containing the literal `</script` must escape the
        // `/` so the inline `<script>` tag around
        // `local_storage_inject_script`'s emission cannot terminate
        // early on token content.
        let escaped = js_string_literal("abc</script>def");
        assert!(!escaped.contains("</script>"));
        assert!(escaped.contains("<\\/script>"));
        // Loose `/` outside of `</` is untouched.
        assert_eq!(js_string_literal("a/b"), "a/b");
    }

    #[test]
    fn renew_at_ms_clamps_when_ttl_shorter_than_10min() {
        // TTL 60 s -> lead = min(5min, 60/2) = 30 s -> renew at exp-30s.
        let now = 1_000_000u64;
        let exp = now + 60_000;
        assert_eq!(renew_at_ms(exp, now), exp - 30_000);
    }

    #[test]
    fn renew_at_ms_returns_now_when_already_expired() {
        assert_eq!(renew_at_ms(500, 1_000), 1_000);
    }

    #[test]
    fn mint_with_retry_exhausts_and_returns_last_error() {
        // Point at a socket that never appears.
        let dir = tempfile::tempdir().unwrap();
        let sock = dir.path().join("nope.sock");
        let start = std::time::Instant::now();
        let err = mint_with_retry(&sock, "kiosk-boot", 3, Duration::from_millis(1)).unwrap_err();
        // Every attempt fails at connect with ENOENT-class error;
        // last-error survives the retry loop.
        matches!(err, MintError::Connect(_));
        // Sanity bound so the retry loop cannot silently blow past
        // (attempts * initial_backoff * 2) + connect-timeout window.
        assert!(start.elapsed() < Duration::from_secs(15));
    }

    #[test]
    fn frame_too_large_refused_on_read() {
        // Server sends a length header past MAX; read must refuse
        // rather than allocate.
        let dir = tempfile::tempdir().unwrap();
        let sock = dir.path().join("frame.sock");
        let listener = UnixListener::bind(&sock).unwrap();
        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            // Drain request.
            let mut len_buf = [0u8; 4];
            stream.read_exact(&mut len_buf).unwrap();
            let n = u32::from_be_bytes(len_buf) as usize;
            let mut req = vec![0u8; n];
            stream.read_exact(&mut req).unwrap();
            // Reply with a 2 MiB length header (over the 1 MiB cap).
            let bogus: u32 = 2 * 1024 * 1024;
            stream.write_all(&bogus.to_be_bytes()).unwrap();
        });
        let err = mint_once(&sock, "kiosk-boot").unwrap_err();
        matches!(err, MintError::FrameTooLarge { .. });
        handle.join().unwrap();
    }

    #[test]
    fn connect_refuses_missing_socket_fast() {
        // Socket path does not exist; connect must return ENOENT-class
        // fast, well before the 5 s connect timeout.
        let dir = tempfile::tempdir().unwrap();
        let sock = dir.path().join("nope.sock");
        let start = std::time::Instant::now();
        let err = mint_once(&sock, "kiosk-boot").unwrap_err();
        matches!(err, MintError::Connect(_));
        assert!(start.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn kiosk_sock_path_honours_env_override() {
        let key = "EVO_KIOSK_SOCK";
        // Save + restore so parallel tests do not interfere.
        let prior = std::env::var_os(key);
        std::env::set_var(key, "/tmp/x.sock");
        assert_eq!(kiosk_sock_path().to_string_lossy(), "/tmp/x.sock");
        std::env::set_var(key, "");
        assert_eq!(kiosk_sock_path().to_string_lossy(), DEFAULT_KIOSK_SOCK);
        match prior {
            Some(v) => std::env::set_var(key, v),
            None => std::env::remove_var(key),
        }
    }
}
