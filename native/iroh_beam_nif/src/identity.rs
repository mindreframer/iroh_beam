use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::atomic::{AtomicU64, Ordering};

use iroh::{EndpointAddr, EndpointId, RelayUrl, SecretKey, TransportAddr};
use iroh_tickets::endpoint::EndpointTicket;
use iroh_tickets::Ticket;
use rustler::{Binary, Encoder, Env, OwnedBinary, Resource, ResourceArc, Term};

use crate::{atoms, encode_guarded, guarded, native_error, NativeError};

const KEY_SIZE: usize = 32;
const MAX_ADDRS: usize = 64;
const MAX_RELAY_URL_BYTES: usize = 2_048;
const MAX_TICKET_BYTES: usize = 64 * 1_024;
const MAX_TICKET_TEXT_BYTES: usize = 128 * 1_024;
static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

pub(crate) struct SecretKeyResource {
    pub(crate) key: SecretKey,
}

#[rustler::resource_impl]
impl Resource for SecretKeyResource {}

#[derive(rustler::NifMap)]
struct NormalizedAddr {
    relay_urls: Vec<String>,
    ip_addrs: Vec<String>,
}

#[derive(rustler::NifMap)]
struct ParsedTicket {
    endpoint_id: String,
    relay_urls: Vec<String>,
    ip_addrs: Vec<String>,
    text: String,
}

fn invalid(operation: rustler::Atom, message: &'static str) -> NativeError {
    native_error(atoms::invalid_argument(), operation, message)
}

fn io_error(message: &'static str) -> NativeError {
    native_error(atoms::io(), atoms::identity_load(), message)
}

fn id_from_bytes(bytes: &[u8]) -> Result<EndpointId, NativeError> {
    let bytes: &[u8; KEY_SIZE] = bytes.try_into().map_err(|_| {
        invalid(
            atoms::endpoint_id(),
            "endpoint ID must contain exactly 32 bytes",
        )
    })?;
    EndpointId::from_bytes(bytes).map_err(|_| {
        invalid(
            atoms::endpoint_id(),
            "endpoint ID is not a valid public key",
        )
    })
}

fn normalize_addr(addr: &EndpointAddr) -> NormalizedAddr {
    let relay_urls = addr.relay_urls().map(ToString::to_string).collect();
    let ip_addrs = addr.ip_addrs().map(ToString::to_string).collect();
    NormalizedAddr {
        relay_urls,
        ip_addrs,
    }
}

pub(crate) fn build_addr(
    endpoint_id: &[u8],
    relay_urls: Vec<String>,
    ip_addrs: Vec<String>,
) -> Result<EndpointAddr, NativeError> {
    if relay_urls.len() + ip_addrs.len() > MAX_ADDRS {
        return Err(invalid(
            atoms::endpoint_addr(),
            "endpoint address contains too many transport addresses",
        ));
    }

    let id = id_from_bytes(endpoint_id)?;
    let mut addrs = Vec::with_capacity(relay_urls.len() + ip_addrs.len());

    for value in relay_urls {
        if value.len() > MAX_RELAY_URL_BYTES {
            return Err(invalid(atoms::endpoint_addr(), "relay URL is too long"));
        }
        let url = RelayUrl::from_str(&value)
            .map_err(|_| invalid(atoms::endpoint_addr(), "relay URL is invalid"))?;
        if !matches!(url.scheme(), "http" | "https")
            || url.host_str().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
        {
            return Err(invalid(
                atoms::endpoint_addr(),
                "relay URL must be an HTTP(S) URL without credentials",
            ));
        }
        addrs.push(TransportAddr::Relay(url));
    }

    for value in ip_addrs {
        let addr = SocketAddr::from_str(&value)
            .map_err(|_| invalid(atoms::endpoint_addr(), "IP socket address is invalid"))?;
        addrs.push(TransportAddr::Ip(addr));
    }

    Ok(EndpointAddr::from_parts(id, addrs))
}

fn parsed_ticket(ticket: &EndpointTicket) -> ParsedTicket {
    let addr = ticket.endpoint_addr();
    let normalized = normalize_addr(addr);
    ParsedTicket {
        endpoint_id: addr.id.to_string(),
        relay_urls: normalized.relay_urls,
        ip_addrs: normalized.ip_addrs,
        text: ticket.to_string(),
    }
}

fn allocate_binary<'a>(
    env: Env<'a>,
    bytes: &[u8],
    operation: rustler::Atom,
) -> Result<Binary<'a>, NativeError> {
    let mut binary = OwnedBinary::new(bytes.len())
        .ok_or_else(|| native_error(atoms::internal(), operation, "binary allocation failed"))?;
    binary.as_mut_slice().copy_from_slice(bytes);
    Ok(binary.release(env))
}

#[rustler::nif]
fn identity_generate(env: Env<'_>) -> Term<'_> {
    encode_guarded(env, atoms::identity_generate(), || {
        Ok(ResourceArc::new(SecretKeyResource {
            key: SecretKey::generate(),
        }))
    })
}

#[rustler::nif]
fn secret_key_import<'a>(env: Env<'a>, bytes: Binary<'a>) -> Term<'a> {
    encode_guarded(env, atoms::secret_key_import(), || {
        let bytes: &[u8; KEY_SIZE] = bytes.as_slice().try_into().map_err(|_| {
            invalid(
                atoms::secret_key_import(),
                "secret key must contain exactly 32 bytes",
            )
        })?;
        Ok(ResourceArc::new(SecretKeyResource {
            key: SecretKey::from_bytes(bytes),
        }))
    })
}

#[rustler::nif]
fn secret_key_export<'a>(env: Env<'a>, secret_key: ResourceArc<SecretKeyResource>) -> Term<'a> {
    let result = guarded(
        || {
            let bytes = secret_key.key.to_bytes();
            allocate_binary(env, &bytes, atoms::secret_key_export())
        },
        || {
            native_error(
                atoms::internal(),
                atoms::secret_key_export(),
                "native operation failed internally",
            )
        },
    );

    match result {
        Ok(binary) => (atoms::ok(), binary).encode(env),
        Err(error) => (atoms::error(), error).encode(env),
    }
}

#[rustler::nif]
fn secret_key_endpoint_id(env: Env<'_>, secret_key: ResourceArc<SecretKeyResource>) -> Term<'_> {
    encode_guarded(env, atoms::endpoint_id(), || {
        Ok(secret_key.key.public().to_string())
    })
}

#[rustler::nif]
fn endpoint_id_parse(env: Env<'_>, text: String) -> Term<'_> {
    encode_guarded(env, atoms::endpoint_id(), || {
        if text.len() > 128 {
            return Err(invalid(atoms::endpoint_id(), "endpoint ID is too long"));
        }
        EndpointId::from_str(&text)
            .map(|id| id.to_string())
            .map_err(|_| invalid(atoms::endpoint_id(), "endpoint ID is invalid"))
    })
}

#[rustler::nif]
fn endpoint_id_from_bytes<'a>(env: Env<'a>, bytes: Binary<'a>) -> Term<'a> {
    encode_guarded(env, atoms::endpoint_id(), || {
        id_from_bytes(bytes.as_slice()).map(|id| id.to_string())
    })
}

#[rustler::nif]
fn endpoint_addr_normalize<'a>(
    env: Env<'a>,
    endpoint_id: Binary<'a>,
    relay_urls: Vec<String>,
    ip_addrs: Vec<String>,
) -> Term<'a> {
    encode_guarded(env, atoms::endpoint_addr(), || {
        build_addr(endpoint_id.as_slice(), relay_urls, ip_addrs).map(|addr| normalize_addr(&addr))
    })
}

#[rustler::nif]
fn endpoint_ticket_from_addr_text<'a>(
    env: Env<'a>,
    endpoint_id: Binary<'a>,
    relay_urls: Vec<String>,
    ip_addrs: Vec<String>,
) -> Term<'a> {
    encode_guarded(env, atoms::endpoint_ticket(), || {
        let addr = build_addr(endpoint_id.as_slice(), relay_urls, ip_addrs)?;
        Ok(EndpointTicket::new(addr).to_string())
    })
}

#[rustler::nif]
fn endpoint_ticket_from_addr_bytes<'a>(
    env: Env<'a>,
    endpoint_id: Binary<'_>,
    relay_urls: Vec<String>,
    ip_addrs: Vec<String>,
) -> Term<'a> {
    let result = guarded(
        || {
            let addr = build_addr(endpoint_id.as_slice(), relay_urls, ip_addrs)?;
            let ticket = EndpointTicket::new(addr);
            allocate_binary(env, &ticket.encode_bytes(), atoms::endpoint_ticket())
        },
        || {
            native_error(
                atoms::internal(),
                atoms::endpoint_ticket(),
                "native operation failed internally",
            )
        },
    );
    match result {
        Ok(binary) => (atoms::ok(), binary).encode(env),
        Err(error) => (atoms::error(), error).encode(env),
    }
}

#[rustler::nif]
fn endpoint_ticket_parse_text(env: Env<'_>, text: String) -> Term<'_> {
    encode_guarded(env, atoms::endpoint_ticket(), || {
        if text.len() > MAX_TICKET_TEXT_BYTES {
            return Err(invalid(
                atoms::endpoint_ticket(),
                "endpoint ticket is too large",
            ));
        }
        let ticket = EndpointTicket::from_str(&text)
            .map_err(|_| invalid(atoms::endpoint_ticket(), "endpoint ticket is invalid"))?;
        Ok(parsed_ticket(&ticket))
    })
}

#[rustler::nif]
fn endpoint_ticket_parse_bytes<'a>(env: Env<'a>, bytes: Binary<'a>) -> Term<'a> {
    encode_guarded(env, atoms::endpoint_ticket(), || {
        if bytes.len() > MAX_TICKET_BYTES {
            return Err(invalid(
                atoms::endpoint_ticket(),
                "endpoint ticket is too large",
            ));
        }
        let ticket = EndpointTicket::decode_bytes(bytes.as_slice())
            .map_err(|_| invalid(atoms::endpoint_ticket(), "endpoint ticket is invalid"))?;
        Ok(parsed_ticket(&ticket))
    })
}

#[rustler::nif]
fn endpoint_ticket_text_to_bytes<'a>(env: Env<'a>, text: String) -> Term<'a> {
    let result = guarded(
        || {
            if text.len() > MAX_TICKET_TEXT_BYTES {
                return Err(invalid(
                    atoms::endpoint_ticket(),
                    "endpoint ticket is too large",
                ));
            }
            let ticket = EndpointTicket::from_str(&text)
                .map_err(|_| invalid(atoms::endpoint_ticket(), "endpoint ticket is invalid"))?;
            allocate_binary(env, &ticket.encode_bytes(), atoms::endpoint_ticket())
        },
        || {
            native_error(
                atoms::internal(),
                atoms::endpoint_ticket(),
                "native operation failed internally",
            )
        },
    );
    match result {
        Ok(binary) => (atoms::ok(), binary).encode(env),
        Err(error) => (atoms::error(), error).encode(env),
    }
}

fn read_key(path: &Path) -> Result<SecretKey, NativeError> {
    let metadata = fs::metadata(path).map_err(|_| io_error("identity file could not be read"))?;
    if !metadata.is_file() || metadata.len() != KEY_SIZE as u64 {
        return Err(invalid(
            atoms::identity_load(),
            "identity file has an invalid format",
        ));
    }
    let bytes = fs::read(path).map_err(|_| io_error("identity file could not be read"))?;
    let bytes: &[u8; KEY_SIZE] = bytes.as_slice().try_into().map_err(|_| {
        invalid(
            atoms::identity_load(),
            "identity file has an invalid format",
        )
    })?;
    Ok(SecretKey::from_bytes(bytes))
}

fn temp_path(path: &Path) -> Result<PathBuf, NativeError> {
    let parent = path.parent().ok_or_else(|| {
        invalid(
            atoms::identity_load(),
            "identity path has no parent directory",
        )
    })?;
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| invalid(atoms::identity_load(), "identity path is invalid"))?;
    let sequence = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
    Ok(parent.join(format!(".{name}.{}.{}.tmp", std::process::id(), sequence)))
}

#[cfg(unix)]
fn create_temp(path: &Path) -> std::io::Result<File> {
    use std::os::unix::fs::OpenOptionsExt;
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
}

#[cfg(not(unix))]
fn create_temp(path: &Path) -> std::io::Result<File> {
    OpenOptions::new().write(true).create_new(true).open(path)
}

fn create_identity(path: &Path) -> Result<SecretKey, NativeError> {
    let parent = path.parent().ok_or_else(|| {
        invalid(
            atoms::identity_load(),
            "identity path has no parent directory",
        )
    })?;
    fs::create_dir_all(parent).map_err(|_| io_error("identity directory could not be created"))?;

    let key = SecretKey::generate();
    let temp = temp_path(path)?;
    let mut file = create_temp(&temp).map_err(|_| io_error("identity temporary file failed"))?;
    let mut bytes = key.to_bytes();
    let write_result = file.write_all(&bytes).and_then(|()| file.sync_all());
    bytes.fill(0);
    drop(file);
    if write_result.is_err() {
        let _ignored = fs::remove_file(&temp);
        return Err(io_error("identity temporary file could not be written"));
    }

    let publication = fs::hard_link(&temp, path);
    let _ignored = fs::remove_file(&temp);
    match publication {
        Ok(()) => Ok(key),
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => read_key(path),
        Err(_) => Err(io_error("identity file could not be published")),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn identity_load_or_create(env: Env<'_>, path: String) -> Term<'_> {
    encode_guarded(env, atoms::identity_load(), || {
        if path.is_empty() || path.len() > 32 * 1_024 {
            return Err(invalid(atoms::identity_load(), "identity path is invalid"));
        }
        let path = Path::new(&path);
        let key = if path.exists() {
            read_key(path)?
        } else {
            create_identity(path)?
        };
        Ok(ResourceArc::new(SecretKeyResource { key }))
    })
}
