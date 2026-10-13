#!/usr/bin/env python3
"""Materialize the pinned, iOS-only FIPS source plus reviewed portability patches."""
import pathlib, subprocess, shutil
root = pathlib.Path(__file__).resolve().parents[2]
rev = '80f8f965aa872296edbce84ade9949ece2596602'
cache = root / 'build/ios-fips/upstream'
dest = root / 'crates/wmapp-fips-ios/vendor/fips'
if not cache.exists():
    cache.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['git', 'clone', '--no-checkout', 'https://github.com/jmcorgan/fips.git', str(cache)], check=True)
subprocess.run(['git', '-C', str(cache), 'cat-file', '-e', rev], check=True)
if dest.exists():
    shutil.rmtree(dest)
dest.mkdir(parents=True)
archive = subprocess.Popen(['git', '-C', str(cache), 'archive', rev], stdout=subprocess.PIPE)
subprocess.run(['tar', '-x', '-C', str(dest)], stdin=archive.stdout, check=True)
assert archive.wait() == 0

def replace(file, old, new, count=1):
    p=dest/file; s=p.read_text(); assert s.count(old)==count, (file, old, s.count(old)); p.write_text(s.replace(old,new))

# iOS must never create/configure a system TUN. Existing app-owned mobile
# platform guards deliberately fail these operations; packetFlow supplies bytes.
replace('src/upper/tun.rs', '#[cfg(target_os = "android")]\nmod platform', '#[cfg(any(target_os = "android", target_os = "ios"))]\nmod platform')
# Bound mesh -> extension delivery without blocking the core when iOS suspends
# packet consumption. Full means packet loss, recovered by upper protocols.
replace('src/upper/tun.rs', 'pub type TunTx = mpsc::Sender<Vec<u8>>;', '''#[derive(Clone)]
pub struct TunTx(std::sync::Arc<dyn Fn(Vec<u8>) -> Result<(), mpsc::TrySendError<Vec<u8>>> + Send + Sync>);
impl TunTx {
    pub fn send(&self, packet: Vec<u8>) -> Result<(), mpsc::TrySendError<Vec<u8>>> {
        (self.0)(packet)
    }
}
pub fn bounded_tun_channel() -> (TunTx, mpsc::Receiver<Vec<u8>>) {
    let (tx, rx) = mpsc::sync_channel(64);
    (TunTx(std::sync::Arc::new(move |packet| tx.try_send(packet))), rx)
}''')
replace('src/node/mod.rs', 'let (tun_tx, tun_rx) = std::sync::mpsc::channel();', 'let (tun_tx, tun_rx) = crate::upper::tun::bounded_tun_channel();')
replace('src/upper/tun.rs', 'let (tx, rx) = mpsc::channel();', 'let (tx, rx) = bounded_tun_channel();', 2)
# The iOS adapter supplies a bounded, readiness-signalled sink. Only Rust
# closures cross this boundary; no Swift object/context or packet pointer does.
replace('src/upper/tun.rs', 'impl TunTx {', """impl TunTx {
    pub fn delivery(sink: impl Fn(Vec<u8>) -> Result<(), mpsc::TrySendError<Vec<u8>>> + Send + Sync + 'static) -> Self {
        Self(std::sync::Arc::new(sink))
    }""")
replace('src/node/mod.rs', '    pub fn enable_app_owned_tun(&mut self)', """    pub fn enable_app_owned_delivery(&mut self, sink: crate::upper::tun::TunTx) -> TunOutboundTx {
        let (tx, rx) = tokio::sync::mpsc::channel(self.config().node.buffers.tun_channel);
        self.supervisor.tun_tx = Some(sink);
        self.supervisor.tun_outbound_rx = Some(rx);
        self.tun_state = TunState::Active;
        tx
    }

    pub fn enable_app_owned_tun(&mut self)""")
# A Packet Tunnel has a much smaller memory budget than a desktop daemon.
file=dest/'src/node/lifecycle/mod.rs';s=file.read_text()
start=s.index('            let cpu_default =');end=s.index('            (\n                true,', start)
s=s[:start]+'            let encrypt_worker_count = 1;\n            let decrypt_worker_count = 0;\n'+s[end:];file.write_text(s)
replace('src/node/encrypt_worker.rs', 'const WORKER_CHANNEL_CAP: usize = 1024;', 'const WORKER_CHANNEL_CAP: usize = 64;')
print('Prepared FIPS '+rev+' with iOS platform, bounded packet delivery and worker limits')
