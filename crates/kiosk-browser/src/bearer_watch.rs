// Copyright (c) 2026 Just a Nerd
// SPDX-License-Identifier: BUSL-1.1

//! The panel's bearer, and whether the steward still honours it.
//!
//! The panel mints a session on `/run/evo/kiosk.sock` and writes the
//! bearer into the page's `localStorage` at the start of every load.
//! Nothing told it when the steward stopped honouring that bearer (a
//! credential reset, a key rotation, a revoke), so it went on writing
//! the dead one on every load until the unit restarted or the token's
//! own expiry came round. The page, for its part, drops a bearer once
//! it proves the device is reachable and the bearer is refused, which
//! left a panel painted unpaired with no way back.
//!
//! The steward answers the same WebSocket upgrade the page makes: 101
//! for a bearer it honours, 401 for one it refuses, 101 again with no
//! bearer at all. So the panel asks the steward itself, with the
//! bearer it holds, and reads the answer. A refused bearer is dropped
//! at once and never written again; the panel mints a fresh one on the
//! local socket.
//!
//! Pure Rust over the standard library, so host CI tests it without
//! GTK. Never logs or echoes the bearer.

use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::Mutex;
use std::time::Duration;

use crate::mint::{local_storage_inject_script, MintedSession};

/// How the steward answered a bearer on the WebSocket upgrade.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BearerState {
    /// 101 Switching Protocols: the steward honours the bearer.
    Accepted,
    /// 401 or 403: the steward refuses it. The token itself is dead.
    Refused,
    /// No answer that says either way: the steward is down or
    /// restarting, the connection failed, or the reply was not an
    /// HTTP status line. Never a reason to drop a bearer, or the
    /// panel would mint on every outage.
    Unknown,
}

/// What the panel does next.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WatchAction {
    /// Nothing to do.
    Keep,
    /// Mint a fresh session on the local socket and load it.
    Remint,
}

/// Read a bearer's state from the HTTP status line of the upgrade
/// reply.
pub fn classify_status_line(line: &str) -> BearerState {
    let mut parts = line.split_whitespace();
    let Some(version) = parts.next() else {
        return BearerState::Unknown;
    };
    if !version.starts_with("HTTP/1.") {
        return BearerState::Unknown;
    }
    match parts.next() {
        Some("101") => BearerState::Accepted,
        Some("401") | Some("403") => BearerState::Refused,
        _ => BearerState::Unknown,
    }
}

/// Deadline for the connect and for each read or write. The steward
/// is on loopback, so a longer wait is an outage, not latency.
const PROBE_TIMEOUT: Duration = Duration::from_secs(2);

/// The characters a WebSocket subprotocol token may carry (RFC 6455).
/// A minted bearer always passes; anything else is never sent.
fn subprotocol_safe(token: &str) -> bool {
    !token.is_empty()
        && token
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&b))
}

/// The upgrade request, with the bearer in the `evo.bearer.<token>`
/// subprotocol the page uses.
fn upgrade_request(host: &str, token: &str) -> String {
    format!(
        "GET /api/v1/ws HTTP/1.1\r\n\
         Host: {host}\r\n\
         Upgrade: websocket\r\n\
         Connection: Upgrade\r\n\
         Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\
         Sec-WebSocket-Version: 13\r\n\
         Sec-WebSocket-Protocol: evo.bearer.{token}\r\n\
         \r\n"
    )
}

/// Ask the steward whether it honours `token`. Blocking, bounded by a
/// two-second deadline on the connect and on each read and write; run
/// it off the UI thread.
pub fn probe_bearer(host: &str, port: u16, token: &str) -> BearerState {
    if !subprotocol_safe(token) {
        return BearerState::Unknown;
    }
    let Some(addr) = (host, port)
        .to_socket_addrs()
        .ok()
        .and_then(|mut a| a.next())
    else {
        return BearerState::Unknown;
    };
    let Ok(mut stream) = TcpStream::connect_timeout(&addr, PROBE_TIMEOUT) else {
        return BearerState::Unknown;
    };
    if stream.set_read_timeout(Some(PROBE_TIMEOUT)).is_err()
        || stream.set_write_timeout(Some(PROBE_TIMEOUT)).is_err()
        || stream
            .write_all(upgrade_request(host, token).as_bytes())
            .is_err()
    {
        return BearerState::Unknown;
    }
    // The status line is all that is read; the socket is dropped
    // straight after, so no WebSocket session is held open.
    let mut head = [0u8; 128];
    let mut got = 0;
    while got < head.len() {
        match stream.read(&mut head[got..]) {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                got += n;
                if head[..got].contains(&b'\n') {
                    break;
                }
            }
        }
    }
    let text = String::from_utf8_lossy(&head[..got]);
    classify_status_line(text.lines().next().unwrap_or(""))
}

/// The bearer the panel presents, and nothing else.
///
/// Whatever is written into a page comes from [`Self::script`], so a
/// bearer the steward has refused cannot be written again: it is gone
/// from here the moment it is refused, before any new one is minted.
#[derive(Debug, Default)]
pub struct KioskBearer {
    session: Option<(String, String)>,
}

impl KioskBearer {
    pub const fn new() -> Self {
        Self { session: None }
    }

    /// Hold a freshly minted session. It replaces whatever was held.
    pub fn install(&mut self, session: &MintedSession) {
        self.session = Some((session.token.clone(), session.token_id.clone()));
    }

    /// The token to put to the steward, if one is held.
    pub fn token(&self) -> Option<&str> {
        self.session.as_ref().map(|(t, _)| t.as_str())
    }

    /// The token's id, safe to log.
    pub fn token_id(&self) -> Option<&str> {
        self.session.as_ref().map(|(_, id)| id.as_str())
    }

    /// The script that writes the held bearer into a page, or none
    /// when no bearer is held.
    pub fn script(&self) -> Option<String> {
        self.token().map(local_storage_inject_script)
    }

    /// What to do with the steward's answer. A refusal drops the
    /// bearer on the spot; holding none means a mint is owed.
    pub fn on_probe(&mut self, state: BearerState) -> WatchAction {
        if state == BearerState::Refused {
            self.session = None;
        }
        if self.session.is_none() {
            WatchAction::Remint
        } else {
            WatchAction::Keep
        }
    }
}

/// The one bearer this process presents. The UI thread installs it;
/// the probe thread is handed a copy of the token and never reads it.
pub static BEARER: Mutex<KioskBearer> = Mutex::new(KioskBearer::new());

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::thread;

    fn session(token: &str, id: &str) -> MintedSession {
        MintedSession {
            token: token.to_string(),
            token_id: id.to_string(),
            expires_at_ms: 1,
        }
    }

    /// One-shot server that reads the request and answers `reply`.
    fn serve(reply: &'static [u8]) -> (u16, thread::JoinHandle<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let handle = thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let mut buf = [0u8; 1024];
            let n = s.read(&mut buf).unwrap();
            let _ = s.write_all(reply);
            String::from_utf8_lossy(&buf[..n]).to_string()
        });
        (port, handle)
    }

    #[test]
    fn the_status_line_says_which_bearer_state() {
        assert_eq!(
            classify_status_line("HTTP/1.1 101 Switching Protocols"),
            BearerState::Accepted
        );
        assert_eq!(
            classify_status_line("HTTP/1.1 401 Unauthorized"),
            BearerState::Refused
        );
        assert_eq!(
            classify_status_line("HTTP/1.1 403 Forbidden"),
            BearerState::Refused
        );
        // Anything else is silence, not a verdict on the bearer.
        for line in [
            "",
            "garbage",
            "HTTP/1.1 502 Bad Gateway",
            "HTTP/1.1 503 Service Unavailable",
            "HTTP/1.1 200 OK",
            "SSH-2.0-OpenSSH",
        ] {
            assert_eq!(classify_status_line(line), BearerState::Unknown, "{line:?}");
        }
    }

    #[test]
    fn the_probe_sends_the_bearer_as_the_page_does_and_reads_a_refusal() {
        let (port, server) = serve(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n");
        let state = probe_bearer("127.0.0.1", port, "tok-1.abc_DEF");
        assert_eq!(state, BearerState::Refused);
        let req = server.join().unwrap();
        assert!(req.starts_with("GET /api/v1/ws HTTP/1.1\r\n"), "{req}");
        assert!(
            req.contains("Sec-WebSocket-Protocol: evo.bearer.tok-1.abc_DEF\r\n"),
            "{req}"
        );
        assert!(req.contains("Upgrade: websocket\r\n"), "{req}");
    }

    #[test]
    fn the_probe_reads_an_accepted_bearer() {
        let (port, server) =
            serve(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n");
        assert_eq!(
            probe_bearer("127.0.0.1", port, "tok"),
            BearerState::Accepted
        );
        server.join().unwrap();
    }

    #[test]
    fn an_outage_is_unknown_and_never_a_refusal() {
        // Nothing listening: the steward is down or restarting.
        let port = {
            let l = TcpListener::bind("127.0.0.1:0").unwrap();
            l.local_addr().unwrap().port()
        };
        assert_eq!(probe_bearer("127.0.0.1", port, "tok"), BearerState::Unknown);
        // A server that hangs up without a word.
        let (port, server) = serve(b"");
        assert_eq!(probe_bearer("127.0.0.1", port, "tok"), BearerState::Unknown);
        server.join().unwrap();
    }

    #[test]
    fn a_token_that_is_not_a_subprotocol_is_never_sent() {
        // It would be a malformed header, and a malformed header is
        // not an answer about the bearer.
        for bad in ["", "a b", "a\r\nX: y", "tok;x", "tok,x"] {
            assert_eq!(
                probe_bearer("127.0.0.1", 9, bad),
                BearerState::Unknown,
                "{bad:?}"
            );
        }
    }

    #[test]
    fn a_refused_bearer_is_never_written_again() {
        // The pin. The dead bearer must be out of reach the moment it
        // is refused, before a replacement exists, so no page load
        // can be handed it while a mint is pending or failing.
        let mut held = KioskBearer::new();
        held.install(&session("DEAD.TOKEN", "id-dead"));
        assert!(held.script().unwrap().contains("DEAD.TOKEN"));

        assert_eq!(held.on_probe(BearerState::Refused), WatchAction::Remint);
        assert!(held.script().is_none(), "no script while no bearer is held");
        assert!(held.token().is_none());
        // Still owed, however many ticks pass before the mint lands.
        assert_eq!(held.on_probe(BearerState::Unknown), WatchAction::Remint);
        assert_eq!(held.on_probe(BearerState::Refused), WatchAction::Remint);
        assert!(held.script().is_none());

        held.install(&session("FRESH.TOKEN", "id-fresh"));
        let script = held.script().unwrap();
        assert!(script.contains("FRESH.TOKEN"), "{script}");
        assert!(!script.contains("DEAD.TOKEN"), "{script}");
        assert_eq!(held.token_id(), Some("id-fresh"));
        assert_eq!(held.on_probe(BearerState::Accepted), WatchAction::Keep);
    }

    #[test]
    fn an_outage_or_an_accepted_bearer_keeps_what_is_held() {
        let mut held = KioskBearer::new();
        held.install(&session("TOK", "id"));
        assert_eq!(held.on_probe(BearerState::Unknown), WatchAction::Keep);
        assert_eq!(held.on_probe(BearerState::Accepted), WatchAction::Keep);
        assert_eq!(held.token(), Some("TOK"));
    }

    #[test]
    fn holding_nothing_owes_a_mint() {
        let mut held = KioskBearer::new();
        assert_eq!(held.on_probe(BearerState::Accepted), WatchAction::Remint);
        assert_eq!(held.on_probe(BearerState::Unknown), WatchAction::Remint);
    }
}
