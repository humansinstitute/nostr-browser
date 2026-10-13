//! Level-triggered readiness: a single byte is present iff the queue is nonempty.
//! No foreign callback/context is retained. Queue and readiness change under the
//! same lock, so a producer cannot race the consumer's empty acknowledgement.
use std::{
    collections::VecDeque,
    io::{self, Read, Write},
    os::unix::net::UnixStream,
    sync::Mutex,
};
pub const MAX_PACKETS: usize = 64;
pub const MAX_BYTES: usize = 128 * 1024;
pub const MAX_OUTPUT_PACKET: usize = 4096;
struct State {
    packets: VecDeque<Vec<u8>>,
    bytes: usize,
    closed: bool,
    dropped: u64,
}
// Closes readiness even if the runtime future panics or is aborted before its
// first poll. This guard is owned by that future, not by the Engine consumer.
pub struct CloseOnDrop(pub std::sync::Arc<Delivery>);
impl Drop for CloseOnDrop {
    fn drop(&mut self) {
        self.0.close();
    }
}
pub struct Delivery {
    state: Mutex<State>,
    reader: UnixStream,
    writer: UnixStream,
}
impl Delivery {
    pub fn new() -> io::Result<Self> {
        let (reader, writer) = UnixStream::pair()?;
        reader.set_nonblocking(true)?;
        writer.set_nonblocking(true)?;
        Ok(Self {
            state: Mutex::new(State {
                packets: VecDeque::new(),
                bytes: 0,
                closed: false,
                dropped: 0,
            }),
            reader,
            writer,
        })
    }
    pub fn descriptor(&self) -> io::Result<UnixStream> {
        self.reader.try_clone()
    }
    pub fn push(&self, packet: Vec<u8>) -> Result<(), Vec<u8>> {
        let mut s = self.state.lock().unwrap();
        if s.closed
            || packet.is_empty()
            || packet.len() > MAX_OUTPUT_PACKET
            || s.packets.len() == MAX_PACKETS
            || s.bytes + packet.len() > MAX_BYTES
        {
            s.dropped += 1;
            return Err(packet);
        }
        if s.packets.is_empty() && (&self.writer).write_all(&[1]).is_err() {
            s.closed = true;
            s.dropped += 1;
            return Err(packet);
        }
        s.bytes += packet.len();
        s.packets.push_back(packet);
        Ok(())
    }
    pub fn pop(&self) -> Result<Option<Vec<u8>>, ()> {
        let mut s = self.state.lock().unwrap();
        if s.closed {
            return Err(());
        }
        let packet = s.packets.pop_front();
        if let Some(ref p) = packet {
            s.bytes -= p.len();
            if s.packets.is_empty() && (&self.reader).read_exact(&mut [0]).is_err() {
                s.closed = true;
                return Err(());
            }
        }
        Ok(packet)
    }
    pub fn close(&self) {
        let mut s = self.state.lock().unwrap();
        s.closed = true;
        s.packets.clear();
        s.bytes = 0;
        // EOF wakes an attached source on runtime death as well as orderly stop.
        let _ = self.writer.shutdown(std::net::Shutdown::Write);
    }
    pub fn dropped(&self) -> u64 {
        self.state.lock().unwrap().dropped
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn packet_and_byte_backpressure_and_readiness() {
        let q = Delivery::new().unwrap();
        let mut fd = q.descriptor().unwrap();
        assert_eq!(
            fd.read(&mut [0]).unwrap_err().kind(),
            io::ErrorKind::WouldBlock
        );
        for _ in 0..MAX_PACKETS {
            q.push(vec![0; 1280]).unwrap();
        }
        assert!(q.push(vec![0; 1280]).is_err());
        for _ in 0..MAX_PACKETS {
            assert!(q.pop().unwrap().is_some());
        }
        assert_eq!(
            fd.read(&mut [0]).unwrap_err().kind(),
            io::ErrorKind::WouldBlock
        );
        for _ in 0..32 {
            q.push(vec![0; 4096]).unwrap();
        }
        assert!(q.push(vec![0]).is_err());
        assert!(q.push(vec![0; 4097]).is_err());
        assert_eq!(q.dropped(), 3);
        q.close();
        q.close();
        assert!(q.push(vec![1]).is_err());
        assert!(q.pop().is_err());
    }
    #[test]
    fn concurrent_producers_drain_and_terminal_close() {
        let q = std::sync::Arc::new(Delivery::new().unwrap());
        let threads: Vec<_> = (0..4)
            .map(|_| {
                let q = q.clone();
                std::thread::spawn(move || {
                    for _ in 0..10000 {
                        let _ = q.push(vec![1; 1280]);
                    }
                })
            })
            .collect();
        for _ in 0..10000 {
            let _ = q.pop();
        }
        q.close();
        for t in threads {
            t.join().unwrap();
        }
        assert!(q.pop().is_err());
    }
}
