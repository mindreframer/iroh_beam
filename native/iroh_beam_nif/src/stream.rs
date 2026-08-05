use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::Mutex;

use bytes::Bytes;
use iroh::endpoint::{RecvStream, SendStream, VarInt};
use rustler::{
    Binary, Encoder, Env, LocalPid, Monitor, NewBinary, OwnedEnv, Resource, ResourceArc, Term,
};
use tokio::sync::Notify;

use crate::connection::ConnectionResource;
use crate::endpoint::start_endpoint_operation;
use crate::{atoms, native_error, NativeError};

const NO_ABORT: u64 = u64::MAX;
const MAX_ABORT_CODE: u64 = (1u64 << 62) - 1;
static ACTIVE_STREAMS: AtomicUsize = AtomicUsize::new(0);
static QUEUED_BYTES: AtomicUsize = AtomicUsize::new(0);
static PEAK_QUEUED_BYTES: AtomicUsize = AtomicUsize::new(0);

pub(crate) struct StreamResource {
    send: Mutex<Option<SendStream>>,
    recv: Mutex<Option<RecvStream>>,
    _connection: ResourceArc<ConnectionResource>,
    id: u64,
    send_busy: AtomicBool,
    recv_busy: AtomicBool,
    send_closed: AtomicBool,
    recv_closed: AtomicBool,
    reset_code: AtomicU64,
    stop_code: AtomicU64,
    reset_notify: Notify,
    stop_notify: Notify,
    released: AtomicBool,
}

impl StreamResource {
    fn close(&self) -> bool {
        if self.released.swap(true, Ordering::AcqRel) {
            return false;
        }
        self.request_reset(0);
        self.request_stop(0);
        ACTIVE_STREAMS.fetch_sub(1, Ordering::AcqRel);
        true
    }

    fn request_reset(&self, code: u64) {
        self.reset_code.store(code, Ordering::Release);
        self.send_closed.store(true, Ordering::Release);
        self.reset_notify.notify_one();
        if let Ok(mut slot) = self.send.lock() {
            if let Some(mut stream) = slot.take() {
                if let Ok(code) = VarInt::from_u64(code) {
                    let _ignored = stream.reset(code);
                }
            }
        }
    }

    fn request_stop(&self, code: u64) {
        self.stop_code.store(code, Ordering::Release);
        self.recv_closed.store(true, Ordering::Release);
        self.stop_notify.notify_one();
        if let Ok(mut slot) = self.recv.lock() {
            if let Some(mut stream) = slot.take() {
                if let Ok(code) = VarInt::from_u64(code) {
                    let _ignored = stream.stop(code);
                }
            }
        }
    }
}

impl Drop for StreamResource {
    fn drop(&mut self) {
        self.close();
    }
}

#[rustler::resource_impl]
impl Resource for StreamResource {
    fn down(&self, _env: Env<'_>, _pid: LocalPid, _monitor: Monitor) {
        self.close();
    }
}

struct SendLease {
    resource: ResourceArc<StreamResource>,
    stream: Option<SendStream>,
}

impl Drop for SendLease {
    fn drop(&mut self) {
        self.resource.send_busy.store(false, Ordering::Release);
        if !self.resource.send_closed.load(Ordering::Acquire) {
            if let Some(stream) = self.stream.take() {
                if let Ok(mut slot) = self.resource.send.lock() {
                    *slot = Some(stream);
                }
            }
        }
    }
}

struct RecvLease {
    resource: ResourceArc<StreamResource>,
    stream: Option<RecvStream>,
}

impl Drop for RecvLease {
    fn drop(&mut self) {
        self.resource.recv_busy.store(false, Ordering::Release);
        if !self.resource.recv_closed.load(Ordering::Acquire) {
            if let Some(stream) = self.stream.take() {
                if let Ok(mut slot) = self.resource.recv.lock() {
                    *slot = Some(stream);
                }
            }
        }
    }
}

struct QueueGuard(usize);

impl QueueGuard {
    fn new(bytes: usize) -> Self {
        let current = QUEUED_BYTES.fetch_add(bytes, Ordering::AcqRel) + bytes;
        let mut peak = PEAK_QUEUED_BYTES.load(Ordering::Acquire);
        while current > peak {
            match PEAK_QUEUED_BYTES.compare_exchange_weak(
                peak,
                current,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => break,
                Err(observed) => peak = observed,
            }
        }
        Self(bytes)
    }
}

impl Drop for QueueGuard {
    fn drop(&mut self) {
        QUEUED_BYTES.fetch_sub(self.0, Ordering::AcqRel);
    }
}

struct BinaryResult(Vec<u8>);

impl Encoder for BinaryResult {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        let mut binary = NewBinary::new(env, self.0.len());
        binary.as_mut_slice().copy_from_slice(&self.0);
        binary.into()
    }
}

enum ReadResult {
    Eof,
    Data(Vec<u8>),
}

impl Encoder for ReadResult {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            Self::Eof => atoms::eof().encode(env),
            Self::Data(bytes) => BinaryResult(bytes.clone()).encode(env),
        }
    }
}

#[derive(rustler::NifMap)]
struct StreamInfo {
    id: u64,
    direction: rustler::Atom,
    send: bool,
    recv: bool,
    send_closed: bool,
    recv_closed: bool,
}

#[derive(rustler::NifMap)]
struct StreamSnapshot {
    active_streams: usize,
    queued_bytes: usize,
    peak_queued_bytes: usize,
}

#[derive(rustler::NifMap)]
struct DatagramInfo {
    max_size: Option<usize>,
    send_buffer_space: usize,
}

fn stream_error(
    operation: rustler::Atom,
    category: rustler::Atom,
    message: &'static str,
) -> NativeError {
    native_error(category, operation, message)
}

fn wrap_stream(
    send: Option<SendStream>,
    recv: Option<RecvStream>,
    connection: ResourceArc<ConnectionResource>,
    owner: LocalPid,
    operation: rustler::Atom,
) -> Result<ResourceArc<StreamResource>, NativeError> {
    let id = send
        .as_ref()
        .map(|stream| u64::from(stream.id()))
        .or_else(|| recv.as_ref().map(|stream| u64::from(stream.id())))
        .ok_or_else(|| stream_error(operation, atoms::internal(), "stream has no halves"))?;
    ACTIVE_STREAMS.fetch_add(1, Ordering::AcqRel);
    let resource = ResourceArc::new(StreamResource {
        send: Mutex::new(send),
        recv: Mutex::new(recv),
        _connection: connection,
        id,
        send_busy: AtomicBool::new(false),
        recv_busy: AtomicBool::new(false),
        send_closed: AtomicBool::new(false),
        recv_closed: AtomicBool::new(false),
        reset_code: AtomicU64::new(NO_ABORT),
        stop_code: AtomicU64::new(NO_ABORT),
        reset_notify: Notify::new(),
        stop_notify: Notify::new(),
        released: AtomicBool::new(false),
    });
    let monitor_env = OwnedEnv::new();
    if monitor_env.monitor(&resource, &owner).is_none() {
        resource.close();
        return Err(stream_error(
            operation,
            atoms::cancelled(),
            "stream owner is no longer available",
        ));
    }
    Ok(resource)
}

fn connection_value(
    connection: &ResourceArc<ConnectionResource>,
    operation: rustler::Atom,
) -> Result<iroh::endpoint::Connection, NativeError> {
    connection
        .connection()
        .ok_or_else(|| stream_error(operation, atoms::closed(), "connection is closed"))
}

#[rustler::nif]
fn stream_open_uni_start<'a>(
    env: Env<'a>,
    caller: LocalPid,
    owner: LocalPid,
    operation_ref: Term<'a>,
    connection: ResourceArc<ConnectionResource>,
) -> Term<'a> {
    let value = match connection_value(&connection, atoms::stream_open_uni()) {
        Ok(value) => value,
        Err(error) => return (atoms::error(), error).encode(env),
    };
    let resource_connection = connection;
    start_endpoint_operation(
        env,
        caller,
        operation_ref,
        atoms::stream_open_uni(),
        async move {
            let send = value.open_uni().await.map_err(|_| {
                stream_error(
                    atoms::stream_open_uni(),
                    atoms::closed(),
                    "unidirectional stream could not be opened",
                )
            })?;
            wrap_stream(
                Some(send),
                None,
                resource_connection,
                owner,
                atoms::stream_open_uni(),
            )
        },
    )
}

#[rustler::nif]
fn stream_open_bi_start<'a>(
    env: Env<'a>,
    caller: LocalPid,
    owner: LocalPid,
    operation_ref: Term<'a>,
    connection: ResourceArc<ConnectionResource>,
) -> Term<'a> {
    let value = match connection_value(&connection, atoms::stream_open_bi()) {
        Ok(value) => value,
        Err(error) => return (atoms::error(), error).encode(env),
    };
    let resource_connection = connection;
    start_endpoint_operation(
        env,
        caller,
        operation_ref,
        atoms::stream_open_bi(),
        async move {
            let (send, recv) = value.open_bi().await.map_err(|_| {
                stream_error(
                    atoms::stream_open_bi(),
                    atoms::closed(),
                    "bidirectional stream could not be opened",
                )
            })?;
            wrap_stream(
                Some(send),
                Some(recv),
                resource_connection,
                owner,
                atoms::stream_open_bi(),
            )
        },
    )
}

#[rustler::nif]
fn stream_accept_uni_start<'a>(
    env: Env<'a>,
    caller: LocalPid,
    owner: LocalPid,
    operation_ref: Term<'a>,
    connection: ResourceArc<ConnectionResource>,
) -> Term<'a> {
    let value = match connection_value(&connection, atoms::stream_accept_uni()) {
        Ok(value) => value,
        Err(error) => return (atoms::error(), error).encode(env),
    };
    let resource_connection = connection;
    start_endpoint_operation(
        env,
        caller,
        operation_ref,
        atoms::stream_accept_uni(),
        async move {
            let recv = value.accept_uni().await.map_err(|_| {
                stream_error(
                    atoms::stream_accept_uni(),
                    atoms::closed(),
                    "unidirectional stream could not be accepted",
                )
            })?;
            wrap_stream(
                None,
                Some(recv),
                resource_connection,
                owner,
                atoms::stream_accept_uni(),
            )
        },
    )
}

#[rustler::nif]
fn stream_accept_bi_start<'a>(
    env: Env<'a>,
    caller: LocalPid,
    owner: LocalPid,
    operation_ref: Term<'a>,
    connection: ResourceArc<ConnectionResource>,
) -> Term<'a> {
    let value = match connection_value(&connection, atoms::stream_accept_bi()) {
        Ok(value) => value,
        Err(error) => return (atoms::error(), error).encode(env),
    };
    let resource_connection = connection;
    start_endpoint_operation(
        env,
        caller,
        operation_ref,
        atoms::stream_accept_bi(),
        async move {
            let (send, recv) = value.accept_bi().await.map_err(|_| {
                stream_error(
                    atoms::stream_accept_bi(),
                    atoms::closed(),
                    "bidirectional stream could not be accepted",
                )
            })?;
            wrap_stream(
                Some(send),
                Some(recv),
                resource_connection,
                owner,
                atoms::stream_accept_bi(),
            )
        },
    )
}

fn take_send(
    stream: ResourceArc<StreamResource>,
    operation: rustler::Atom,
) -> Result<SendLease, NativeError> {
    if stream.send_closed.load(Ordering::Acquire) {
        return Err(stream_error(
            operation,
            atoms::closed(),
            "send half is closed",
        ));
    }
    if stream
        .send_busy
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return Err(stream_error(operation, atoms::busy(), "send half is busy"));
    }
    let value = stream.send.lock().ok().and_then(|mut value| value.take());
    match value {
        Some(value) => Ok(SendLease {
            resource: stream,
            stream: Some(value),
        }),
        None => {
            stream.send_busy.store(false, Ordering::Release);
            Err(stream_error(
                operation,
                atoms::closed(),
                "send half is unavailable",
            ))
        }
    }
}

fn take_recv(
    stream: ResourceArc<StreamResource>,
    operation: rustler::Atom,
) -> Result<RecvLease, NativeError> {
    if stream.recv_closed.load(Ordering::Acquire) {
        return Err(stream_error(
            operation,
            atoms::closed(),
            "receive half is closed",
        ));
    }
    if stream
        .recv_busy
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return Err(stream_error(
            operation,
            atoms::busy(),
            "receive half is busy",
        ));
    }
    let value = stream.recv.lock().ok().and_then(|mut value| value.take());
    match value {
        Some(value) => Ok(RecvLease {
            resource: stream,
            stream: Some(value),
        }),
        None => {
            stream.recv_busy.store(false, Ordering::Release);
            Err(stream_error(
                operation,
                atoms::closed(),
                "receive half is unavailable",
            ))
        }
    }
}

#[rustler::nif]
fn stream_send_start<'a>(
    env: Env<'a>,
    caller: LocalPid,
    operation_ref: Term<'a>,
    stream: ResourceArc<StreamResource>,
    data: Binary<'a>,
    send_all: bool,
    chunk_size: usize,
) -> Term<'a> {
    if data.is_empty() || chunk_size == 0 {
        return (
            atoms::error(),
            stream_error(
                atoms::stream_send(),
                atoms::invalid_argument(),
                "send data and chunk size must be positive",
            ),
        )
            .encode(env);
    }
    let mut lease = match take_send(stream, atoms::stream_send()) {
        Ok(lease) => lease,
        Err(error) => return (atoms::error(), error).encode(env),
    };
    let data = data.as_slice().to_vec();
    let queued = QueueGuard::new(data.len());
    start_endpoint_operation(
        env,
        caller,
        operation_ref,
        atoms::stream_send(),
        async move {
            let _queued = queued;
            let send_stream = lease.stream.as_mut().ok_or_else(|| {
                stream_error(
                    atoms::stream_send(),
                    atoms::closed(),
                    "send half is unavailable",
                )
            })?;
            let write = async {
                if send_all {
                    let mut written = 0;
                    while written < data.len() {
                        let end = (written + chunk_size).min(data.len());
                        send_stream
                            .write_all(&data[written..end])
                            .await
                            .map_err(|_| {
                                stream_error(
                                    atoms::stream_send(),
                                    atoms::peer_aborted(),
                                    "stream send failed",
                                )
                            })?;
                        written = end;
                    }
                    Ok(data.len())
                } else {
                    let end = chunk_size.min(data.len());
                    send_stream.write(&data[..end]).await.map_err(|_| {
                        stream_error(
                            atoms::stream_send(),
                            atoms::peer_aborted(),
                            "stream send failed",
                        )
                    })
                }
            };
            tokio::select! {
                result = write => result,
                _ = lease.resource.reset_notify.notified() => {
                    let code = lease.resource.reset_code.load(Ordering::Acquire);
                    if let Ok(code) = VarInt::from_u64(code) {
                        let _ignored = send_stream.reset(code);
                    }
                    Err(stream_error(
                        atoms::stream_send(), atoms::peer_aborted(), "send half was reset"
                    ))
                }
            }
        },
    )
}

#[rustler::nif]
fn stream_recv_start<'a>(
    env: Env<'a>,
    caller: LocalPid,
    operation_ref: Term<'a>,
    stream: ResourceArc<StreamResource>,
    max_bytes: usize,
) -> Term<'a> {
    if max_bytes == 0 || max_bytes > 16 * 1_024 * 1_024 {
        return (
            atoms::error(),
            stream_error(
                atoms::stream_recv(),
                atoms::invalid_argument(),
                "receive limit must be between 1 and 16777216 bytes",
            ),
        )
            .encode(env);
    }
    let mut lease = match take_recv(stream, atoms::stream_recv()) {
        Ok(lease) => lease,
        Err(error) => return (atoms::error(), error).encode(env),
    };
    start_endpoint_operation(
        env,
        caller,
        operation_ref,
        atoms::stream_recv(),
        async move {
            let recv_stream = lease.stream.as_mut().ok_or_else(|| {
                stream_error(
                    atoms::stream_recv(),
                    atoms::closed(),
                    "receive half is unavailable",
                )
            })?;
            tokio::select! {
                result = recv_stream.read_chunk(max_bytes) => {
                    result
                        .map(|value| value.map_or(ReadResult::Eof, |bytes| ReadResult::Data(bytes.to_vec())))
                        .map_err(|_| stream_error(
                            atoms::stream_recv(), atoms::peer_aborted(), "stream receive failed"
                        ))
                }
                _ = lease.resource.stop_notify.notified() => {
                    let code = lease.resource.stop_code.load(Ordering::Acquire);
                    if let Ok(code) = VarInt::from_u64(code) {
                        let _ignored = recv_stream.stop(code);
                    }
                    Err(stream_error(
                        atoms::stream_recv(), atoms::peer_aborted(), "receive half was stopped"
                    ))
                }
            }
        },
    )
}

fn validate_abort_code(code: u64, operation: rustler::Atom) -> Result<VarInt, NativeError> {
    if code > MAX_ABORT_CODE {
        return Err(stream_error(
            operation,
            atoms::invalid_argument(),
            "abort code exceeds QUIC varint range",
        ));
    }
    VarInt::from_u64(code).map_err(|_| {
        stream_error(
            operation,
            atoms::invalid_argument(),
            "abort code is invalid",
        )
    })
}

#[rustler::nif]
fn stream_finish(env: Env<'_>, stream: ResourceArc<StreamResource>) -> Term<'_> {
    if stream.send_busy.load(Ordering::Acquire) {
        return (
            atoms::error(),
            stream_error(atoms::stream_finish(), atoms::busy(), "send half is busy"),
        )
            .encode(env);
    }
    stream.send_closed.store(true, Ordering::Release);
    let result = stream
        .send
        .lock()
        .ok()
        .and_then(|mut value| value.take())
        .ok_or_else(|| {
            stream_error(
                atoms::stream_finish(),
                atoms::closed(),
                "send half is closed",
            )
        })
        .and_then(|mut value| {
            value.finish().map_err(|_| {
                stream_error(
                    atoms::stream_finish(),
                    atoms::closed(),
                    "send half is closed",
                )
            })
        });
    match result {
        Ok(()) => (atoms::ok(), atoms::ok()).encode(env),
        Err(error) => (atoms::error(), error).encode(env),
    }
}

#[rustler::nif]
fn stream_reset(env: Env<'_>, stream: ResourceArc<StreamResource>, code: u64) -> Term<'_> {
    if let Err(error) = validate_abort_code(code, atoms::stream_reset()) {
        return (atoms::error(), error).encode(env);
    }
    stream.request_reset(code);
    (atoms::ok(), atoms::ok()).encode(env)
}

#[rustler::nif]
fn stream_stop(env: Env<'_>, stream: ResourceArc<StreamResource>, code: u64) -> Term<'_> {
    if let Err(error) = validate_abort_code(code, atoms::stream_stop()) {
        return (atoms::error(), error).encode(env);
    }
    stream.request_stop(code);
    (atoms::ok(), atoms::ok()).encode(env)
}

#[rustler::nif]
fn stream_abort(stream: ResourceArc<StreamResource>, code: u64) -> bool {
    if code > MAX_ABORT_CODE {
        return false;
    }
    stream.request_reset(code);
    stream.request_stop(code);
    stream.close()
}

#[rustler::nif]
fn stream_info(env: Env<'_>, stream: ResourceArc<StreamResource>) -> Term<'_> {
    let send = stream
        .send
        .lock()
        .map(|value| value.is_some())
        .unwrap_or(false)
        || stream.send_busy.load(Ordering::Acquire);
    let recv = stream
        .recv
        .lock()
        .map(|value| value.is_some())
        .unwrap_or(false)
        || stream.recv_busy.load(Ordering::Acquire);
    let direction = if send && recv {
        atoms::bi()
    } else {
        atoms::uni()
    };
    (
        atoms::ok(),
        StreamInfo {
            id: stream.id,
            direction,
            send,
            recv,
            send_closed: stream.send_closed.load(Ordering::Acquire),
            recv_closed: stream.recv_closed.load(Ordering::Acquire),
        },
    )
        .encode(env)
}

struct DatagramPermit {
    connection: ResourceArc<ConnectionResource>,
    send: bool,
}

impl Drop for DatagramPermit {
    fn drop(&mut self) {
        if self.send {
            self.connection.finish_datagram_send();
        } else {
            self.connection.finish_datagram_recv();
        }
    }
}

#[rustler::nif]
fn datagram_send_start<'a>(
    env: Env<'a>,
    caller: LocalPid,
    operation_ref: Term<'a>,
    connection: ResourceArc<ConnectionResource>,
    data: Binary<'a>,
    wait_for_capacity: bool,
) -> Term<'a> {
    let value = match connection_value(&connection, atoms::datagram_send()) {
        Ok(value) => value,
        Err(error) => return (atoms::error(), error).encode(env),
    };
    let max_size = value.max_datagram_size().unwrap_or(0);
    if data.is_empty() || data.len() > max_size {
        return (
            atoms::error(),
            stream_error(
                atoms::datagram_send(),
                atoms::too_large(),
                "datagram is empty, unsupported, or exceeds the current maximum",
            ),
        )
            .encode(env);
    }
    if !connection.begin_datagram_send() {
        return (
            atoms::error(),
            stream_error(
                atoms::datagram_send(),
                atoms::busy(),
                "datagram sender is busy",
            ),
        )
            .encode(env);
    }
    let permit = DatagramPermit {
        connection,
        send: true,
    };
    let data = Bytes::copy_from_slice(data.as_slice());
    let queued = QueueGuard::new(data.len());
    start_endpoint_operation(
        env,
        caller,
        operation_ref,
        atoms::datagram_send(),
        async move {
            let _permit = permit;
            let _queued = queued;
            if wait_for_capacity {
                value.send_datagram_wait(data).await.map_err(|_| {
                    stream_error(
                        atoms::datagram_send(),
                        atoms::capacity(),
                        "datagram could not be queued",
                    )
                })?;
            } else {
                value.send_datagram(data).map_err(|_| {
                    stream_error(
                        atoms::datagram_send(),
                        atoms::capacity(),
                        "datagram send buffer has no capacity",
                    )
                })?;
            }
            Ok(atoms::ok())
        },
    )
}

#[rustler::nif]
fn datagram_recv_start<'a>(
    env: Env<'a>,
    caller: LocalPid,
    operation_ref: Term<'a>,
    connection: ResourceArc<ConnectionResource>,
) -> Term<'a> {
    let value = match connection_value(&connection, atoms::datagram_recv()) {
        Ok(value) => value,
        Err(error) => return (atoms::error(), error).encode(env),
    };
    if !connection.begin_datagram_recv() {
        return (
            atoms::error(),
            stream_error(
                atoms::datagram_recv(),
                atoms::busy(),
                "datagram receiver is busy",
            ),
        )
            .encode(env);
    }
    let permit = DatagramPermit {
        connection,
        send: false,
    };
    start_endpoint_operation(
        env,
        caller,
        operation_ref,
        atoms::datagram_recv(),
        async move {
            let _permit = permit;
            value
                .read_datagram()
                .await
                .map(|bytes| BinaryResult(bytes.to_vec()))
                .map_err(|_| {
                    stream_error(
                        atoms::datagram_recv(),
                        atoms::closed(),
                        "datagram receive failed",
                    )
                })
        },
    )
}

#[rustler::nif]
fn datagram_info(env: Env<'_>, connection: ResourceArc<ConnectionResource>) -> Term<'_> {
    match connection_value(&connection, atoms::datagram_info()) {
        Ok(value) => (
            atoms::ok(),
            DatagramInfo {
                max_size: value.max_datagram_size(),
                send_buffer_space: value.datagram_send_buffer_space(),
            },
        )
            .encode(env),
        Err(error) => (atoms::error(), error).encode(env),
    }
}

#[rustler::nif]
fn stream_snapshot(env: Env<'_>) -> Term<'_> {
    (
        atoms::ok(),
        StreamSnapshot {
            active_streams: ACTIVE_STREAMS.load(Ordering::Acquire),
            queued_bytes: QUEUED_BYTES.load(Ordering::Acquire),
            peak_queued_bytes: PEAK_QUEUED_BYTES.load(Ordering::Acquire),
        },
    )
        .encode(env)
}
