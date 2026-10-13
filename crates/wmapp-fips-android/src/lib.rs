mod dns_proxy;
mod identity_store;
mod tun_adapter;

use fips::Node;
use jni::objects::{GlobalRef, JByteArray, JClass, JObject, JString, JValue};
use jni::sys::{jint, jlong, jstring};
use jni::{JNIEnv, JavaVM};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::net::Shutdown;
use std::os::fd::{FromRawFd, IntoRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use tokio::sync::oneshot;
use tokio::task::JoinHandle;
use zeroize::{Zeroize, Zeroizing};

#[cfg(test)]
const BOOTSTRAP_NPUB: &str = "npub1qmc3cvfz0yu2hx96nq3gp55zdan2qclealn7xshgr448d3nh6lks7zel98";
#[cfg(test)]
const BOOTSTRAP_ADDRESS: &str = "217.77.8.91:2121";

const CONFIG_YAML: &str = r#"
node:
  leaf_only: true
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
  control:
    enabled: true
tun:
  enabled: true
  mtu: 1280
dns:
  enabled: true
  bind_addr: "::1"
  port: 0
transports:
  udp:
    bind_addr: "0.0.0.0:0"
    advertise_on_nostr: true
    accept_connections: true
    outbound_only: false
peers:
  - npub: "npub1qmc3cvfz0yu2hx96nq3gp55zdan2qclealn7xshgr448d3nh6lks7zel98"
    alias: "wingman-bootstrap"
    addresses:
      - transport: udp
        addr: "217.77.8.91:2121"
    connect_policy: auto_connect
"#;

#[derive(Debug, thiserror::Error)]
enum NativeError {
    #[error("identity unavailable: {0}")]
    Identity(String),
    #[error("configuration invalid: {0}")]
    Config(String),
    #[error("runtime unavailable: {0}")]
    Runtime(String),
    #[error("invalid lifecycle operation: {0}")]
    Lifecycle(String),
    #[error("I/O unavailable: {0}")]
    Io(#[from] std::io::Error),
}

struct ArmedNode {
    node: Node,
    outbound: tokio::sync::mpsc::Sender<Vec<u8>>,
    inbound: std::sync::mpsc::Receiver<Vec<u8>>,
    udp_fds: std::sync::mpsc::Receiver<fips::AppOwnedUdpSocket>,
}

struct StartedNode {
    node: Node,
    outbound: tokio::sync::mpsc::Sender<Vec<u8>>,
    inbound: std::sync::mpsc::Receiver<Vec<u8>>,
    resolver: std::net::SocketAddr,
    transport_mtu: u16,
}

enum Stage {
    Armed(ArmedNode),
    Started(StartedNode),
    Running {
        shutdown: Option<oneshot::Sender<()>>,
        node_task: JoinHandle<()>,
        adapter: tun_adapter::TunAdapter,
    },
}

struct Engine {
    runtime: tokio::runtime::Runtime,
    stage: Option<Stage>,
    npub: String,
    ipv6: String,
    control_path: PathBuf,
}

static ENGINE: OnceLock<Mutex<Option<Engine>>> = OnceLock::new();

fn engine_slot() -> &'static Mutex<Option<Engine>> {
    ENGINE.get_or_init(|| Mutex::new(None))
}

fn prepare(identity_path: &Path, control_path: &Path) -> Result<Value, NativeError> {
    stop().ok();
    let identity = identity_store::load_or_create(identity_path)?;
    let npub = identity.npub();
    let ipv6 = identity.address().to_ipv6().to_string();
    let mut secret = Zeroizing::new(fips::encode_nsec(&identity.keypair().secret_key()));
    let mut config: fips::Config =
        serde_yaml::from_str(CONFIG_YAML).map_err(|e| NativeError::Config(e.to_string()))?;
    config.node.identity.nsec = Some(secret.to_string());
    config.node.control.socket_path = control_path.to_string_lossy().into_owned();
    secret.zeroize();
    let mut node = Node::new(config).map_err(|e| NativeError::Config(e.to_string()))?;
    let (outbound, inbound) = node.enable_app_owned_tun();
    let udp_fds = node.enable_app_owned_udp_fd();
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .map_err(|e| NativeError::Runtime(e.to_string()))?;
    *engine_slot().lock().unwrap() = Some(Engine {
        runtime,
        stage: Some(Stage::Armed(ArmedNode {
            node,
            outbound,
            inbound,
            udp_fds,
        })),
        npub: npub.clone(),
        ipv6: ipv6.clone(),
        control_path: control_path.to_path_buf(),
    });
    Ok(
        json!({"state":"starting","detail":"FIPS is ready for the Android VPN.","nodeNpub":npub,"ipv6":ipv6}),
    )
}

fn start_node() -> Result<Value, NativeError> {
    let mut guard = engine_slot().lock().unwrap();
    let engine = guard
        .as_mut()
        .ok_or_else(|| NativeError::Lifecycle("node is not prepared".into()))?;
    let stage = engine
        .stage
        .take()
        .ok_or_else(|| NativeError::Lifecycle("node is busy".into()))?;
    let Stage::Armed(mut armed) = stage else {
        engine.stage = Some(stage);
        return Err(NativeError::Lifecycle("node was already started".into()));
    };
    if let Err(error) = engine.runtime.block_on(armed.node.start()) {
        return Err(NativeError::Runtime(error.to_string()));
    }
    let resolver = armed
        .node
        .dns_local_addr()
        .ok_or_else(|| NativeError::Runtime("built-in .fips resolver did not start".into()))?;
    let transport_mtu = armed.node.transport_mtu();
    let sockets: Vec<Value> = armed
        .udp_fds
        .try_iter()
        .map(|socket| json!({"instance":socket.instance,"fd":socket.fd}))
        .collect();
    if sockets.is_empty() {
        return Err(NativeError::Runtime(
            "FIPS published no UDP transport descriptor".into(),
        ));
    }
    engine.stage = Some(Stage::Started(StartedNode {
        node: armed.node,
        outbound: armed.outbound,
        inbound: armed.inbound,
        resolver,
        transport_mtu,
    }));
    Ok(json!({"ok":true,"transportSockets":sockets}))
}

struct AndroidPublicDnsResolver {
    vm: Arc<JavaVM>,
    native_class: GlobalRef,
    network_handle: i64,
}

impl tun_adapter::PublicDnsResolver for AndroidPublicDnsResolver {
    fn resolve(&self, query: &[u8]) -> std::io::Result<Vec<u8>> {
        let mut env = self
            .vm
            .attach_current_thread()
            .map_err(|error| std::io::Error::other(error.to_string()))?;
        let query = env
            .byte_array_from_slice(query)
            .map_err(|error| std::io::Error::other(error.to_string()))?;
        let query_object = query.as_ref();
        let answer = env
            .call_static_method(
                &self.native_class,
                "resolvePublicDns",
                "([BJ)[B",
                &[
                    JValue::Object(query_object),
                    JValue::Long(self.network_handle),
                ],
            )
            .and_then(|value| value.l())
            .map_err(|error| std::io::Error::other(error.to_string()))?;
        if answer.is_null() {
            return Err(std::io::Error::other(
                "Android underlying-network DNS query failed",
            ));
        }
        env.convert_byte_array(JByteArray::from(answer))
            .map_err(|error| std::io::Error::other(error.to_string()))
    }
}

fn run_node(
    tun_fd: OwnedFd,
    public_network_handle: i64,
    public_resolver: Arc<dyn tun_adapter::PublicDnsResolver>,
) -> Result<Value, NativeError> {
    if public_network_handle == 0 {
        return Err(NativeError::Lifecycle(
            "underlying network handle is invalid".into(),
        ));
    }
    let mut guard = engine_slot().lock().unwrap();
    let engine = guard
        .as_mut()
        .ok_or_else(|| NativeError::Lifecycle("node is not prepared".into()))?;
    let stage = engine
        .stage
        .take()
        .ok_or_else(|| NativeError::Lifecycle("node is busy".into()))?;
    let Stage::Started(mut started) = stage else {
        engine.stage = Some(stage);
        return Err(NativeError::Lifecycle(
            "transport descriptors must be protected first".into(),
        ));
    };
    let adapter = tun_adapter::TunAdapter::start(
        tun_fd.into_raw_fd(),
        started.outbound,
        started.inbound,
        started.transport_mtu,
        started.resolver,
        public_resolver,
    )?;
    let (shutdown_tx, shutdown_rx) = oneshot::channel();
    let task = engine.runtime.spawn(async move {
        let _ = started
            .node
            .run_rx_loop_with_shutdown(async {
                let _ = shutdown_rx.await;
            })
            .await;
        started.node.finish_shutdown().await;
    });
    engine.stage = Some(Stage::Running {
        shutdown: Some(shutdown_tx),
        node_task: task,
        adapter,
    });
    Ok(
        json!({"state":"running","detail":"FIPS 0.5.0 is routing fd00::/8 through Android VPN.","nodeNpub":engine.npub}),
    )
}

fn inspect() -> Value {
    let guard = engine_slot().lock().unwrap();
    let Some(engine) = guard.as_ref() else {
        return json!({"state":"notInstalled","detail":"Android VPN consent and FIPS startup are required."});
    };
    let (state, detail) = match engine.stage.as_ref() {
        Some(Stage::Armed(_)) => ("starting", "FIPS is waiting for the Android VPN."),
        Some(Stage::Started(_)) => (
            "starting",
            "FIPS transport sockets are awaiting VPN protection.",
        ),
        Some(Stage::Running { node_task, .. }) if !node_task.is_finished() => (
            "running",
            "FIPS 0.5.0 is routing fd00::/8 through Android VPN.",
        ),
        Some(Stage::Running { .. }) => ("failed", "The embedded FIPS node stopped unexpectedly."),
        None => ("failed", "The embedded FIPS lifecycle is unavailable."),
    };
    json!({"state":state,"detail":detail,"nodeNpub":engine.npub,"ipv6":engine.ipv6})
}

fn stop() -> Result<Value, NativeError> {
    let mut engine = engine_slot().lock().unwrap().take();
    if let Some(ref mut engine) = engine {
        if let Some(Stage::Running {
            shutdown,
            node_task,
            adapter,
        }) = engine.stage.as_mut()
        {
            // Stop TUN producers/consumers while the node is still able to
            // drain their channels, then shut down the FIPS receive loop.
            adapter.stop();
            if let Some(sender) = shutdown.take() {
                let _ = sender.send(());
            }
            engine.runtime.block_on(async {
                let _ = tokio::time::timeout(Duration::from_secs(5), node_task).await;
            });
        } else if let Some(Stage::Started(started)) = engine.stage.as_mut() {
            let _ = engine.runtime.block_on(started.node.stop());
        }
    }
    Ok(json!({"state":"notInstalled","detail":"The embedded FIPS VPN is stopped."}))
}

fn send_control(request: Value) -> Result<Value, NativeError> {
    let control_path = {
        let guard = engine_slot().lock().unwrap();
        guard
            .as_ref()
            .ok_or_else(|| NativeError::Lifecycle("node is not running".into()))?
            .control_path
            .clone()
    };
    let mut stream = UnixStream::connect(control_path)?;
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    let mut encoded =
        serde_json::to_vec(&request).map_err(|e| NativeError::Runtime(e.to_string()))?;
    encoded.push(b'\n');
    stream.write_all(&encoded)?;
    stream.shutdown(Shutdown::Write)?;
    let line = BufReader::new(stream)
        .lines()
        .next()
        .ok_or_else(|| NativeError::Runtime("control response was empty".into()))??;
    serde_json::from_str(&line).map_err(|e| NativeError::Runtime(e.to_string()))
}

fn peer_status() -> Result<Value, NativeError> {
    send_control(json!({"command":"show_peers"}))
}

fn probe(npub: &str) -> Result<Value, NativeError> {
    let start = send_control(json!({"command":"probe_start","params":{"npub":npub}}))?;
    let id = start
        .pointer("/data/probe_id")
        .and_then(Value::as_u64)
        .ok_or_else(|| {
            NativeError::Runtime(
                start
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("probe was rejected")
                    .into(),
            )
        })?;
    for _ in 0..30 {
        std::thread::sleep(Duration::from_millis(500));
        let report = send_control(json!({"command":"probe_poll","params":{"probe_id":id}}))?;
        let overall = report
            .pointer("/data/overall")
            .and_then(Value::as_str)
            .unwrap_or("running");
        if overall != "running" {
            return Ok(report);
        }
    }
    let _ = send_control(json!({"command":"probe_cancel","params":{"probe_id":id}}));
    Err(NativeError::Runtime("probe timed out".into()))
}

fn envelope(result: Result<Value, NativeError>) -> String {
    match result {
        Ok(value) => value.to_string(),
        Err(error) => json!({"state":"failed","ok":false,"detail":error.to_string()}).to_string(),
    }
}

fn java_string(env: &mut JNIEnv<'_>, value: String) -> jstring {
    env.new_string(value)
        .map(|s| s.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

fn rust_string(env: &mut JNIEnv<'_>, value: JString<'_>) -> Result<String, NativeError> {
    env.get_string(&value)
        .map(|s| s.into())
        .map_err(|e| NativeError::Runtime(e.to_string()))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_wingmanbefree_wingman_1app_fips_FipsNative_nativePrepare(
    mut env: JNIEnv,
    _: JClass,
    identity_path: JString,
    control_path: JString,
) -> jstring {
    let result = rust_string(&mut env, identity_path).and_then(|identity| {
        rust_string(&mut env, control_path)
            .and_then(|control| prepare(Path::new(&identity), Path::new(&control)))
    });
    java_string(&mut env, envelope(result))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_wingmanbefree_wingman_1app_fips_FipsNative_nativeStartNode(
    mut env: JNIEnv,
    _: JClass,
) -> jstring {
    java_string(&mut env, envelope(start_node()))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_wingmanbefree_wingman_1app_fips_FipsNative_nativeRunNode(
    mut env: JNIEnv,
    object: JObject,
    fd: jint,
    public_network_handle: jlong,
) -> jstring {
    let result = if fd < 0 {
        Err(NativeError::Lifecycle("TUN descriptor is invalid".into()))
    } else {
        // nativeRunNode owns the detached descriptor even when JNI setup or
        // lifecycle validation fails, so every failure path closes it.
        let tun_fd = unsafe { OwnedFd::from_raw_fd(fd) };
        env.get_java_vm()
            .and_then(|vm| {
                env.get_object_class(object)
                    .and_then(|class| env.new_global_ref(class))
                    .map(|class| (vm, class))
            })
            .map(|(vm, native_class)| {
                Arc::new(AndroidPublicDnsResolver {
                    vm: Arc::new(vm),
                    native_class,
                    network_handle: public_network_handle,
                }) as Arc<dyn tun_adapter::PublicDnsResolver>
            })
            .map_err(|error| NativeError::Runtime(error.to_string()))
            .and_then(|resolver| run_node(tun_fd, public_network_handle, resolver))
    };
    java_string(&mut env, envelope(result))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_wingmanbefree_wingman_1app_fips_FipsNative_nativeInspect(
    mut env: JNIEnv,
    _: JClass,
) -> jstring {
    java_string(&mut env, inspect().to_string())
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_wingmanbefree_wingman_1app_fips_FipsNative_nativeStop(
    mut env: JNIEnv,
    _: JClass,
) -> jstring {
    java_string(&mut env, envelope(stop()))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_wingmanbefree_wingman_1app_fips_FipsNative_nativePeerStatus(
    mut env: JNIEnv,
    _: JClass,
) -> jstring {
    java_string(&mut env, envelope(peer_status()))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_wingmanbefree_wingman_1app_fips_FipsNative_nativeProbe(
    mut env: JNIEnv,
    _: JClass,
    npub: JString,
) -> jstring {
    let result = rust_string(&mut env, npub).and_then(|value| probe(&value));
    java_string(&mut env, envelope(result))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::fd::IntoRawFd;
    use std::os::unix::net::UnixDatagram;

    struct UnusedPublicResolver;

    impl tun_adapter::PublicDnsResolver for UnusedPublicResolver {
        fn resolve(&self, _query: &[u8]) -> std::io::Result<Vec<u8>> {
            unreachable!("invalid startup must not query DNS")
        }
    }

    #[test]
    fn pinned_config_has_wingman_scope_and_authenticated_bootstrap() {
        let config: fips::Config = serde_yaml::from_str(CONFIG_YAML).unwrap();
        assert_eq!(config.peers.len(), 1);
        assert_eq!(config.peers[0].npub, BOOTSTRAP_NPUB);
        assert!(CONFIG_YAML.contains(BOOTSTRAP_ADDRESS));
        assert!(CONFIG_YAML.contains("wingman-fips-poc-v1"));
        assert!(CONFIG_YAML.contains("connect_policy: auto_connect"));
    }

    #[test]
    fn stop_is_repeatable_without_preparation() {
        assert_eq!(stop().unwrap()["state"], "notInstalled");
        assert_eq!(stop().unwrap()["state"], "notInstalled");
    }

    #[test]
    fn invalid_public_network_closes_owned_tun_descriptor() {
        let (tun, _peer) = UnixDatagram::pair().unwrap();
        let raw_fd = tun.into_raw_fd();
        let owned_fd = unsafe { OwnedFd::from_raw_fd(raw_fd) };
        let error = run_node(owned_fd, 0, Arc::new(UnusedPublicResolver)).unwrap_err();
        assert!(error.to_string().contains("underlying network handle"));
        assert_eq!(unsafe { libc::fcntl(raw_fd, libc::F_GETFD) }, -1);
        assert_eq!(
            std::io::Error::last_os_error().raw_os_error(),
            Some(libc::EBADF)
        );
    }
}
