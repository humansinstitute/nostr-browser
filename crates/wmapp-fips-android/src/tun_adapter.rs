use crate::dns_proxy;
use fips::upper::{icmp::effective_ipv6_mtu, tcp_mss::clamp_tcp_mss};
use std::fs::File;
use std::io::{ErrorKind, Read, Write};
use std::net::SocketAddr;
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;
use std::time::Duration;

const TUN_MTU: usize = 1280;

pub(crate) trait PublicDnsResolver: Send + Sync + 'static {
    fn resolve(&self, query: &[u8]) -> std::io::Result<Vec<u8>>;
}

pub(crate) fn is_mesh_ipv6(packet: &[u8]) -> bool {
    packet.len() >= 40 && packet[0] >> 4 == 6 && packet[24] == 0xfd
}

pub(crate) fn clamp_outbound(packet: &mut [u8], transport_mtu: u16) -> bool {
    let max_mss = effective_ipv6_mtu(transport_mtu).saturating_sub(60);
    clamp_tcp_mss(packet, max_mss)
}

pub(crate) struct TunAdapter {
    stop: Arc<AtomicBool>,
    tun: Option<File>,
    reader: Option<JoinHandle<()>>,
    writer: Option<JoinHandle<()>>,
}

impl TunAdapter {
    pub(crate) fn start(
        fd: RawFd,
        outbound: tokio::sync::mpsc::Sender<Vec<u8>>,
        inbound: std::sync::mpsc::Receiver<Vec<u8>>,
        transport_mtu: u16,
        fips_resolver: SocketAddr,
        public_resolver: Arc<dyn PublicDnsResolver>,
    ) -> std::io::Result<Self> {
        // nativeRunNode takes ownership of the detached ParcelFileDescriptor.
        // Keep every clone nonblocking so teardown never joins a thread stuck
        // in a TUN read/write after the Java owner has closed its descriptor.
        let tun = unsafe { File::from_raw_fd(fd) };
        set_nonblocking(tun.as_raw_fd())?;
        let mut input = tun.try_clone()?;
        let mut dns_output = tun.try_clone()?;
        let mut output = tun.try_clone()?;
        let stop = Arc::new(AtomicBool::new(false));
        let reader_stop = Arc::clone(&stop);
        let reader = std::thread::Builder::new()
            .name("wm-fips-tun-in".into())
            .spawn(move || {
                let mut buffer = vec![0u8; TUN_MTU + 256];
                while !reader_stop.load(Ordering::Acquire) {
                    let mut descriptor = libc::pollfd {
                        fd: input.as_raw_fd(),
                        events: libc::POLLIN,
                        revents: 0,
                    };
                    let ready = unsafe { libc::poll(&mut descriptor, 1, 200) };
                    if ready <= 0 {
                        continue;
                    }
                    let length = match input.read(&mut buffer) {
                        Ok(0) => break,
                        Ok(length) => length,
                        Err(error) if error.kind() == ErrorKind::WouldBlock => continue,
                        Err(error) if error.kind() == ErrorKind::Interrupted => continue,
                        Err(_) => break,
                    };
                    let packet = &mut buffer[..length];
                    if let Some(query) = dns_proxy::classify_dns_query(packet) {
                        let reply = match query {
                            dns_proxy::DnsQuery::Fips { ihl, payload } => {
                                dns_proxy::proxy_query(packet, ihl, payload, fips_resolver)
                                    .unwrap_or_else(|_| {
                                        dns_proxy::build_error_reply(
                                            packet,
                                            ihl,
                                            payload,
                                            simple_dns::RCODE::ServerFailure,
                                        )
                                    })
                            }
                            dns_proxy::DnsQuery::Public { ihl, payload } => public_resolver
                                .resolve(payload)
                                .map(|answer| dns_proxy::build_resolver_reply(packet, ihl, &answer))
                                .unwrap_or_else(|_| {
                                    dns_proxy::build_error_reply(
                                        packet,
                                        ihl,
                                        payload,
                                        simple_dns::RCODE::ServerFailure,
                                    )
                                }),
                            dns_proxy::DnsQuery::Mixed { ihl, payload } => {
                                dns_proxy::build_error_reply(
                                    packet,
                                    ihl,
                                    payload,
                                    simple_dns::RCODE::Refused,
                                )
                            }
                        };
                        let _ = write_packet(&mut dns_output, &reply, &reader_stop);
                        continue;
                    }
                    if !is_mesh_ipv6(packet) {
                        continue;
                    }
                    clamp_outbound(packet, transport_mtu);
                    let mut pending = packet.to_vec();
                    loop {
                        match outbound.try_send(pending) {
                            Ok(()) => break,
                            Err(tokio::sync::mpsc::error::TrySendError::Full(packet)) => {
                                pending = packet;
                                if reader_stop.load(Ordering::Acquire) {
                                    return;
                                }
                                std::thread::sleep(Duration::from_millis(10));
                            }
                            Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => return,
                        }
                    }
                }
            })?;
        let writer_stop = Arc::clone(&stop);
        let writer = match std::thread::Builder::new()
            .name("wm-fips-tun-out".into())
            .spawn(move || {
                while !writer_stop.load(Ordering::Acquire) {
                    match inbound.recv_timeout(Duration::from_millis(200)) {
                        Ok(packet) if write_packet(&mut output, &packet, &writer_stop).is_err() => {
                            break;
                        }
                        Ok(_) | Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                    }
                }
            }) {
            Ok(writer) => writer,
            Err(error) => {
                stop.store(true, Ordering::Release);
                drop(tun);
                let _ = reader.join();
                return Err(error);
            }
        };
        Ok(Self {
            stop,
            tun: Some(tun),
            reader: Some(reader),
            writer: Some(writer),
        })
    }

    pub(crate) fn stop(&mut self) {
        self.stop.store(true, Ordering::Release);
        self.tun.take();
        if let Some(handle) = self.reader.take() {
            let _ = handle.join();
        }
        if let Some(handle) = self.writer.take() {
            let _ = handle.join();
        }
    }
}

fn set_nonblocking(fd: RawFd) -> std::io::Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 {
        return Err(std::io::Error::last_os_error());
    }
    if unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}

fn write_packet(file: &mut File, packet: &[u8], stop: &AtomicBool) -> std::io::Result<()> {
    loop {
        match file.write(packet) {
            Ok(length) if length == packet.len() => return Ok(()),
            Ok(_) => return Err(std::io::Error::other("partial TUN packet write")),
            Err(error) if error.kind() == ErrorKind::Interrupted => {}
            Err(error) if error.kind() == ErrorKind::WouldBlock => {
                if stop.load(Ordering::Acquire) {
                    return Ok(());
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(error) => return Err(error),
        }
    }
}

impl Drop for TunAdapter {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use simple_dns::{CLASS, Name, Packet, QCLASS, QTYPE, Question, RCODE, TYPE};
    use std::os::fd::IntoRawFd;
    use std::os::unix::net::UnixDatagram;
    use std::sync::Mutex;

    struct FailingPublicResolver;

    impl PublicDnsResolver for FailingPublicResolver {
        fn resolve(&self, _query: &[u8]) -> std::io::Result<Vec<u8>> {
            Err(std::io::Error::other("test resolver unavailable"))
        }
    }

    struct RecordingPublicResolver {
        queries: Arc<Mutex<Vec<Vec<u8>>>>,
    }

    impl PublicDnsResolver for RecordingPublicResolver {
        fn resolve(&self, query: &[u8]) -> std::io::Result<Vec<u8>> {
            self.queries.lock().unwrap().push(query.to_vec());
            let mut reply = query.to_vec();
            reply[2] |= 0x80;
            Ok(reply)
        }
    }

    fn dns_packet(names: &[&str]) -> Vec<u8> {
        let mut dns = Packet::new_query(42);
        for name in names {
            dns.questions.push(Question::new(
                Name::new_unchecked(name).into_owned(),
                QTYPE::TYPE(TYPE::AAAA),
                QCLASS::CLASS(CLASS::IN),
                false,
            ));
        }
        let payload = dns.build_bytes_vec().unwrap();
        let total = 28 + payload.len();
        let mut packet = vec![0u8; total];
        packet[0] = 0x45;
        packet[2..4].copy_from_slice(&(total as u16).to_be_bytes());
        packet[8] = 64;
        packet[9] = 17;
        packet[12..16].copy_from_slice(&[10, 1, 1, 2]);
        packet[16..20].copy_from_slice(&dns_proxy::DNS_INTERCEPT);
        packet[20..22].copy_from_slice(&4242u16.to_be_bytes());
        packet[22..24].copy_from_slice(&53u16.to_be_bytes());
        packet[24..26].copy_from_slice(&((8 + payload.len()) as u16).to_be_bytes());
        packet[28..].copy_from_slice(&payload);
        packet
    }

    fn receive_dns(app: &UnixDatagram) -> Vec<u8> {
        let mut received = [0u8; 4096];
        let length = app.recv(&mut received).unwrap();
        received[..length].to_vec()
    }

    fn syn_packet(mss: u16) -> Vec<u8> {
        let mut packet = vec![0u8; 64];
        packet[0] = 0x60;
        packet[6] = 6;
        packet[24] = 0xfd;
        packet[40 + 12] = 6 << 4;
        packet[40 + 13] = 0x02;
        packet[60] = 2;
        packet[61] = 4;
        packet[62..64].copy_from_slice(&mss.to_be_bytes());
        packet
    }

    #[test]
    fn admits_only_fd00_destination_ipv6() {
        let mut mesh = vec![0u8; 40];
        mesh[0] = 0x60;
        mesh[24] = 0xfd;
        let mut public = mesh.clone();
        public[24] = 0x20;
        assert!(is_mesh_ipv6(&mesh));
        assert!(!is_mesh_ipv6(&public));
        assert!(!is_mesh_ipv6(&[0x45; 40]));
    }

    #[test]
    fn clamps_outbound_syn_to_fips_safe_mss() {
        let mut packet = syn_packet(1460);
        assert!(clamp_outbound(&mut packet, 1280));
        let expected = effective_ipv6_mtu(1280) - 60;
        assert_eq!(u16::from_be_bytes([packet[62], packet[63]]), expected);
    }

    #[test]
    fn pumps_app_tun_packets_in_both_directions() {
        let (tun, app) = UnixDatagram::pair().unwrap();
        app.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
        let (to_fips, mut from_tun) = tokio::sync::mpsc::channel(1);
        let (to_tun, from_fips) = std::sync::mpsc::channel();
        let resolver = "127.0.0.1:9".parse().unwrap();
        let mut adapter = TunAdapter::start(
            tun.into_raw_fd(),
            to_fips,
            from_fips,
            1280,
            resolver,
            Arc::new(FailingPublicResolver),
        )
        .unwrap();

        let mut outbound = vec![0u8; 40];
        outbound[0] = 0x60;
        outbound[24] = 0xfd;
        app.send(&outbound).unwrap();
        assert_eq!(from_tun.blocking_recv().unwrap(), outbound);

        let inbound = vec![0x60, 0x01, 0x02, 0x03];
        to_tun.send(inbound.clone()).unwrap();
        let mut received = [0u8; 64];
        let length = app.recv(&mut received).unwrap();
        assert_eq!(&received[..length], inbound);

        adapter.stop();
    }

    #[test]
    fn stop_unblocks_when_fips_outbound_channel_is_full() {
        let (tun, app) = UnixDatagram::pair().unwrap();
        let (to_fips, _from_tun) = tokio::sync::mpsc::channel(1);
        let (_to_tun, from_fips) = std::sync::mpsc::channel();
        let resolver = "127.0.0.1:9".parse().unwrap();
        let mut adapter = TunAdapter::start(
            tun.into_raw_fd(),
            to_fips,
            from_fips,
            1280,
            resolver,
            Arc::new(FailingPublicResolver),
        )
        .unwrap();

        let mut outbound = vec![0u8; 40];
        outbound[0] = 0x60;
        outbound[24] = 0xfd;
        app.send(&outbound).unwrap();
        app.send(&outbound).unwrap();
        std::thread::sleep(Duration::from_millis(50));

        let started = std::time::Instant::now();
        adapter.stop();
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn splits_fips_public_and_mixed_dns_without_leaking_questions() {
        let fips_server = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
        let fips_address = fips_server.local_addr().unwrap();
        let fips_queries = Arc::new(Mutex::new(Vec::new()));
        let received_fips_queries = Arc::clone(&fips_queries);
        let fips_responder = std::thread::spawn(move || {
            let mut bytes = [0u8; 4096];
            let (length, peer) = fips_server.recv_from(&mut bytes).unwrap();
            received_fips_queries
                .lock()
                .unwrap()
                .push(bytes[..length].to_vec());
            bytes[2] |= 0x80;
            fips_server.send_to(&bytes[..length], peer).unwrap();
        });
        let public_queries = Arc::new(Mutex::new(Vec::new()));
        let public_resolver = RecordingPublicResolver {
            queries: Arc::clone(&public_queries),
        };
        let (tun, app) = UnixDatagram::pair().unwrap();
        app.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        let (to_fips, _from_tun) = tokio::sync::mpsc::channel(1);
        let (_to_tun, from_fips) = std::sync::mpsc::channel();
        let mut adapter = TunAdapter::start(
            tun.into_raw_fd(),
            to_fips,
            from_fips,
            1280,
            fips_address,
            Arc::new(public_resolver),
        )
        .unwrap();

        app.send(&dns_packet(&["example.com"])).unwrap();
        let public_reply = receive_dns(&app);
        assert_eq!(
            Packet::parse(&public_reply[28..]).unwrap().rcode(),
            RCODE::NoError
        );
        assert_eq!(public_queries.lock().unwrap().len(), 1);
        assert!(fips_queries.lock().unwrap().is_empty());

        app.send(&dns_packet(&["node.fips", "example.com"]))
            .unwrap();
        let mixed_reply = receive_dns(&app);
        assert_eq!(
            Packet::parse(&mixed_reply[28..]).unwrap().rcode(),
            RCODE::Refused
        );
        assert_eq!(public_queries.lock().unwrap().len(), 1);
        assert!(fips_queries.lock().unwrap().is_empty());

        app.send(&dns_packet(&["node.fips"])).unwrap();
        let fips_reply = receive_dns(&app);
        assert_eq!(
            Packet::parse(&fips_reply[28..]).unwrap().rcode(),
            RCODE::NoError
        );
        fips_responder.join().unwrap();
        assert_eq!(fips_queries.lock().unwrap().len(), 1);
        assert_eq!(public_queries.lock().unwrap().len(), 1);

        adapter.stop();
    }

    #[test]
    fn public_resolver_failure_returns_servfail_and_tears_down() {
        let (tun, app) = UnixDatagram::pair().unwrap();
        app.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
        let (to_fips, _from_tun) = tokio::sync::mpsc::channel(1);
        let (_to_tun, from_fips) = std::sync::mpsc::channel();
        let mut adapter = TunAdapter::start(
            tun.into_raw_fd(),
            to_fips,
            from_fips,
            1280,
            "127.0.0.1:9".parse().unwrap(),
            Arc::new(FailingPublicResolver),
        )
        .unwrap();

        app.send(&dns_packet(&["example.com"])).unwrap();
        let reply = receive_dns(&app);
        assert_eq!(
            Packet::parse(&reply[28..]).unwrap().rcode(),
            RCODE::ServerFailure
        );
        let started = std::time::Instant::now();
        adapter.stop();
        assert!(started.elapsed() < Duration::from_secs(1));
    }
}
