use simple_dns::{Packet, RCODE};
use std::io;
use std::net::{SocketAddr, UdpSocket};
use std::time::Duration;

pub(crate) const DNS_INTERCEPT: [u8; 4] = [10, 1, 1, 1];
const DNS_PORT: u16 = 53;

#[derive(Debug)]
pub(crate) enum DnsQuery<'a> {
    Fips { ihl: usize, payload: &'a [u8] },
    Public { ihl: usize, payload: &'a [u8] },
    Mixed { ihl: usize, payload: &'a [u8] },
}

pub(crate) fn classify_dns_query(packet: &[u8]) -> Option<DnsQuery<'_>> {
    if packet.len() < 40 || packet[0] >> 4 != 4 || packet[9] != 17 {
        return None;
    }
    let ihl = usize::from(packet[0] & 0x0f) * 4;
    if ihl < 20 || packet.len() < ihl + 20 || packet[16..20] != DNS_INTERCEPT {
        return None;
    }
    if u16::from_be_bytes([packet[ihl + 2], packet[ihl + 3]]) != DNS_PORT {
        return None;
    }
    let udp_len = usize::from(u16::from_be_bytes([packet[ihl + 4], packet[ihl + 5]]));
    if udp_len < 20 || ihl + udp_len > packet.len() {
        return None;
    }
    let payload = &packet[ihl + 8..ihl + udp_len];
    let query = Packet::parse(payload).ok()?;
    if query.questions.is_empty() {
        return None;
    }
    let fips_questions = query
        .questions
        .iter()
        .filter(|question| {
            let name = question.qname.to_string();
            let normalized = name.trim_end_matches('.').to_ascii_lowercase();
            normalized == "fips" || normalized.ends_with(".fips")
        })
        .count();
    Some(match fips_questions {
        0 => DnsQuery::Public { ihl, payload },
        count if count == query.questions.len() => DnsQuery::Fips { ihl, payload },
        _ => DnsQuery::Mixed { ihl, payload },
    })
}

pub(crate) fn proxy_query(
    query_packet: &[u8],
    ihl: usize,
    payload: &[u8],
    resolver: SocketAddr,
) -> io::Result<Vec<u8>> {
    let bind = if resolver.is_ipv6() {
        "[::1]:0"
    } else {
        "127.0.0.1:0"
    };
    let socket = UdpSocket::bind(bind)?;
    socket.set_read_timeout(Some(Duration::from_secs(2)))?;
    socket.connect(resolver)?;
    socket.send(payload)?;
    let mut answer = vec![0u8; 4096];
    let length = socket.recv(&mut answer)?;
    answer.truncate(length);
    Ok(build_ipv4_udp_reply(query_packet, ihl, &answer))
}

pub(crate) fn build_resolver_reply(query: &[u8], ihl: usize, payload: &[u8]) -> Vec<u8> {
    build_ipv4_udp_reply(query, ihl, payload)
}

pub(crate) fn build_error_reply(
    query_packet: &[u8],
    ihl: usize,
    payload: &[u8],
    rcode: RCODE,
) -> Vec<u8> {
    let answer = Packet::parse(payload)
        .map(|query| {
            let mut reply = query.into_reply();
            reply.answers.clear();
            reply.name_servers.clear();
            reply.additional_records.clear();
            *reply.opt_mut() = None;
            *reply.rcode_mut() = rcode;
            reply.build_bytes_vec()
        })
        .and_then(|result| result)
        .unwrap_or_else(|_| {
            let mut reply = payload.to_vec();
            if reply.len() >= 12 {
                reply[2] |= 0x80;
                reply[3] = (reply[3] & 0xf0) | (rcode as u8 & 0x0f);
                reply[6..12].fill(0);
            }
            reply
        });
    build_ipv4_udp_reply(query_packet, ihl, &answer)
}

fn build_ipv4_udp_reply(query: &[u8], ihl: usize, payload: &[u8]) -> Vec<u8> {
    let udp_len = 8 + payload.len();
    let total_len = ihl + udp_len;
    let mut reply = vec![0u8; total_len];
    reply[0] = query[0];
    reply[2..4].copy_from_slice(&(total_len as u16).to_be_bytes());
    reply[6..8].copy_from_slice(&0x4000u16.to_be_bytes());
    reply[8] = 64;
    reply[9] = 17;
    reply[12..16].copy_from_slice(&query[16..20]);
    reply[16..20].copy_from_slice(&query[12..16]);
    if ihl > 20 {
        reply[20..ihl].copy_from_slice(&query[20..ihl]);
    }
    let ipv4_sum = checksum(&reply[..ihl]);
    reply[10..12].copy_from_slice(&ipv4_sum.to_be_bytes());

    reply[ihl..ihl + 2].copy_from_slice(&query[ihl + 2..ihl + 4]);
    reply[ihl + 2..ihl + 4].copy_from_slice(&query[ihl..ihl + 2]);
    reply[ihl + 4..ihl + 6].copy_from_slice(&(udp_len as u16).to_be_bytes());
    reply[ihl + 8..].copy_from_slice(payload);
    let udp_sum = udp_checksum(&reply[12..16], &reply[16..20], &reply[ihl..]);
    reply[ihl + 6..ihl + 8].copy_from_slice(&udp_sum.to_be_bytes());
    reply
}

fn checksum(bytes: &[u8]) -> u16 {
    finish_sum(sum_words(bytes))
}

fn sum_words(bytes: &[u8]) -> u32 {
    let mut sum = 0u32;
    let (chunks, remainder) = bytes.as_chunks::<2>();
    for chunk in chunks {
        sum += u32::from(u16::from_be_bytes([chunk[0], chunk[1]]));
    }
    if let [last] = remainder {
        sum += u32::from(*last) << 8;
    }
    sum
}

fn finish_sum(mut sum: u32) -> u16 {
    while sum >> 16 != 0 {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    !(sum as u16)
}

fn udp_checksum(src: &[u8], dst: &[u8], udp: &[u8]) -> u16 {
    let mut sum = sum_words(src) + sum_words(dst) + 17 + udp.len() as u32;
    let mut zeroed = udp.to_vec();
    zeroed[6] = 0;
    zeroed[7] = 0;
    sum += sum_words(&zeroed);
    let value = finish_sum(sum);
    if value == 0 { 0xffff } else { value }
}

#[cfg(test)]
mod tests {
    use super::*;
    use simple_dns::{CLASS, Name, QCLASS, QTYPE, Question, TYPE};
    use std::thread;

    fn dns_payload(name: &str) -> Vec<u8> {
        let mut packet = Packet::new_query(7);
        packet.questions.push(Question::new(
            Name::new_unchecked(name).into_owned(),
            QTYPE::TYPE(TYPE::AAAA),
            QCLASS::CLASS(CLASS::IN),
            false,
        ));
        packet.build_bytes_vec().unwrap()
    }

    fn query(name: &str) -> Vec<u8> {
        query_from_payload(dns_payload(name))
    }

    fn query_from_payload(payload: Vec<u8>) -> Vec<u8> {
        let total = 28 + payload.len();
        let mut packet = vec![0u8; total];
        packet[0] = 0x45;
        packet[2..4].copy_from_slice(&(total as u16).to_be_bytes());
        packet[8] = 64;
        packet[9] = 17;
        packet[12..16].copy_from_slice(&[10, 0, 0, 2]);
        packet[16..20].copy_from_slice(&DNS_INTERCEPT);
        packet[20..22].copy_from_slice(&4242u16.to_be_bytes());
        packet[22..24].copy_from_slice(&53u16.to_be_bytes());
        packet[24..26].copy_from_slice(&((8 + payload.len()) as u16).to_be_bytes());
        packet[28..].copy_from_slice(&payload);
        packet
    }

    #[test]
    fn intercepts_only_exact_fips_zone() {
        assert!(matches!(
            classify_dns_query(&query("node.fips")),
            Some(DnsQuery::Fips { .. })
        ));
        assert!(matches!(
            classify_dns_query(&query("example.com")),
            Some(DnsQuery::Public { .. })
        ));
        assert!(matches!(
            classify_dns_query(&query("notfips.example")),
            Some(DnsQuery::Public { .. })
        ));

        let mut mixed = Packet::new_query(8);
        for name in ["node.fips", "example.com"] {
            mixed.questions.push(Question::new(
                Name::new_unchecked(name).into_owned(),
                QTYPE::TYPE(TYPE::AAAA),
                QCLASS::CLASS(CLASS::IN),
                false,
            ));
        }
        assert!(matches!(
            classify_dns_query(&query_from_payload(mixed.build_bytes_vec().unwrap())),
            Some(DnsQuery::Mixed { .. })
        ));
    }

    #[test]
    fn proxies_payload_and_builds_valid_checksums() {
        let server = UdpSocket::bind("127.0.0.1:0").unwrap();
        let address = server.local_addr().unwrap();
        let responder = thread::spawn(move || {
            let mut bytes = [0u8; 512];
            let (length, peer) = server.recv_from(&mut bytes).unwrap();
            bytes[2] |= 0x80;
            server.send_to(&bytes[..length], peer).unwrap();
        });
        let packet = query("node.fips");
        let Some(DnsQuery::Fips { ihl, payload }) = classify_dns_query(&packet) else {
            panic!("expected .fips query")
        };
        let reply = proxy_query(&packet, ihl, payload, address).unwrap();
        responder.join().unwrap();
        assert_eq!(checksum(&reply[..ihl]), 0);
        let written_udp_sum = u16::from_be_bytes([reply[ihl + 6], reply[ihl + 7]]);
        assert_eq!(
            udp_checksum(&reply[12..16], &reply[16..20], &reply[ihl..]),
            written_udp_sum
        );
        assert_eq!(&reply[12..16], &DNS_INTERCEPT);
        assert_eq!(&reply[16..20], &[10, 0, 0, 2]);
    }

    #[test]
    fn mixed_query_gets_local_refused_with_valid_checksums() {
        let mut mixed = Packet::new_query(8);
        for name in ["node.fips", "example.com"] {
            mixed.questions.push(Question::new(
                Name::new_unchecked(name).into_owned(),
                QTYPE::TYPE(TYPE::AAAA),
                QCLASS::CLASS(CLASS::IN),
                false,
            ));
        }
        let packet = query_from_payload(mixed.build_bytes_vec().unwrap());
        let Some(DnsQuery::Mixed { ihl, payload }) = classify_dns_query(&packet) else {
            panic!("expected mixed query")
        };
        let reply = build_error_reply(&packet, ihl, payload, RCODE::Refused);
        assert_eq!(
            Packet::parse(&reply[ihl + 8..]).unwrap().rcode(),
            RCODE::Refused
        );
        assert_eq!(checksum(&reply[..ihl]), 0);
        let written_udp_sum = u16::from_be_bytes([reply[ihl + 6], reply[ihl + 7]]);
        assert_eq!(
            udp_checksum(&reply[12..16], &reply[16..20], &reply[ihl..]),
            written_udp_sum
        );
    }
}
