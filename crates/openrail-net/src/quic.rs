//! QUIC transport (quinn + rustls) for the lockstep state machines.
//!
//! One bidirectional stream per connection, opened by the client, carries
//! length-prefixed postcard frames both ways.
//!
//! # Trust model
//!
//! A selfhosted server has no CA-signed certificate, so it creates a
//! self-signed one on first start and keeps it on disk. Clients trust the
//! server in one of two ways:
//!
//! - [`ServerVerification::Pinned`]: the client knows the SHA-256
//!   fingerprint of the server certificate (the server logs it and shows it
//!   in `/status`; share it together with the address). Anyone in the
//!   middle without the server's private key is rejected. This is the
//!   default for real play.
//! - [`ServerVerification::InsecureAcceptAny`]: accepts any certificate.
//!   Traffic is still encrypted, but an active attacker on the path can
//!   impersonate the server and read or change everything, including the
//!   server password. Only for development and LAN testing.

use std::{
    collections::HashMap,
    future::Future,
    net::SocketAddr,
    path::Path,
    sync::{Arc, Mutex},
    time::Duration,
};

use quinn::{
    crypto::rustls::{QuicClientConfig, QuicServerConfig},
    Connection, Endpoint, RecvStream, SendStream,
};
use rustls::{
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    crypto::CryptoProvider,
    pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName, UnixTime},
    DigitallySignedStruct, SignatureScheme,
};
use tokio::sync::mpsc;
use tracing::{debug, info, warn};

use crate::{
    client::{ClientEvent, ClientState, LockstepClient},
    codec::{decode, encode, read_frame, write_frame, MAX_CLIENT_FRAME, MAX_SERVER_FRAME},
    host::{ConnId, HostOutput, LockstepHost},
    protocol::{ClientMsg, ServerMsg, ALPN},
};

/// Name the certificate is issued for and clients connect with. With a
/// pinned fingerprint the name does not matter for security.
pub const SERVER_NAME: &str = "openrail";

#[derive(Debug)]
pub struct NetError(pub String);

impl std::fmt::Display for NetError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for NetError {}

fn provider() -> Arc<CryptoProvider> {
    Arc::new(rustls::crypto::ring::default_provider())
}

/// SHA-256 of a DER certificate.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct Fingerprint(pub [u8; 32]);

impl Fingerprint {
    pub fn of(cert_der: &[u8]) -> Self {
        let d = ring::digest::digest(&ring::digest::SHA256, cert_der);
        Fingerprint(d.as_ref().try_into().expect("SHA-256 is 32 bytes"))
    }
}

impl std::fmt::Display for Fingerprint {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        for b in self.0 {
            write!(f, "{b:02x}")?;
        }
        Ok(())
    }
}

impl std::fmt::Debug for Fingerprint {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Fingerprint({self})")
    }
}

impl std::str::FromStr for Fingerprint {
    type Err = NetError;

    /// Accepts 64 hex digits, optionally separated by `:`.
    fn from_str(s: &str) -> Result<Self, NetError> {
        let hex: Vec<u8> = s.bytes().filter(|b| *b != b':').collect();
        let bad = || NetError(format!("invalid fingerprint {s:?}: expected 64 hex digits"));
        if hex.len() != 64 {
            return Err(bad());
        }
        let mut out = [0u8; 32];
        for (i, pair) in hex.chunks(2).enumerate() {
            let pair = std::str::from_utf8(pair).map_err(|_| bad())?;
            out[i] = u8::from_str_radix(pair, 16).map_err(|_| bad())?;
        }
        Ok(Fingerprint(out))
    }
}

/// The server's certificate and private key.
pub struct ServerIdentity {
    pub cert: CertificateDer<'static>,
    key: PrivatePkcs8KeyDer<'static>,
}

impl ServerIdentity {
    /// A fresh self-signed certificate.
    pub fn generate() -> Result<Self, NetError> {
        let ck = rcgen::generate_simple_self_signed(vec![
            SERVER_NAME.to_string(),
            "localhost".to_string(),
        ])
        .map_err(|e| NetError(format!("generating certificate: {e}")))?;
        Ok(ServerIdentity {
            cert: ck.cert.der().clone(),
            key: PrivatePkcs8KeyDer::from(ck.signing_key.serialize_der()),
        })
    }

    /// Loads the DER certificate and PKCS#8 key from disk, creating them
    /// first if either is missing, so the fingerprint survives restarts.
    pub fn load_or_generate(cert_path: &Path, key_path: &Path) -> Result<Self, NetError> {
        if cert_path.exists() && key_path.exists() {
            let cert = std::fs::read(cert_path)
                .map_err(|e| NetError(format!("reading {}: {e}", cert_path.display())))?;
            let key = std::fs::read(key_path)
                .map_err(|e| NetError(format!("reading {}: {e}", key_path.display())))?;
            return Ok(ServerIdentity {
                cert: CertificateDer::from(cert),
                key: PrivatePkcs8KeyDer::from(key),
            });
        }
        let id = Self::generate()?;
        std::fs::write(cert_path, id.cert.as_ref())
            .map_err(|e| NetError(format!("writing {}: {e}", cert_path.display())))?;
        std::fs::write(key_path, id.key.secret_pkcs8_der())
            .map_err(|e| NetError(format!("writing {}: {e}", key_path.display())))?;
        info!("generated new server certificate {}", cert_path.display());
        Ok(id)
    }

    pub fn fingerprint(&self) -> Fingerprint {
        Fingerprint::of(&self.cert)
    }

    fn server_config(&self) -> Result<quinn::ServerConfig, NetError> {
        let mut tls = rustls::ServerConfig::builder_with_provider(provider())
            .with_protocol_versions(&[&rustls::version::TLS13])
            .map_err(|e| NetError(e.to_string()))?
            .with_no_client_auth()
            .with_single_cert(
                vec![self.cert.clone()],
                PrivateKeyDer::Pkcs8(self.key.clone_key()),
            )
            .map_err(|e| NetError(format!("server certificate: {e}")))?;
        tls.alpn_protocols = vec![ALPN.to_vec()];
        let crypto = QuicServerConfig::try_from(tls).map_err(|e| NetError(e.to_string()))?;
        let mut cfg = quinn::ServerConfig::with_crypto(Arc::new(crypto));
        cfg.transport_config(transport_config());
        Ok(cfg)
    }
}

fn transport_config() -> Arc<quinn::TransportConfig> {
    let mut t = quinn::TransportConfig::default();
    t.keep_alive_interval(Some(Duration::from_secs(5)));
    t.max_idle_timeout(Some(
        Duration::from_secs(30)
            .try_into()
            .expect("30 s is a valid idle timeout"),
    ));
    Arc::new(t)
}

/// How a client decides to trust the server. See the module docs.
#[derive(Clone, Copy, Debug)]
pub enum ServerVerification {
    Pinned(Fingerprint),
    InsecureAcceptAny,
}

#[derive(Debug)]
struct Verifier {
    pin: Option<Fingerprint>,
    provider: Arc<CryptoProvider>,
}

impl ServerCertVerifier for Verifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        match self.pin {
            Some(pin) if Fingerprint::of(end_entity) != pin => {
                Err(rustls::Error::InvalidCertificate(
                    rustls::CertificateError::ApplicationVerificationFailure,
                ))
            }
            _ => Ok(ServerCertVerified::assertion()),
        }
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}

fn client_config(verification: ServerVerification) -> Result<quinn::ClientConfig, NetError> {
    let pin = match verification {
        ServerVerification::Pinned(f) => Some(f),
        ServerVerification::InsecureAcceptAny => None,
    };
    let provider = provider();
    let mut tls = rustls::ClientConfig::builder_with_provider(provider.clone())
        .with_protocol_versions(&[&rustls::version::TLS13])
        .map_err(|e| NetError(e.to_string()))?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(Verifier { pin, provider }))
        .with_no_client_auth();
    tls.alpn_protocols = vec![ALPN.to_vec()];
    let crypto = QuicClientConfig::try_from(tls).map_err(|e| NetError(e.to_string()))?;
    let mut cfg = quinn::ClientConfig::new(Arc::new(crypto));
    cfg.transport_config(transport_config());
    Ok(cfg)
}

/// A QUIC endpoint accepting game connections.
pub fn server_endpoint(bind: SocketAddr, identity: &ServerIdentity) -> Result<Endpoint, NetError> {
    Endpoint::server(identity.server_config()?, bind)
        .map_err(|e| NetError(format!("binding UDP {bind}: {e}")))
}

// ---------------------------------------------------------------------------
// Host side

type Frame = Arc<[u8]>;

enum WriterCmd {
    Frame(Frame),
    Close,
}

enum Event {
    Connected(ConnId, mpsc::Sender<WriterCmd>),
    Message(ConnId, ClientMsg),
    Closed(ConnId),
}

/// Frames buffered per connection before a client counts as too slow and
/// is dropped: about a minute and a half of ticks.
const WRITE_QUEUE: usize = 1024;

/// Runs the lockstep host on `endpoint` until `shutdown` resolves: accepts
/// connections, feeds their messages to the host, executes a tick every
/// `tick_interval` and delivers what the host sends. `on_tick` runs after
/// every tick with the host locked (autosave, logging).
pub async fn run_host(
    endpoint: Endpoint,
    host: Arc<Mutex<LockstepHost>>,
    tick_interval: Duration,
    mut on_tick: impl FnMut(&LockstepHost),
    shutdown: impl Future<Output = ()>,
) {
    let (events_tx, mut events) = mpsc::channel::<Event>(4096);
    let accept = tokio::spawn(accept_loop(endpoint.clone(), events_tx));
    let mut writers: HashMap<ConnId, mpsc::Sender<WriterCmd>> = HashMap::new();
    let mut interval = tokio::time::interval(tick_interval);
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    tokio::pin!(shutdown);

    loop {
        let outputs = tokio::select! {
            _ = interval.tick() => {
                let mut h = host.lock().unwrap();
                h.tick();
                on_tick(&h);
                h.drain_output()
            }
            Some(ev) = events.recv() => {
                let mut h = host.lock().unwrap();
                match ev {
                    Event::Connected(conn, w) => { writers.insert(conn, w); }
                    Event::Message(conn, msg) => {
                        if writers.contains_key(&conn) {
                            h.handle(conn, msg);
                        }
                    }
                    Event::Closed(conn) => {
                        if writers.remove(&conn).is_some() {
                            h.disconnected(conn);
                        }
                    }
                }
                h.drain_output()
            }
            _ = &mut shutdown => break,
        };
        deliver(&host, &mut writers, outputs);
    }

    accept.abort();
    for w in writers.values() {
        let _ = w.try_send(WriterCmd::Close);
    }
    endpoint.close(0u32.into(), b"server shutting down");
    // Give the close frames a moment to go out.
    let _ = tokio::time::timeout(Duration::from_secs(1), endpoint.wait_idle()).await;
}

fn deliver(
    host: &Arc<Mutex<LockstepHost>>,
    writers: &mut HashMap<ConnId, mpsc::Sender<WriterCmd>>,
    mut outputs: Vec<HostOutput>,
) {
    while !outputs.is_empty() {
        let mut too_slow = Vec::new();
        for out in outputs.drain(..) {
            match out {
                HostOutput::Send { to, msg } => {
                    let frame: Frame = encode(&msg).into();
                    for conn in to {
                        let Some(w) = writers.get(&conn) else {
                            continue;
                        };
                        if w.try_send(WriterCmd::Frame(frame.clone())).is_err() {
                            too_slow.push(conn);
                        }
                    }
                }
                HostOutput::Disconnect(conn) => {
                    if let Some(w) = writers.remove(&conn) {
                        // If the queue is full the writer is dropped, which
                        // closes the connection anyway.
                        let _ = w.try_send(WriterCmd::Close);
                    }
                }
            }
        }
        if too_slow.is_empty() {
            break;
        }
        let mut h = host.lock().unwrap();
        for conn in too_slow {
            if writers.remove(&conn).is_some() {
                warn!("dropping {conn:?}: not keeping up");
                h.disconnected(conn);
            }
        }
        outputs = h.drain_output();
    }
}

async fn accept_loop(endpoint: Endpoint, events: mpsc::Sender<Event>) {
    let mut next = 1u64;
    while let Some(incoming) = endpoint.accept().await {
        let conn = ConnId(next);
        next += 1;
        tokio::spawn(serve_connection(conn, incoming, events.clone()));
    }
}

async fn serve_connection(id: ConnId, incoming: quinn::Incoming, events: mpsc::Sender<Event>) {
    let conn = match incoming.await {
        Ok(c) => c,
        Err(e) => {
            debug!("handshake failed: {e}");
            return;
        }
    };
    let remote = conn.remote_address();
    let stream = tokio::time::timeout(Duration::from_secs(10), conn.accept_bi()).await;
    let (send, mut recv) = match stream {
        Ok(Ok(s)) => s,
        _ => {
            conn.close(1u32.into(), b"no stream");
            return;
        }
    };
    info!("{id:?} connected from {remote}");
    let (wtx, wrx) = mpsc::channel(WRITE_QUEUE);
    if events.send(Event::Connected(id, wtx)).await.is_err() {
        return;
    }
    tokio::spawn(write_loop(conn.clone(), send, wrx));
    loop {
        match read_frame(&mut recv, MAX_CLIENT_FRAME).await {
            Ok(Some(payload)) => match decode::<ClientMsg>(&payload) {
                Ok(msg) => {
                    if events.send(Event::Message(id, msg)).await.is_err() {
                        break;
                    }
                }
                Err(e) => {
                    warn!("{id:?}: {e}");
                    conn.close(2u32.into(), b"malformed message");
                    break;
                }
            },
            Ok(None) => break,
            Err(e) => {
                debug!("{id:?} read: {e}");
                break;
            }
        }
    }
    info!("{id:?} disconnected");
    let _ = events.send(Event::Closed(id)).await;
}

async fn write_loop(conn: Connection, mut send: SendStream, mut rx: mpsc::Receiver<WriterCmd>) {
    while let Some(cmd) = rx.recv().await {
        match cmd {
            WriterCmd::Frame(f) => {
                if write_frame(&mut send, &f).await.is_err() {
                    return;
                }
            }
            WriterCmd::Close => break,
        }
    }
    // Let the last frames (Kick, Refused) reach the peer before closing.
    let _ = send.finish();
    let _ = tokio::time::timeout(Duration::from_secs(2), send.stopped()).await;
    conn.close(0u32.into(), b"bye");
}

// ---------------------------------------------------------------------------
// Client side

/// A QUIC connection to a host with its game stream: decoded messages
/// arrive on `inbox`, encoded frames (see [`encode`]) sent to `outbox` are
/// written in order. The reader and writer tasks run on the tokio runtime
/// that called [`ClientLink::connect`]; `inbox` closes when the host closes
/// the stream or the connection dies.
pub struct ClientLink {
    pub endpoint: Endpoint,
    pub conn: Connection,
    pub inbox: mpsc::UnboundedReceiver<ServerMsg>,
    pub outbox: mpsc::UnboundedSender<Vec<u8>>,
}

impl ClientLink {
    /// Opens the connection and the game stream. Sends nothing yet.
    pub async fn connect(
        addr: SocketAddr,
        verification: ServerVerification,
    ) -> Result<ClientLink, NetError> {
        let bind: SocketAddr = if addr.is_ipv6() {
            "[::]:0".parse().unwrap()
        } else {
            "0.0.0.0:0".parse().unwrap()
        };
        let mut endpoint =
            Endpoint::client(bind).map_err(|e| NetError(format!("binding UDP: {e}")))?;
        endpoint.set_default_client_config(client_config(verification)?);
        let conn = endpoint
            .connect(addr, SERVER_NAME)
            .map_err(|e| NetError(format!("connecting to {addr}: {e}")))?
            .await
            .map_err(|e| NetError(format!("connecting to {addr}: {e}")))?;
        let (send, recv) = conn
            .open_bi()
            .await
            .map_err(|e| NetError(format!("opening stream: {e}")))?;

        let (in_tx, inbox) = mpsc::unbounded_channel();
        let (outbox, out_rx) = mpsc::unbounded_channel();
        tokio::spawn(client_read_loop(recv, in_tx));
        tokio::spawn(client_write_loop(send, out_rx));
        Ok(ClientLink {
            endpoint,
            conn,
            inbox,
            outbox,
        })
    }
}

/// A [`LockstepClient`] connected to a host over QUIC.
pub struct NetClient {
    pub client: LockstepClient,
    endpoint: Endpoint,
    conn: Connection,
    inbox: mpsc::UnboundedReceiver<ServerMsg>,
    outbox: mpsc::UnboundedSender<Vec<u8>>,
}

impl NetClient {
    /// Connects, sends Hello and waits for the Welcome (the snapshot). Fails
    /// if the server refuses or cannot be reached.
    pub async fn connect(
        addr: SocketAddr,
        verification: ServerVerification,
        name: &str,
        password: Option<String>,
    ) -> Result<NetClient, NetError> {
        let ClientLink {
            endpoint,
            conn,
            inbox,
            outbox,
        } = ClientLink::connect(addr, verification).await?;
        let mut me = NetClient {
            client: LockstepClient::new(name, password),
            endpoint,
            conn,
            inbox,
            outbox,
        };
        me.flush();
        while me.client.state() == ClientState::Connecting {
            let Some(msg) = me.inbox.recv().await else {
                return Err(NetError("connection closed before Welcome".into()));
            };
            me.client.handle(msg);
        }
        if me.client.state() == ClientState::Closed {
            let reason = me
                .client
                .drain_events()
                .into_iter()
                .find_map(|e| match e {
                    ClientEvent::Refused { reason } | ClientEvent::Kicked { reason } => {
                        Some(reason)
                    }
                    _ => None,
                })
                .unwrap_or_else(|| "refused".into());
            return Err(NetError(format!("server refused: {reason}")));
        }
        me.flush();
        Ok(me)
    }

    /// Sends everything the state machine has queued.
    pub fn flush(&mut self) {
        for msg in self.client.drain_outgoing() {
            let _ = self.outbox.send(encode(&msg));
        }
    }

    /// Without blocking: handles all messages that arrived, simulates up to
    /// `max_ticks` confirmed ticks and flushes outgoing messages.
    pub fn pump(&mut self, max_ticks: usize) -> Vec<ClientEvent> {
        while let Ok(msg) = self.inbox.try_recv() {
            self.client.handle(msg);
        }
        self.client.advance(max_ticks);
        self.flush();
        self.client.drain_events()
    }

    /// Waits until at least one message arrives. Returns `false` once the
    /// connection is gone.
    pub async fn wait(&mut self) -> bool {
        match self.inbox.recv().await {
            Some(msg) => {
                self.client.handle(msg);
                true
            }
            None => false,
        }
    }

    pub fn is_connected(&self) -> bool {
        self.conn.close_reason().is_none()
    }

    /// Round-trip time estimated by QUIC.
    pub fn rtt(&self) -> Duration {
        self.conn.rtt()
    }

    pub async fn close(self) {
        self.conn.close(0u32.into(), b"bye");
        let _ = tokio::time::timeout(Duration::from_secs(1), self.endpoint.wait_idle()).await;
    }
}

async fn client_read_loop(mut recv: RecvStream, tx: mpsc::UnboundedSender<ServerMsg>) {
    while let Ok(Some(payload)) = read_frame(&mut recv, MAX_SERVER_FRAME).await {
        match decode::<ServerMsg>(&payload) {
            Ok(msg) => {
                if tx.send(msg).is_err() {
                    return;
                }
            }
            Err(e) => {
                warn!("from server: {e}");
                return;
            }
        }
    }
}

async fn client_write_loop(mut send: SendStream, mut rx: mpsc::UnboundedReceiver<Vec<u8>>) {
    while let Some(frame) = rx.recv().await {
        if write_frame(&mut send, &frame).await.is_err() {
            return;
        }
    }
    let _ = send.finish();
}
