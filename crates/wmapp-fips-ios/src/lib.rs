//! Extension-only C ABI. Callers own input buffers; returned JSON is freed once
//! with wm_fips_string_free. Packet calls copy bytes and never retain pointers.
mod delivery;
mod dns_proxy;
use fips::{Identity, Node};
use serde_json::{Value, json};
use std::os::fd::IntoRawFd;
use std::{
    ffi::{CStr, CString, c_char},
    io::{Read, Write},
    net::Shutdown,
    os::unix::net::UnixStream,
    path::Path,
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::Duration,
};
use tokio::{sync::oneshot, task::JoinHandle};
use zeroize::Zeroizing;
#[cfg(test)]
static DNS_WORKERS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
const MAX_PACKET: usize = 1280;
const BOOTSTRAP: &str = "npub1qmc3cvfz0yu2hx96nq3gp55zdan2qclealn7xshgr448d3nh6lks7zel98";
const CONFIG: &str = r#"
node:
  leaf_only: true
  limits: {max_connections: 8, max_peers: 4, max_links: 8, max_pending_inbound: 16, max_sessions: 32}
  buffers: {packet_channel: 64, tun_channel: 64, dns_channel: 16}
  session: {pending_max_destinations: 16}
  rendezvous:
    nostr:
      enabled: true
      policy: open
      app: "wingman-fips-poc-v1"
      advertise: true
      share_local_candidates: true
    lan:
      enabled: true
      scope: "wingman-fips-poc-v1"
  control: {enabled: true, socket_path: "fips.sock"}
tun: {enabled: true, mtu: 1280}
dns: {enabled: true, bind_addr: "::1", port: 0}
transports:
  udp: {bind_addr: "0.0.0.0:0", advertise_on_nostr: true, accept_connections: true, outbound_only: false}
peers:
  - npub: "npub1qmc3cvfz0yu2hx96nq3gp55zdan2qclealn7xshgr448d3nh6lks7zel98"
    alias: "wingman-bootstrap-poc"
    addresses: [{transport: udp, addr: "217.77.8.91:2121"}]
    connect_policy: auto_connect
"#;
struct Engine {
    runtime: tokio::runtime::Runtime,
    task: JoinHandle<()>,
    shutdown: Option<oneshot::Sender<()>>,
    outbound: tokio::sync::mpsc::Sender<Vec<u8>>,
    delivery: Arc<delivery::Delivery>,
    dns_in: Option<mpsc::SyncSender<Vec<u8>>>,
    dns_stop: Arc<AtomicBool>,
    dns_thread: Option<std::thread::JoinHandle<()>>,
    npub: String,
    ipv6: String,
    mtu: u16,
    dropped: u64,
}
static ENGINE: OnceLock<Mutex<Option<Engine>>> = OnceLock::new();
fn slot() -> &'static Mutex<Option<Engine>> {
    ENGINE.get_or_init(|| Mutex::new(None))
}
fn failure(code: &str) -> Value {
    json!({"state":"failed","ok":false,"detail":code})
}
fn start(secret: &[u8; 32], directory: &str) -> Result<Value, &'static str> {
    let mut guard = slot().lock().map_err(|_| "FIPS lifecycle unavailable.")?;
    if guard.is_some() {
        return Err("FIPS is already started; stop before restarting.");
    }
    let identity = Identity::from_secret_bytes(secret).map_err(|_| "FIPS identity is invalid.")?;
    let npub = identity.npub();
    let ipv6 = identity.address().to_ipv6().to_string();
    // Extension-private working directory avoids Darwin's short sockaddr_un limit.
    // Only this dedicated extension process calls this ABI, never Runner.
    if !Path::new(directory).is_dir() {
        return Err("FIPS private directory unavailable.");
    }
    std::env::set_current_dir(directory).map_err(|_| "FIPS private directory unavailable.")?;
    let config = serde_yaml::from_str(CONFIG).map_err(|_| "FIPS configuration invalid.")?;
    let mut node =
        Node::with_identity(identity, config).map_err(|_| "FIPS initialization failed.")?;
    let delivery = Arc::new(delivery::Delivery::new().map_err(|_| "FIPS readiness unavailable.")?);
    let sink = delivery.clone();
    let outbound = node.enable_app_owned_delivery(fips::upper::tun::TunTx::delivery(move |p| {
        sink.push(p).map_err(mpsc::TrySendError::Full)
    }));
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_stack_size(2 * 1024 * 1024)
        .enable_all()
        .build()
        .map_err(|_| "FIPS runtime unavailable.")?;
    runtime
        .block_on(async { tokio::time::timeout(Duration::from_secs(15), node.start()).await })
        .map_err(|_| "FIPS startup timed out.")?
        .map_err(|_| "FIPS transport startup failed.")?;
    let resolver = node.dns_local_addr().ok_or("FIPS DNS startup failed.")?;
    let mtu = node.transport_mtu();
    let (dns_tx, dns_rx) = mpsc::sync_channel::<Vec<u8>>(16);
    let reply_tx = delivery.clone();
    let dns_stop = Arc::new(AtomicBool::new(false));
    let worker_stop = dns_stop.clone();
    let dns_thread = std::thread::Builder::new()
        .name("fips-dns".into())
        .stack_size(256 * 1024)
        .spawn(move || {
            #[cfg(test)]
            DNS_WORKERS.fetch_add(1, Ordering::SeqCst);
            while let Ok(packet) = dns_rx.recv() {
                if worker_stop.load(Ordering::Acquire) {
                    break;
                }
                let Some(query) = dns_proxy::classify_dns_query(&packet) else {
                    continue;
                };
                let reply = match query {
                    dns_proxy::DnsQuery::Fips { ihl, payload } => dns_proxy::proxy_query(
                        &packet, ihl, payload, resolver,
                    )
                    .unwrap_or_else(|_| {
                        dns_proxy::build_error_reply(
                            &packet,
                            ihl,
                            payload,
                            simple_dns::RCODE::ServerFailure,
                        )
                    }),
                    dns_proxy::DnsQuery::Public { ihl, payload }
                    | dns_proxy::DnsQuery::Mixed { ihl, payload } => dns_proxy::build_error_reply(
                        &packet,
                        ihl,
                        payload,
                        simple_dns::RCODE::Refused,
                    ),
                };
                let _ = reply_tx.push(reply);
            }
            #[cfg(test)]
            DNS_WORKERS.fetch_sub(1, Ordering::SeqCst);
        })
        .map_err(|_| "FIPS DNS worker unavailable.")?;
    let (shutdown, rx) = oneshot::channel();
    let terminal_delivery = delivery::CloseOnDrop(delivery.clone());
    let task = runtime.spawn(async move {
        let terminal_delivery = terminal_delivery;
        let _ = node
            .run_rx_loop_with_shutdown(async {
                let _ = rx.await;
            })
            .await;
        terminal_delivery.0.close();
        node.finish_shutdown().await;
    });
    *guard = Some(Engine {
        runtime,
        task,
        shutdown: Some(shutdown),
        outbound,
        delivery,
        dns_in: Some(dns_tx),
        dns_stop,
        dns_thread: Some(dns_thread),
        npub: npub.clone(),
        ipv6: ipv6.clone(),
        mtu,
        dropped: 0,
    });
    Ok(
        json!({"state":"running","detail":"FIPS packet runtime started.","nodeNpub":npub,"ipv6":ipv6}),
    )
}
fn stop() -> Value {
    if let Ok(mut guard) = slot().lock() {
        if let Some(mut engine) = guard.take() {
            engine.delivery.close();
            engine.dns_stop.store(true, Ordering::Release);
            engine.dns_in.take();
            if let Some(tx) = engine.shutdown.take() {
                let _ = tx.send(());
            }
            engine.runtime.block_on(async {
                let _ = tokio::time::timeout(Duration::from_secs(3), &mut engine.task).await;
            });
            engine.task.abort();
            if let Some(worker) = engine.dns_thread.take() {
                let _ = worker.join();
            }
            engine.runtime.shutdown_timeout(Duration::from_secs(1));
        }
    }
    json!({"state":"notInstalled","detail":"FIPS VPN is stopped."})
}
fn status() -> Value {
    let Ok(guard) = slot().lock() else {
        return failure("FIPS lifecycle unavailable.");
    };
    match guard.as_ref() {
        Some(e) if !e.task.is_finished() => {
            json!({"state":"running","detail":"FIPS 0.5.0 packet runtime is running.","nodeNpub":e.npub,"ipv6":e.ipv6,"droppedPackets":e.dropped + e.delivery.dropped()})
        }
        Some(_) => failure("FIPS runtime stopped unexpectedly. Restart the VPN."),
        None => json!({"state":"notInstalled","detail":"FIPS VPN is stopped."}),
    }
}
fn control(request: Value) -> Result<Value, &'static str> {
    let mut stream =
        UnixStream::connect("fips.sock").map_err(|_| "FIPS diagnostics unavailable.")?;
    stream.set_read_timeout(Some(Duration::from_secs(1))).ok();
    stream.set_write_timeout(Some(Duration::from_secs(1))).ok();
    let mut bytes = request.to_string().into_bytes();
    bytes.push(b'\n');
    stream
        .write_all(&bytes)
        .map_err(|_| "FIPS diagnostics unavailable.")?;
    stream.shutdown(Shutdown::Write).ok();
    let mut out = Vec::new();
    stream
        .take(128 * 1024)
        .read_to_end(&mut out)
        .map_err(|_| "FIPS diagnostics timed out.")?;
    serde_json::from_slice(&out).map_err(|_| "FIPS diagnostics invalid.")
}
fn peers() -> Value {
    match control(json!({"command":"show_peers"})) {
        Ok(v) => {
            let connected = v
                .pointer("/data/peers")
                .and_then(Value::as_array)
                .is_some_and(|p| {
                    p.iter().any(|p| {
                        p["npub"] == BOOTSTRAP
                            && p["connectivity"]
                                .as_str()
                                .is_some_and(|s| s.eq_ignore_ascii_case("connected"))
                    })
                });
            json!({"connected":connected})
        }
        Err(_) => json!({"connected":false}),
    }
}
fn probe(npub: &str) -> Value {
    let start = match control(json!({"command":"probe_start","params":{"npub":npub}})) {
        Ok(value) => value,
        Err(_) => return json!({"ok":false,"detail":"FIPS probe could not start."}),
    };
    let Some(id) = start.pointer("/data/probe_id").and_then(Value::as_u64) else {
        return json!({"ok":false,"detail":"FIPS probe was rejected."});
    };
    for _ in 0..30 {
        std::thread::sleep(Duration::from_millis(500));
        let report = match control(json!({"command":"probe_poll","params":{"probe_id":id}})) {
            Ok(value) => value,
            Err(_) => return json!({"ok":false,"detail":"FIPS probe status was unavailable."}),
        };
        let overall = report
            .pointer("/data/overall")
            .and_then(Value::as_str)
            .unwrap_or("running");
        if overall != "running" {
            return json!({
                "ok": overall == "ok",
                "detail": format!("FIPS probe completed: {overall}.")
            });
        }
    }
    let _ = control(json!({"command":"probe_cancel","params":{"probe_id":id}}));
    json!({"ok":false,"detail":"FIPS probe timed out."})
}
fn mesh_packet(packet: &[u8]) -> bool {
    packet.len() >= 40
        && packet.len() <= MAX_PACKET
        && packet[0] >> 4 == 6
        && packet[24] == 0xfd
        && usize::from(u16::from_be_bytes([packet[4], packet[5]])) + 40 == packet.len()
}
fn input(packet: &[u8]) -> i32 {
    if packet.is_empty() || packet.len() > MAX_PACKET {
        return -1;
    }
    let Ok(mut guard) = slot().lock() else {
        return -2;
    };
    let Some(e) = guard.as_mut() else { return -2 };
    if e.task.is_finished() {
        return -2;
    }
    let accepted = if dns_proxy::classify_dns_query(packet).is_some() {
        e.dns_in
            .as_ref()
            .is_some_and(|tx| tx.try_send(packet.to_vec()).is_ok())
    } else if mesh_packet(packet) {
        let mut packet = packet.to_vec();
        let ceiling = fips::upper::icmp::effective_ipv6_mtu(e.mtu.min(1280)).saturating_sub(60);
        fips::upper::tcp_mss::clamp_tcp_mss(&mut packet, ceiling);
        e.outbound.try_send(packet).is_ok()
    } else {
        return -1;
    };
    if accepted {
        0
    } else {
        e.dropped += 1;
        1
    }
}
fn boundary(f: impl FnOnce() -> Value) -> *mut c_char {
    let v = std::panic::catch_unwind(std::panic::AssertUnwindSafe(f))
        .unwrap_or_else(|_| failure("FIPS internal failure."));
    CString::new(v.to_string())
        .expect("JSON has no NUL")
        .into_raw()
}
/// # Safety
/// secret points to 32 bytes, directory is a valid NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wm_fips_start(secret: *const u8, directory: *const c_char) -> *mut c_char {
    boundary(|| {
        if secret.is_null() || directory.is_null() {
            return failure("FIPS startup arguments missing.");
        }
        let mut key = Zeroizing::new([0u8; 32]);
        unsafe {
            key.copy_from_slice(std::slice::from_raw_parts(secret, 32));
        }
        let Ok(dir) = (unsafe { CStr::from_ptr(directory) }).to_str() else {
            return failure("FIPS directory invalid.");
        };
        start(&key, dir).unwrap_or_else(failure)
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn wm_fips_stop() -> *mut c_char {
    boundary(stop)
}
#[unsafe(no_mangle)]
pub extern "C" fn wm_fips_status() -> *mut c_char {
    boundary(status)
}
#[unsafe(no_mangle)]
pub extern "C" fn wm_fips_peers() -> *mut c_char {
    boundary(peers)
}
/// # Safety
/// npub is a valid NUL-terminated UTF-8 string. Input is not retained.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wm_fips_probe(npub: *const c_char) -> *mut c_char {
    boundary(|| {
        if npub.is_null() {
            return json!({"ok":false,"detail":"A FIPS node is required."});
        }
        let Ok(npub) = (unsafe { CStr::from_ptr(npub) }).to_str() else {
            return json!({"ok":false,"detail":"Invalid FIPS node npub."});
        };
        if npub.len() != 63 || !npub.starts_with("npub1") {
            return json!({"ok":false,"detail":"Invalid FIPS node npub."});
        }
        probe(npub)
    })
}
/// # Safety
/// ptr is NULL or an unfreed pointer returned by a wm_fips JSON function.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wm_fips_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(unsafe { CString::from_raw(ptr) });
    }
}
/// # Safety
/// bytes is readable for len bytes. No pointer is retained.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wm_fips_input(bytes: *const u8, len: usize) -> i32 {
    if bytes.is_null() || len > MAX_PACKET {
        return -1;
    }
    std::panic::catch_unwind(|| input(unsafe { std::slice::from_raw_parts(bytes, len) }))
        .unwrap_or(-2)
}
/// Transfers one duplicated readiness descriptor to the caller, or -1 on error.
/// Caller must close exactly once after its dispatch source is cancelled.
/// Do not read it: wm_fips_output acknowledges readiness atomically with dequeue.
#[unsafe(no_mangle)]
pub extern "C" fn wm_fips_output_descriptor() -> i32 {
    std::panic::catch_unwind(|| {
        let Ok(guard) = slot().lock() else { return -1 };
        let Some(e) = guard.as_ref() else { return -1 };
        e.delivery
            .descriptor()
            .map(IntoRawFd::into_raw_fd)
            .unwrap_or(-1)
    })
    .unwrap_or(-1)
}
/// # Safety
/// output is writable for capacity bytes. Returns length, 0 if empty, or error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wm_fips_output(output: *mut u8, capacity: usize) -> i32 {
    if output.is_null() || capacity < 4096 {
        return -1;
    }
    std::panic::catch_unwind(|| {
        let Ok(guard) = slot().lock() else { return -2 };
        let Some(e) = guard.as_ref() else { return -2 };
        if e.task.is_finished() {
            return -2;
        }
        let packet = e.delivery.pop();
        match packet {
            Ok(Some(p)) if p.len() <= capacity => {
                unsafe { std::ptr::copy_nonoverlapping(p.as_ptr(), output, p.len()) };
                p.len() as i32
            }
            Ok(Some(_)) => -1,
            Ok(None) => 0,
            Err(_) => -2,
        }
    })
    .unwrap_or(-2)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ffi_null_ownership_and_errors() {
        unsafe {
            let p = wm_fips_start(std::ptr::null(), std::ptr::null());
            assert_eq!(
                serde_json::from_slice::<Value>(CStr::from_ptr(p).to_bytes()).unwrap()["state"],
                "failed"
            );
            wm_fips_string_free(p);
            let probe = wm_fips_probe(std::ptr::null());
            let decoded: Value = serde_json::from_slice(CStr::from_ptr(probe).to_bytes()).unwrap();
            assert_eq!(decoded["ok"], false);
            assert!(decoded["detail"].as_str().unwrap().contains("required"));
            wm_fips_string_free(probe);
            wm_fips_string_free(std::ptr::null_mut());
            assert_eq!(wm_fips_input(std::ptr::null(), 10), -1);
            assert_eq!(wm_fips_output(std::ptr::null_mut(), 4096), -1);
        }
    }
    #[test]
    fn pinned_config_enables_wingman_rendezvous_and_bootstrap() {
        const RENDEZVOUS_SCOPE: &str = "wingman-fips-poc-v1";
        let config: fips::Config = serde_yaml::from_str(CONFIG).unwrap();
        assert_eq!(config.peers.len(), 1);
        assert_eq!(config.peers[0].npub, BOOTSTRAP);
        assert!(CONFIG.contains("217.77.8.91:2121"));
        assert!(CONFIG.contains(RENDEZVOUS_SCOPE));
        assert!(CONFIG.contains("nostr:"));
        assert!(CONFIG.contains("enabled: true"));
        assert!(CONFIG.contains("policy: open"));
        assert!(CONFIG.contains("share_local_candidates: true"));
        assert!(CONFIG.contains("lan:"));
        assert!(CONFIG.contains("advertise_on_nostr: true"));
        assert!(CONFIG.contains("connect_policy: auto_connect"));
    }
    #[test]
    fn packet_lengths_and_destinations() {
        let mut p = vec![0; 40];
        p[0] = 0x60;
        p[24] = 0xfd;
        assert!(mesh_packet(&p));
        p[5] = 1;
        assert!(!mesh_packet(&p));
        p[5] = 0;
        p[24] = 0x20;
        assert!(!mesh_packet(&p));
        for n in 0..40 {
            assert!(!mesh_packet(&p[..n]));
        }
    }
    #[test]
    fn lifecycle_start_stop_persists_identity_and_rejects_double_start() {
        let previous = std::env::current_dir().unwrap();
        let dir = previous.join("target/ffi-lifecycle-test");
        std::fs::create_dir_all(&dir).unwrap();
        let key = [7u8; 32];
        assert!(start(&[0; 32], dir.to_str().unwrap()).is_err());
        let first = start(&key, dir.to_str().unwrap()).unwrap();
        assert!(start(&key, dir.to_str().unwrap()).is_err());
        assert_eq!(status()["state"], "running");
        use std::os::fd::FromRawFd;
        let fd = wm_fips_output_descriptor();
        assert!(fd >= 0);
        let mut old_readiness = unsafe { UnixStream::from_raw_fd(fd) };
        assert_eq!(stop()["state"], "notInstalled");
        assert_eq!(stop()["state"], "notInstalled");
        let second = start(&key, dir.to_str().unwrap()).unwrap();
        assert_eq!(first["nodeNpub"], second["nodeNpub"]);
        assert_eq!(first["ipv6"], second["ipv6"]);
        assert_eq!(
            old_readiness.read(&mut [0]).unwrap(),
            0,
            "old generation must see EOF, never new packets"
        );
        // Runtime death must reject input/output honestly and wake its source.
        let mut death_readiness = unsafe { UnixStream::from_raw_fd(wm_fips_output_descriptor()) };
        slot().lock().unwrap().as_ref().unwrap().task.abort();
        for _ in 0..100 {
            if status()["state"] == "failed" {
                break;
            }
            std::thread::sleep(Duration::from_millis(1));
        }
        assert_eq!(status()["state"], "failed");
        assert_eq!(death_readiness.read(&mut [0]).unwrap(), 0);
        let mut output = [0; 4096];
        assert_eq!(
            unsafe { wm_fips_output(output.as_mut_ptr(), output.len()) },
            -2
        );
        stop();
        assert_eq!(wm_fips_output_descriptor(), -1);
        assert_eq!(DNS_WORKERS.load(Ordering::SeqCst), 0);
        for _ in 0..5 {
            start(&key, dir.to_str().unwrap()).unwrap();
            let began = std::time::Instant::now();
            stop();
            assert!(began.elapsed() < Duration::from_secs(6));
            assert_eq!(
                DNS_WORKERS.load(Ordering::SeqCst),
                0,
                "DNS worker leaked across stop"
            );
        }
        std::env::set_current_dir(previous).unwrap();
    }
    #[test]
    #[ignore = "Contacts the public PoC bootstrap; run explicitly with network access"]
    fn live_authenticated_bootstrap() {
        let previous = std::env::current_dir().unwrap();
        let dir = previous.join("target/ffi-live-test");
        std::fs::create_dir_all(&dir).unwrap();
        let identity = Identity::generate();
        let key = Zeroizing::new(identity.keypair().secret_bytes());
        start(&key, dir.to_str().unwrap()).unwrap();
        let mut connected = false;
        for _ in 0..40 {
            if peers()["connected"] == true {
                connected = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(500));
        }
        // Exercise the same packet DNS boundary used by packetFlow.
        let mut query = simple_dns::Packet::new_query(42);
        query.questions.push(simple_dns::Question::new(
            simple_dns::Name::new_unchecked(&format!("{BOOTSTRAP}.fips")).into_owned(),
            simple_dns::QTYPE::TYPE(simple_dns::TYPE::AAAA),
            simple_dns::QCLASS::CLASS(simple_dns::CLASS::IN),
            false,
        ));
        let payload = query.build_bytes_vec().unwrap();
        let mut packet = vec![0u8; 28 + payload.len()];
        let len = packet.len() as u16;
        packet[0] = 0x45;
        packet[2..4].copy_from_slice(&len.to_be_bytes());
        packet[9] = 17;
        packet[12..16].copy_from_slice(&[10, 1, 1, 2]);
        packet[16..20].copy_from_slice(&[10, 1, 1, 1]);
        packet[20..22].copy_from_slice(&4242u16.to_be_bytes());
        packet[22..24].copy_from_slice(&53u16.to_be_bytes());
        packet[24..26].copy_from_slice(&((payload.len() + 8) as u16).to_be_bytes());
        packet[28..].copy_from_slice(&payload);
        assert_eq!(input(&packet), 0);
        let mut resolved = false;
        for _ in 0..100 {
            let mut out = [0u8; 4096];
            let length = unsafe { wm_fips_output(out.as_mut_ptr(), out.len()) };
            if length > 28 && out[0] >> 4 == 4 {
                let answer = simple_dns::Packet::parse(&out[28..length as usize]).unwrap();
                resolved = answer.id() == 42 && !answer.answers.is_empty();
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        stop();
        std::env::set_current_dir(previous).unwrap();
        assert!(
            connected,
            "No authenticated bootstrap connection within 20 seconds"
        );
        assert!(resolved, "No AAAA answer through packet DNS adapter");
    }
    #[test]
    fn bounded_upstream_delivery_drops_without_blocking() {
        let (tx, rx) = fips::upper::tun::bounded_tun_channel();
        for _ in 0..64 {
            tx.send(vec![0; 1280]).unwrap();
        }
        assert!(tx.send(vec![0; 1280]).is_err());
        assert_eq!(rx.try_iter().count(), 64);
    }
}
