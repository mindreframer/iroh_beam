use std::collections::HashSet;
use std::net::SocketAddr;
use std::str::FromStr;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock};

use iroh::endpoint::presets;
use iroh::{Endpoint, RelayConfig, RelayMap, RelayMode, RelayUrl, Watcher};
use rustler::{Atom, Encoder, Env, LocalPid, Monitor, OwnedEnv, Resource, ResourceArc, Term};

use crate::identity::SecretKeyResource;
use crate::{
    atoms, native_error, runtime, NativeError, OperationResource, ACTIVE_OPERATIONS, COMPLETED,
    RUNNING,
};

const MAX_ALPNS: usize = 16;
const MAX_ALPN_BYTES: usize = 255;
const MAX_BIND_ADDRS: usize = 8;
const MAX_RELAYS: usize = 8;
const MAX_TOKEN_BYTES: usize = 4 * 1_024;
static ACTIVE_IDENTITIES: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
static ACTIVE_ENDPOINTS: AtomicUsize = AtomicUsize::new(0);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ProfileKind {
    N0,
    Direct,
    NoRelay,
    Custom,
}

impl ProfileKind {
    fn atom(self) -> Atom {
        match self {
            Self::N0 => atoms::n0(),
            Self::Direct => atoms::direct(),
            Self::NoRelay => atoms::no_relay(),
            Self::Custom => atoms::custom(),
        }
    }

    fn relay_enabled(self) -> bool {
        matches!(self, Self::N0 | Self::Custom)
    }

    fn address_lookup_enabled(self) -> bool {
        matches!(self, Self::N0 | Self::NoRelay)
    }
}

#[derive(rustler::NifMap)]
struct NativeRelay {
    url: String,
    token: Option<String>,
}

#[derive(rustler::NifMap)]
struct NativeEndpointOptions {
    profile: Atom,
    alpns: Vec<String>,
    bind_addrs: Vec<String>,
    relays: Vec<NativeRelay>,
    max_connections: usize,
    max_pending_accepts: usize,
    direct_ip: bool,
}

struct BindConfig {
    profile: ProfileKind,
    alpns: Vec<Vec<u8>>,
    bind_addrs: Vec<SocketAddr>,
    relay_map: Option<RelayMap>,
    direct_ip: bool,
}

pub(crate) struct EndpointResource {
    endpoint: Mutex<Option<Endpoint>>,
    endpoint_id: String,
    profile: ProfileKind,
    direct_ip: bool,
    released: AtomicBool,
    pending_accepts: AtomicUsize,
    max_pending_accepts: usize,
    active_connections: AtomicUsize,
    max_connections: usize,
}

impl EndpointResource {
    pub(crate) fn endpoint(&self) -> Option<Endpoint> {
        self.endpoint
            .lock()
            .ok()
            .and_then(|value| value.as_ref().cloned())
    }

    pub(crate) fn address_lookup_enabled(&self) -> bool {
        self.profile.address_lookup_enabled()
    }

    pub(crate) fn begin_accept(&self) -> bool {
        self.pending_accepts
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
                (count < self.max_pending_accepts).then_some(count + 1)
            })
            .is_ok()
    }

    pub(crate) fn finish_accept(&self) {
        let _updated =
            self.pending_accepts
                .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
                    count.checked_sub(1)
                });
    }

    pub(crate) fn claim_connection(&self) -> bool {
        self.active_connections
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
                (count < self.max_connections).then_some(count + 1)
            })
            .is_ok()
    }

    pub(crate) fn release_connection(&self) {
        let _updated =
            self.active_connections
                .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
                    count.checked_sub(1)
                });
    }

    fn take_endpoint(&self) -> Option<Endpoint> {
        self.endpoint.lock().ok().and_then(|mut value| value.take())
    }

    fn release_identity(&self) {
        if !self.released.swap(true, Ordering::AcqRel) {
            if let Ok(mut identities) = active_identities().lock() {
                identities.remove(&self.endpoint_id);
            }
            ACTIVE_ENDPOINTS.fetch_sub(1, Ordering::AcqRel);
        }
    }

    fn abort(&self) -> bool {
        let endpoint = self.take_endpoint();
        self.release_identity();
        endpoint.is_some()
    }
}

impl Drop for EndpointResource {
    fn drop(&mut self) {
        self.abort();
    }
}

#[rustler::resource_impl]
impl Resource for EndpointResource {
    fn down(&self, _env: Env<'_>, _pid: LocalPid, _monitor: Monitor) {
        self.abort();
    }
}

#[derive(rustler::NifMap)]
struct EndpointInfo {
    endpoint_id: String,
    relay_urls: Vec<String>,
    ip_addrs: Vec<String>,
    bound_sockets: Vec<String>,
    profile: Atom,
    relay_enabled: bool,
    address_lookup_enabled: bool,
    direct_ip: bool,
    online: bool,
    closed: bool,
}

#[derive(rustler::NifMap)]
struct EndpointSnapshot {
    active_endpoints: usize,
    active_identities: usize,
    active_operations: usize,
}

fn active_identities() -> &'static Mutex<HashSet<String>> {
    ACTIVE_IDENTITIES.get_or_init(|| Mutex::new(HashSet::new()))
}

fn endpoint_error(category: Atom, operation: Atom, message: &'static str) -> NativeError {
    native_error(category, operation, message)
}

fn parse_config(
    profile: Atom,
    alpns: Vec<String>,
    bind_addrs: Vec<String>,
    relays: Vec<NativeRelay>,
    direct_ip: bool,
) -> Result<BindConfig, NativeError> {
    if alpns.is_empty() || alpns.len() > MAX_ALPNS {
        return Err(endpoint_error(
            atoms::invalid_argument(),
            atoms::endpoint_bind(),
            "at least one bounded ALPN is required",
        ));
    }
    if alpns
        .iter()
        .any(|alpn| alpn.is_empty() || alpn.len() > MAX_ALPN_BYTES || alpn.as_bytes().contains(&0))
    {
        return Err(endpoint_error(
            atoms::invalid_argument(),
            atoms::endpoint_bind(),
            "ALPN values must contain 1 to 255 non-NUL bytes",
        ));
    }
    let mut unique_alpns = HashSet::new();
    if alpns.iter().any(|alpn| !unique_alpns.insert(alpn)) {
        return Err(endpoint_error(
            atoms::invalid_argument(),
            atoms::endpoint_bind(),
            "ALPN values must be unique",
        ));
    }

    if bind_addrs.len() > MAX_BIND_ADDRS {
        return Err(endpoint_error(
            atoms::invalid_argument(),
            atoms::endpoint_bind(),
            "too many bind addresses",
        ));
    }
    let bind_addrs: Vec<SocketAddr> = bind_addrs
        .iter()
        .map(|value| SocketAddr::from_str(value))
        .collect::<Result<_, _>>()
        .map_err(|_| {
            endpoint_error(
                atoms::invalid_argument(),
                atoms::endpoint_bind(),
                "bind address is invalid",
            )
        })?;
    let mut families = HashSet::new();
    if bind_addrs
        .iter()
        .any(|addr| !families.insert(addr.is_ipv4()))
    {
        return Err(endpoint_error(
            atoms::invalid_argument(),
            atoms::endpoint_bind(),
            "only one bind address per IP family is supported",
        ));
    }

    let profile = if profile == atoms::n0() {
        ProfileKind::N0
    } else if profile == atoms::direct() {
        ProfileKind::Direct
    } else if profile == atoms::no_relay() {
        ProfileKind::NoRelay
    } else if profile == atoms::custom() {
        ProfileKind::Custom
    } else {
        return Err(endpoint_error(
            atoms::invalid_argument(),
            atoms::endpoint_bind(),
            "network profile is invalid",
        ));
    };

    let relay_map = if profile == ProfileKind::Custom {
        if relays.is_empty() || relays.len() > MAX_RELAYS {
            return Err(endpoint_error(
                atoms::invalid_argument(),
                atoms::endpoint_bind(),
                "custom profile requires one to eight relays",
            ));
        }
        let mut configs = Vec::with_capacity(relays.len());
        for relay in relays {
            let url = RelayUrl::from_str(&relay.url).map_err(|_| {
                endpoint_error(
                    atoms::invalid_argument(),
                    atoms::endpoint_bind(),
                    "custom relay URL is invalid",
                )
            })?;
            if !matches!(url.scheme(), "http" | "https")
                || url.host_str().is_none()
                || !url.username().is_empty()
                || url.password().is_some()
                || url.query().is_some()
                || url.fragment().is_some()
            {
                return Err(endpoint_error(
                    atoms::invalid_argument(),
                    atoms::endpoint_bind(),
                    "custom relay URL must be HTTP(S) without credentials",
                ));
            }
            let mut config = RelayConfig::from(url);
            if let Some(token) = relay.token {
                if token.is_empty() || token.len() > MAX_TOKEN_BYTES || token.contains(['\r', '\n'])
                {
                    return Err(endpoint_error(
                        atoms::invalid_argument(),
                        atoms::endpoint_bind(),
                        "custom relay token is invalid",
                    ));
                }
                config = config.with_auth_token(token);
            }
            configs.push(config);
        }
        Some(configs.into_iter().collect())
    } else {
        if !relays.is_empty() {
            return Err(endpoint_error(
                atoms::invalid_argument(),
                atoms::endpoint_bind(),
                "relay records require the custom profile",
            ));
        }
        None
    };

    if !direct_ip && !bind_addrs.is_empty() {
        return Err(endpoint_error(
            atoms::invalid_argument(),
            atoms::endpoint_bind(),
            "bind addresses require direct IP transports",
        ));
    }

    Ok(BindConfig {
        profile,
        alpns: alpns.into_iter().map(String::into_bytes).collect(),
        bind_addrs,
        relay_map,
        direct_ip,
    })
}

fn reserve_identity(endpoint_id: &str) -> Result<(), NativeError> {
    let mut identities = active_identities().lock().map_err(|_| {
        endpoint_error(
            atoms::internal(),
            atoms::endpoint_bind(),
            "endpoint identity registry is unavailable",
        )
    })?;
    if !identities.insert(endpoint_id.to_owned()) {
        return Err(endpoint_error(
            atoms::duplicate_identity(),
            atoms::endpoint_bind(),
            "endpoint identity is already active in this VM",
        ));
    }
    Ok(())
}

fn release_reserved_identity(endpoint_id: &str) {
    if let Ok(mut identities) = active_identities().lock() {
        identities.remove(endpoint_id);
    }
}

fn endpoint_builder(
    config: BindConfig,
    secret_key: iroh::SecretKey,
) -> Result<iroh::endpoint::Builder, NativeError> {
    let mut builder = match config.profile {
        ProfileKind::N0 => Endpoint::builder(presets::N0),
        ProfileKind::Direct => Endpoint::builder(presets::Minimal)
            .relay_mode(RelayMode::Disabled)
            .clear_address_lookup(),
        ProfileKind::NoRelay => Endpoint::builder(presets::N0DisableRelay),
        ProfileKind::Custom => Endpoint::builder(presets::Minimal)
            .relay_mode(RelayMode::Custom(config.relay_map.ok_or_else(|| {
                endpoint_error(
                    atoms::internal(),
                    atoms::endpoint_bind(),
                    "custom relay configuration is unavailable",
                )
            })?))
            .clear_address_lookup(),
    }
    .secret_key(secret_key)
    .alpns(config.alpns);

    if !config.direct_ip {
        builder = builder.clear_ip_transports();
    } else if !config.bind_addrs.is_empty() {
        builder = builder.clear_ip_transports();
        for bind_addr in config.bind_addrs {
            builder = builder.bind_addr(bind_addr).map_err(|_| {
                endpoint_error(
                    atoms::invalid_argument(),
                    atoms::endpoint_bind(),
                    "bind address configuration is invalid",
                )
            })?;
        }
    }
    Ok(builder)
}

fn send_operation_result<T: Encoder>(
    mut owned_env: OwnedEnv,
    caller: LocalPid,
    saved_ref: rustler::env::SavedTerm,
    result: Result<T, NativeError>,
) -> OwnedEnv {
    let _send_result = owned_env.send_and_clear(&caller, |message_env| {
        let result = match result {
            Ok(value) => (atoms::ok(), value).encode(message_env),
            Err(error) => (atoms::error(), error).encode(message_env),
        };
        (atoms::native_module(), saved_ref.load(message_env), result).encode(message_env)
    });
    owned_env
}

#[rustler::nif]
fn endpoint_bind_start<'a>(
    env: Env<'a>,
    caller: LocalPid,
    operation_ref: Term<'a>,
    secret_key: ResourceArc<SecretKeyResource>,
    options: NativeEndpointOptions,
) -> Term<'a> {
    let runtime = match runtime() {
        Ok(runtime) => runtime,
        Err(error) => return (atoms::error(), error).encode(env),
    };
    let profile = options.profile;
    let direct_ip = options.direct_ip;
    if options.max_connections == 0
        || options.max_connections > 1_000_000
        || options.max_pending_accepts == 0
        || options.max_pending_accepts > 1_024
    {
        return (
            atoms::error(),
            endpoint_error(
                atoms::invalid_argument(),
                atoms::endpoint_bind(),
                "endpoint limits are outside the supported range",
            ),
        )
            .encode(env);
    }
    let max_connections = options.max_connections;
    let max_pending_accepts = options.max_pending_accepts;
    let config = match parse_config(
        options.profile,
        options.alpns,
        options.bind_addrs,
        options.relays,
        options.direct_ip,
    ) {
        Ok(config) => config,
        Err(error) => return (atoms::error(), error).encode(env),
    };
    let endpoint_id = secret_key.key.public().to_string();
    if let Err(error) = reserve_identity(&endpoint_id) {
        return (atoms::error(), error).encode(env);
    }
    let builder = match endpoint_builder(config, secret_key.key.clone()) {
        Ok(builder) => builder,
        Err(error) => {
            release_reserved_identity(&endpoint_id);
            return (atoms::error(), error).encode(env);
        }
    };

    let operation = ResourceArc::new(OperationResource::new());
    let operation_monitor = match operation.monitor(Some(env), &caller) {
        Some(monitor) => monitor,
        None => {
            release_reserved_identity(&endpoint_id);
            return (
                atoms::error(),
                endpoint_error(
                    atoms::cancelled(),
                    atoms::endpoint_bind(),
                    "endpoint owner is no longer available",
                ),
            )
                .encode(env);
        }
    };
    let task_operation = operation.clone();
    let mut owned_env = OwnedEnv::new();
    let saved_ref = owned_env.save(operation_ref);
    let profile = if profile == atoms::n0() {
        ProfileKind::N0
    } else if profile == atoms::direct() {
        ProfileKind::Direct
    } else if profile == atoms::no_relay() {
        ProfileKind::NoRelay
    } else {
        ProfileKind::Custom
    };
    ACTIVE_OPERATIONS.fetch_add(1, Ordering::AcqRel);

    let mut bind_task = runtime.spawn(builder.bind());
    runtime.spawn(async move {
        let bind_result = tokio::select! {
            result = &mut bind_task => Some(result),
            _ = task_operation.cancelled.notified() => {
                bind_task.abort();
                let _cancelled = bind_task.await;
                None
            },
        };

        let should_complete = task_operation
            .state
            .compare_exchange(RUNNING, COMPLETED, Ordering::AcqRel, Ordering::Acquire)
            .is_ok();

        if should_complete {
            let result = match bind_result {
                Some(Ok(Ok(endpoint))) => {
                    ACTIVE_ENDPOINTS.fetch_add(1, Ordering::AcqRel);
                    let endpoint_resource = ResourceArc::new(EndpointResource {
                        endpoint: Mutex::new(Some(endpoint)),
                        endpoint_id: endpoint_id.clone(),
                        profile,
                        direct_ip,
                        released: AtomicBool::new(false),
                        pending_accepts: AtomicUsize::new(0),
                        max_pending_accepts,
                        active_connections: AtomicUsize::new(0),
                        max_connections,
                    });
                    if owned_env.monitor(&endpoint_resource, &caller).is_some() {
                        Ok(endpoint_resource)
                    } else {
                        endpoint_resource.abort();
                        Err(endpoint_error(
                            atoms::cancelled(),
                            atoms::endpoint_bind(),
                            "endpoint owner is no longer available",
                        ))
                    }
                }
                Some(Ok(Err(_))) => {
                    release_reserved_identity(&endpoint_id);
                    Err(endpoint_error(
                        atoms::bind_failed(),
                        atoms::endpoint_bind(),
                        "endpoint could not bind",
                    ))
                }
                Some(Err(_)) => {
                    release_reserved_identity(&endpoint_id);
                    Err(endpoint_error(
                        atoms::internal(),
                        atoms::endpoint_bind(),
                        "endpoint bind failed internally",
                    ))
                }
                None => {
                    release_reserved_identity(&endpoint_id);
                    Err(endpoint_error(
                        atoms::cancelled(),
                        atoms::endpoint_bind(),
                        "endpoint bind was cancelled",
                    ))
                }
            };
            owned_env = send_operation_result(owned_env, caller, saved_ref, result);
        } else {
            release_reserved_identity(&endpoint_id);
        }

        let _demonitored = owned_env.demonitor(&task_operation, &operation_monitor);
        ACTIVE_OPERATIONS.fetch_sub(1, Ordering::AcqRel);
    });

    (atoms::ok(), operation).encode(env)
}

fn endpoint_info_value(endpoint: &ResourceArc<EndpointResource>) -> EndpointInfo {
    let profile = endpoint.profile;
    let maybe_endpoint = endpoint
        .endpoint
        .lock()
        .ok()
        .and_then(|value| value.as_ref().cloned());
    match maybe_endpoint {
        Some(value) => {
            let addr = value.addr();
            let online = if profile.relay_enabled() {
                value
                    .home_relay_status()
                    .get()
                    .iter()
                    .any(|status| status.is_connected())
            } else {
                !value.is_closed()
            };
            EndpointInfo {
                endpoint_id: endpoint.endpoint_id.clone(),
                relay_urls: addr.relay_urls().map(ToString::to_string).collect(),
                ip_addrs: addr.ip_addrs().map(ToString::to_string).collect(),
                bound_sockets: value
                    .bound_sockets()
                    .into_iter()
                    .map(|addr| addr.to_string())
                    .collect(),
                profile: profile.atom(),
                relay_enabled: profile.relay_enabled(),
                address_lookup_enabled: profile.address_lookup_enabled(),
                direct_ip: endpoint.direct_ip,
                online,
                closed: value.is_closed(),
            }
        }
        None => EndpointInfo {
            endpoint_id: endpoint.endpoint_id.clone(),
            relay_urls: Vec::new(),
            ip_addrs: Vec::new(),
            bound_sockets: Vec::new(),
            profile: profile.atom(),
            relay_enabled: profile.relay_enabled(),
            address_lookup_enabled: profile.address_lookup_enabled(),
            direct_ip: endpoint.direct_ip,
            online: false,
            closed: true,
        },
    }
}

#[rustler::nif]
fn endpoint_info(env: Env<'_>, endpoint: ResourceArc<EndpointResource>) -> Term<'_> {
    (atoms::ok(), endpoint_info_value(&endpoint)).encode(env)
}

#[rustler::nif]
fn endpoint_abort(endpoint: ResourceArc<EndpointResource>) -> bool {
    endpoint.abort()
}

#[rustler::nif]
fn endpoint_close_start<'a>(
    env: Env<'a>,
    caller: LocalPid,
    operation_ref: Term<'a>,
    endpoint: ResourceArc<EndpointResource>,
) -> Term<'a> {
    start_endpoint_operation(
        env,
        caller,
        operation_ref,
        atoms::endpoint_close(),
        async move {
            if let Some(value) = endpoint.take_endpoint() {
                value.close().await;
            }
            endpoint.release_identity();
            Ok(atoms::closed())
        },
    )
}

#[rustler::nif]
fn endpoint_await_online_start<'a>(
    env: Env<'a>,
    caller: LocalPid,
    operation_ref: Term<'a>,
    endpoint: ResourceArc<EndpointResource>,
) -> Term<'a> {
    let profile = endpoint.profile;
    let value = endpoint
        .endpoint
        .lock()
        .ok()
        .and_then(|value| value.as_ref().cloned());
    start_endpoint_operation(
        env,
        caller,
        operation_ref,
        atoms::endpoint_online(),
        async move {
            let value = value.ok_or_else(|| {
                endpoint_error(
                    atoms::closed(),
                    atoms::endpoint_online(),
                    "endpoint is closed",
                )
            })?;
            if profile.relay_enabled() {
                tokio::select! {
                    () = value.online() => Ok(atoms::ok()),
                    () = value.closed() => Err(endpoint_error(
                        atoms::closed(), atoms::endpoint_online(), "endpoint closed before becoming online"
                    )),
                }
            } else if value.is_closed() {
                Err(endpoint_error(
                    atoms::closed(),
                    atoms::endpoint_online(),
                    "endpoint is closed",
                ))
            } else {
                Ok(atoms::ok())
            }
        },
    )
}

pub(crate) fn start_endpoint_operation<'a, F, T>(
    env: Env<'a>,
    caller: LocalPid,
    operation_ref: Term<'a>,
    operation_name: Atom,
    future: F,
) -> Term<'a>
where
    F: std::future::Future<Output = Result<T, NativeError>> + Send + 'static,
    T: Encoder + Send + 'static,
{
    let runtime = match runtime() {
        Ok(runtime) => runtime,
        Err(error) => return (atoms::error(), error).encode(env),
    };
    let operation = ResourceArc::new(OperationResource::new());
    let monitor = match operation.monitor(Some(env), &caller) {
        Some(monitor) => monitor,
        None => {
            return (
                atoms::error(),
                endpoint_error(
                    atoms::cancelled(),
                    operation_name,
                    "caller is no longer available",
                ),
            )
                .encode(env)
        }
    };
    let task_operation = operation.clone();
    let mut owned_env = OwnedEnv::new();
    let saved_ref = owned_env.save(operation_ref);
    ACTIVE_OPERATIONS.fetch_add(1, Ordering::AcqRel);

    let mut future_task = runtime.spawn(future);
    runtime.spawn(async move {
        let result = tokio::select! {
            result = &mut future_task => Some(result),
            _ = task_operation.cancelled.notified() => {
                future_task.abort();
                let _cancelled = future_task.await;
                None
            },
        };
        let should_complete = task_operation
            .state
            .compare_exchange(RUNNING, COMPLETED, Ordering::AcqRel, Ordering::Acquire)
            .is_ok();
        if should_complete {
            let result = match result {
                Some(Ok(result)) => result,
                Some(Err(_)) => Err(endpoint_error(
                    atoms::internal(),
                    operation_name,
                    "endpoint operation failed internally",
                )),
                None => Err(endpoint_error(
                    atoms::cancelled(),
                    operation_name,
                    "operation was cancelled",
                )),
            };
            owned_env = send_operation_result(owned_env, caller, saved_ref, result);
        }
        let _demonitored = owned_env.demonitor(&task_operation, &monitor);
        ACTIVE_OPERATIONS.fetch_sub(1, Ordering::AcqRel);
    });

    (atoms::ok(), operation).encode(env)
}

#[rustler::nif]
fn endpoint_snapshot(env: Env<'_>) -> Term<'_> {
    let active_identities = active_identities()
        .lock()
        .map(|identities| identities.len())
        .unwrap_or_default();
    (
        atoms::ok(),
        EndpointSnapshot {
            active_endpoints: ACTIVE_ENDPOINTS.load(Ordering::Acquire),
            active_identities,
            active_operations: ACTIVE_OPERATIONS.load(Ordering::Acquire),
        },
    )
        .encode(env)
}
