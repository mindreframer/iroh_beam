use std::collections::HashSet;
use std::str::FromStr;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use iroh::endpoint::Connection;
use iroh::{EndpointAddr, EndpointId, TransportAddr};
use rustler::{Atom, Encoder, Env, LocalPid, Monitor, OwnedEnv, Resource, ResourceArc, Term};

use crate::endpoint::{start_endpoint_operation, EndpointResource};
use crate::identity::build_addr;
use crate::{atoms, native_error, NativeError};

static ACTIVE_CONNECTIONS: AtomicUsize = AtomicUsize::new(0);

#[derive(rustler::NifMap)]
struct NativeDialTarget {
    endpoint_id: String,
    relay_urls: Vec<String>,
    ip_addrs: Vec<String>,
}

#[derive(Clone, Copy)]
enum ConnectionRole {
    Outgoing,
    Incoming,
}

pub(crate) struct ConnectionResource {
    connection: Connection,
    endpoint: ResourceArc<EndpointResource>,
    remote_id: String,
    alpn: String,
    role: ConnectionRole,
    released: AtomicBool,
}

impl ConnectionResource {
    fn close(&self) -> bool {
        if !self.released.swap(true, Ordering::AcqRel) {
            self.connection.close(0u32.into(), b"");
            self.endpoint.release_connection();
            ACTIVE_CONNECTIONS.fetch_sub(1, Ordering::AcqRel);
            true
        } else {
            false
        }
    }
}

impl Drop for ConnectionResource {
    fn drop(&mut self) {
        self.close();
    }
}

#[rustler::resource_impl]
impl Resource for ConnectionResource {
    fn down(&self, _env: Env<'_>, _pid: LocalPid, _monitor: Monitor) {
        self.close();
    }
}

struct AcceptPermit(ResourceArc<EndpointResource>);

impl Drop for AcceptPermit {
    fn drop(&mut self) {
        self.0.finish_accept();
    }
}

#[derive(rustler::NifMap)]
struct ConnectionInfo {
    remote_id: String,
    alpn: String,
    side: Atom,
    role: Atom,
    stable_id: usize,
    closed: bool,
}

#[derive(rustler::NifMap)]
struct PathInfo {
    kind: Atom,
    remote: String,
    rtt_microseconds: u64,
    selected: bool,
}

#[derive(rustler::NifMap)]
struct ConnectionSnapshot {
    active_connections: usize,
}

fn connection_error(category: Atom, operation: Atom, message: &'static str) -> NativeError {
    native_error(category, operation, message)
}

fn parse_target(target: NativeDialTarget) -> Result<EndpointAddr, NativeError> {
    let endpoint_id = EndpointId::from_str(&target.endpoint_id).map_err(|_| {
        connection_error(
            atoms::invalid_argument(),
            atoms::connection_connect(),
            "dial target endpoint ID is invalid",
        )
    })?;
    build_addr(endpoint_id.as_bytes(), target.relay_urls, target.ip_addrs).map_err(|_| {
        connection_error(
            atoms::invalid_argument(),
            atoms::connection_connect(),
            "dial target address is invalid",
        )
    })
}

fn wrap_connection(
    connection: Connection,
    endpoint: ResourceArc<EndpointResource>,
    owner: LocalPid,
    role: ConnectionRole,
    operation: Atom,
) -> Result<ResourceArc<ConnectionResource>, NativeError> {
    if !endpoint.claim_connection() {
        connection.close(0u32.into(), b"");
        return Err(connection_error(
            atoms::capacity(),
            operation,
            "endpoint connection limit is reached",
        ));
    }
    ACTIVE_CONNECTIONS.fetch_add(1, Ordering::AcqRel);
    let resource = ResourceArc::new(ConnectionResource {
        remote_id: connection.remote_id().to_string(),
        alpn: String::from_utf8_lossy(connection.alpn()).into_owned(),
        connection,
        endpoint,
        role,
        released: AtomicBool::new(false),
    });
    let monitor_env = OwnedEnv::new();
    if monitor_env.monitor(&resource, &owner).is_none() {
        resource.close();
        return Err(connection_error(
            atoms::cancelled(),
            operation,
            "connection owner is no longer available",
        ));
    }
    Ok(resource)
}

#[rustler::nif]
fn connection_connect_start<'a>(
    env: Env<'a>,
    caller: LocalPid,
    owner: LocalPid,
    operation_ref: Term<'a>,
    endpoint: ResourceArc<EndpointResource>,
    target: NativeDialTarget,
    alpn: String,
) -> Term<'a> {
    if alpn.is_empty() || alpn.len() > 255 || alpn.as_bytes().contains(&0) {
        return (
            atoms::error(),
            connection_error(
                atoms::invalid_argument(),
                atoms::connection_connect(),
                "ALPN is invalid",
            ),
        )
            .encode(env);
    }
    let target = match parse_target(target) {
        Ok(target) => target,
        Err(error) => return (atoms::error(), error).encode(env),
    };
    if target.is_empty() && !endpoint.address_lookup_enabled() {
        return (
            atoms::error(),
            connection_error(
                atoms::resolution(),
                atoms::connection_connect(),
                "endpoint ID has no configured address information",
            ),
        )
            .encode(env);
    }
    let value = match endpoint.endpoint() {
        Some(value) => value,
        None => {
            return (
                atoms::error(),
                connection_error(
                    atoms::closed(),
                    atoms::connection_connect(),
                    "endpoint is closed",
                ),
            )
                .encode(env)
        }
    };
    let operation_endpoint = endpoint.clone();
    let operation_owner = owner;
    start_endpoint_operation(
        env,
        caller,
        operation_ref,
        atoms::connection_connect(),
        async move {
            let connection = value.connect(target, alpn.as_bytes()).await.map_err(|_| {
                connection_error(
                    atoms::refused(),
                    atoms::connection_connect(),
                    "connection handshake failed",
                )
            })?;
            wrap_connection(
                connection,
                operation_endpoint,
                operation_owner,
                ConnectionRole::Outgoing,
                atoms::connection_connect(),
            )
        },
    )
}

#[rustler::nif]
fn connection_accept_start<'a>(
    env: Env<'a>,
    caller: LocalPid,
    owner: LocalPid,
    operation_ref: Term<'a>,
    endpoint: ResourceArc<EndpointResource>,
    allow_all: bool,
    allowed_ids: Vec<String>,
) -> Term<'a> {
    let allowed_ids: HashSet<String> = match allowed_ids
        .into_iter()
        .map(|value| EndpointId::from_str(&value).map(|id| id.to_string()))
        .collect::<Result<_, _>>()
    {
        Ok(allowed_ids) => allowed_ids,
        Err(_) => {
            return (
                atoms::error(),
                connection_error(
                    atoms::invalid_argument(),
                    atoms::connection_accept(),
                    "peer allowlist is invalid",
                ),
            )
                .encode(env)
        }
    };
    if !endpoint.begin_accept() {
        return (
            atoms::error(),
            connection_error(
                atoms::busy(),
                atoms::connection_accept(),
                "an endpoint accept is already pending",
            ),
        )
            .encode(env);
    }
    let permit = AcceptPermit(endpoint.clone());
    let value = match endpoint.endpoint() {
        Some(value) => value,
        None => {
            drop(permit);
            return (
                atoms::error(),
                connection_error(
                    atoms::closed(),
                    atoms::connection_accept(),
                    "endpoint is closed",
                ),
            )
                .encode(env);
        }
    };
    let operation_endpoint = endpoint;
    start_endpoint_operation(
        env,
        caller,
        operation_ref,
        atoms::connection_accept(),
        async move {
            let _permit = permit;
            let incoming = value.accept().await.ok_or_else(|| {
                connection_error(
                    atoms::closed(),
                    atoms::connection_accept(),
                    "endpoint closed while accepting",
                )
            })?;
            let accepting = incoming.accept().map_err(|_| {
                connection_error(
                    atoms::refused(),
                    atoms::connection_accept(),
                    "incoming connection was refused",
                )
            })?;
            let connection = accepting.await.map_err(|_| {
                connection_error(
                    atoms::refused(),
                    atoms::connection_accept(),
                    "incoming handshake failed",
                )
            })?;
            let remote_id = connection.remote_id().to_string();
            if !allow_all && !allowed_ids.contains(&remote_id) {
                connection.close(0u32.into(), b"");
                return Err(connection_error(
                    atoms::unauthorized(),
                    atoms::connection_accept(),
                    "authenticated peer is not allowed",
                ));
            }
            wrap_connection(
                connection,
                operation_endpoint,
                owner,
                ConnectionRole::Incoming,
                atoms::connection_accept(),
            )
        },
    )
}

fn info_value(resource: &ConnectionResource) -> ConnectionInfo {
    ConnectionInfo {
        remote_id: resource.remote_id.clone(),
        alpn: resource.alpn.clone(),
        side: if resource.connection.side().is_client() {
            atoms::client()
        } else {
            atoms::server()
        },
        role: match resource.role {
            ConnectionRole::Outgoing => atoms::outgoing(),
            ConnectionRole::Incoming => atoms::incoming(),
        },
        stable_id: resource.connection.stable_id(),
        closed: resource.released.load(Ordering::Acquire)
            || resource.connection.close_reason().is_some(),
    }
}

#[rustler::nif]
fn connection_info(env: Env<'_>, connection: ResourceArc<ConnectionResource>) -> Term<'_> {
    (atoms::ok(), info_value(&connection)).encode(env)
}

#[rustler::nif]
fn connection_path(env: Env<'_>, connection: ResourceArc<ConnectionResource>) -> Term<'_> {
    let paths = connection.connection.paths();
    let selected = paths.iter().find(|path| path.is_selected());
    let info = selected.map(|path| PathInfo {
        kind: if path.is_ip() {
            atoms::direct()
        } else if path.is_relay() {
            atoms::relay()
        } else {
            atoms::unknown()
        },
        remote: match path.remote_addr() {
            TransportAddr::Ip(addr) => addr.to_string(),
            TransportAddr::Relay(url) => url.to_string(),
            other => other.to_string(),
        },
        rtt_microseconds: path.rtt().as_micros().try_into().unwrap_or(u64::MAX),
        selected: true,
    });
    (atoms::ok(), info).encode(env)
}

#[rustler::nif]
fn connection_close(connection: ResourceArc<ConnectionResource>) -> bool {
    connection.close()
}

#[rustler::nif]
fn connection_closed_start<'a>(
    env: Env<'a>,
    caller: LocalPid,
    operation_ref: Term<'a>,
    connection: ResourceArc<ConnectionResource>,
) -> Term<'a> {
    let value = connection.connection.clone();
    start_endpoint_operation(
        env,
        caller,
        operation_ref,
        atoms::connection_closed(),
        async move {
            let _reason = value.closed().await;
            connection.close();
            Ok(atoms::closed())
        },
    )
}

#[rustler::nif]
fn connection_close_reason(env: Env<'_>, connection: ResourceArc<ConnectionResource>) -> Term<'_> {
    if connection.connection.close_reason().is_some() || connection.released.load(Ordering::Acquire)
    {
        (atoms::ok(), atoms::closed()).encode(env)
    } else {
        (atoms::ok(), rustler::types::atom::nil()).encode(env)
    }
}

#[rustler::nif]
fn connection_snapshot(env: Env<'_>) -> Term<'_> {
    (
        atoms::ok(),
        ConnectionSnapshot {
            active_connections: ACTIVE_CONNECTIONS.load(Ordering::Acquire),
        },
    )
        .encode(env)
}
