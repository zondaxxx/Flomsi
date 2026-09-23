//! A socket that gives up when the server stops talking in the middle of a command.
//!
//! A FETCH of a large message on a slow link may take minutes, so a per-command deadline
//! would cut honest work short. What never happens honestly is a read or a write that
//! makes no progress at all for [STALL]: then the connection is dead or the server hung,
//! and the operation fails with `TimedOut` instead of waiting forever. IDLE is the one
//! time silence is expected; the provider disarms the watchdog around it (TCP keepalive
//! still notices a peer that vanished).

use std::future::Future;
use std::io;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::time::{sleep, Sleep};

#[cfg(not(test))]
pub const STALL: Duration = Duration::from_secs(60);
#[cfg(test)]
pub const STALL: Duration = Duration::from_secs(2);

/// Shared switch: while false, silence is allowed (IDLE).
#[derive(Clone, Debug)]
pub struct Armed(Arc<AtomicBool>);

impl Armed {
    pub fn new() -> Armed {
        Armed(Arc::new(AtomicBool::new(true)))
    }
    pub fn set(&self, on: bool) {
        self.0.store(on, Ordering::SeqCst);
    }
    fn get(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}

impl Default for Armed {
    fn default() -> Self {
        Armed::new()
    }
}

#[derive(Debug)]
pub struct Watchdog<S> {
    inner: S,
    armed: Armed,
    stall: Duration,
    read_timer: Option<Pin<Box<Sleep>>>,
    write_timer: Option<Pin<Box<Sleep>>>,
}

impl<S> Watchdog<S> {
    pub fn new(inner: S, armed: Armed) -> Watchdog<S> {
        Watchdog {
            inner,
            armed,
            stall: STALL,
            read_timer: None,
            write_timer: None,
        }
    }
}

fn stalled() -> io::Error {
    io::Error::new(
        io::ErrorKind::TimedOut,
        format!(
            "the server stopped answering (nothing for {} s)",
            STALL.as_secs()
        ),
    )
}

/// `Pending` from the inner stream: start or check the timer. Anything else clears it.
fn watch<T>(
    result: Poll<io::Result<T>>,
    timer: &mut Option<Pin<Box<Sleep>>>,
    armed: bool,
    stall: Duration,
    cx: &mut Context<'_>,
) -> Poll<io::Result<T>> {
    match result {
        Poll::Pending if armed => {
            let t = timer.get_or_insert_with(|| Box::pin(sleep(stall)));
            match t.as_mut().poll(cx) {
                Poll::Ready(()) => {
                    *timer = None;
                    Poll::Ready(Err(stalled()))
                }
                Poll::Pending => Poll::Pending,
            }
        }
        Poll::Pending => {
            *timer = None;
            Poll::Pending
        }
        ready => {
            *timer = None;
            ready
        }
    }
}

impl<S: AsyncRead + Unpin> AsyncRead for Watchdog<S> {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        let r = Pin::new(&mut this.inner).poll_read(cx, buf);
        watch(r, &mut this.read_timer, this.armed.get(), this.stall, cx)
    }
}

impl<S: AsyncWrite + Unpin> AsyncWrite for Watchdog<S> {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        data: &[u8],
    ) -> Poll<io::Result<usize>> {
        let this = self.get_mut();
        let r = Pin::new(&mut this.inner).poll_write(cx, data);
        // A command just went out: the wait for its answer starts now. (TLS reads ahead
        // after every response, which can leave a read timer running from the previous
        // command; it must not count against this one.)
        if matches!(r, Poll::Ready(Ok(_))) {
            this.read_timer = None;
        }
        watch(r, &mut this.write_timer, this.armed.get(), this.stall, cx)
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        let r = Pin::new(&mut this.inner).poll_flush(cx);
        if matches!(r, Poll::Ready(Ok(_))) {
            this.read_timer = None;
        }
        watch(r, &mut this.write_timer, this.armed.get(), this.stall, cx)
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_shutdown(cx)
    }
}

/// Keepalive probes on the socket: a peer that vanished (a laptop lid, a NAT that forgot
/// us) turns into an error within a couple of minutes even while IDLE is silent.
pub fn keepalive(tcp: &tokio::net::TcpStream) {
    let ka = socket2::TcpKeepalive::new().with_time(Duration::from_secs(60));
    // Probe every 15 s after that; the OS decides how many misses end it (8 on macOS and
    // Linux, 10 on Windows).
    let ka = ka.with_interval(Duration::from_secs(15));
    let _ = socket2::SockRef::from(tcp).set_tcp_keepalive(&ka);
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[tokio::test]
    async fn silence_fails_when_armed_and_waits_when_not() {
        let (a, mut b) = tokio::io::duplex(64);
        let armed = Armed::new();
        let mut w = Watchdog::new(a, armed.clone());

        // Progress keeps it alive.
        b.write_all(b"hello").await.unwrap();
        let mut buf = [0u8; 5];
        w.read_exact(&mut buf).await.unwrap();

        // Silence while armed: TimedOut after STALL.
        let started = std::time::Instant::now();
        let err = w.read(&mut buf).await.unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::TimedOut);
        assert!(started.elapsed() >= STALL);

        // Disarmed (IDLE): silence is fine for longer than STALL.
        armed.set(false);
        let waiter = tokio::spawn(async move {
            let mut buf = [0u8; 2];
            w.read_exact(&mut buf).await.map(|_| buf)
        });
        tokio::time::sleep(STALL + Duration::from_millis(500)).await;
        b.write_all(b"ok").await.unwrap();
        assert_eq!(&waiter.await.unwrap().unwrap(), b"ok");
    }
}
