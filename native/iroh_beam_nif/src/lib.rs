use std::collections::HashMap;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicU8, AtomicUsize, Ordering};
use std::sync::{OnceLock, OnceLock as RuntimeLock};
use std::time::Duration;

use rustler::{Atom, Encoder, Env, LocalPid, Monitor, OwnedEnv, Resource, ResourceArc, Term};
use tokio::runtime::{Builder, Runtime};
use tokio::sync::Notify;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        completed,
        cancelled,
        internal,
        native_failure,
        native_smoke,
        native_versions,
        panic_outcome = "panic",
        native_module = "Elixir.IrohBeam.Native"
    }
}

const RUNNING: u8 = 0;
const COMPLETED: u8 = 1;
const CANCELLED: u8 = 2;
const IROH_VERSION: &str = "1.0.3";
const RUSTLER_VERSION: &str = "0.38.0";
const NIF_VERSION: &str = "2.16";

static RUNTIME: RuntimeLock<Result<Runtime, String>> = OnceLock::new();
static ACTIVE_OPERATIONS: AtomicUsize = AtomicUsize::new(0);

#[derive(rustler::NifMap)]
struct VersionInfo {
    iroh: String,
    rustler: String,
    nif: String,
    crate_version: String,
}

#[derive(rustler::NifMap)]
struct NativeError {
    category: Atom,
    operation: Atom,
    message: String,
    context: HashMap<String, String>,
}

struct OperationResource {
    state: AtomicU8,
    cancelled: Notify,
}

impl OperationResource {
    fn new() -> Self {
        Self {
            state: AtomicU8::new(RUNNING),
            cancelled: Notify::new(),
        }
    }

    fn cancel(&self) -> bool {
        let cancelled = self
            .state
            .compare_exchange(RUNNING, CANCELLED, Ordering::AcqRel, Ordering::Acquire)
            .is_ok();

        if cancelled {
            self.cancelled.notify_one();
        }

        cancelled
    }
}

#[rustler::resource_impl]
impl Resource for OperationResource {
    fn down(&self, _env: Env<'_>, _pid: LocalPid, _monitor: Monitor) {
        self.cancel();
    }
}

fn runtime() -> Result<&'static Runtime, NativeError> {
    match RUNTIME.get_or_init(|| {
        Builder::new_multi_thread()
            .thread_name("iroh-beam")
            .enable_time()
            .build()
            .map_err(|_| "managed native runtime could not be started".to_owned())
    }) {
        Ok(runtime) => Ok(runtime),
        Err(message) => Err(native_error(
            atoms::internal(),
            atoms::native_smoke(),
            message,
        )),
    }
}

fn native_error(category: Atom, operation: Atom, message: impl Into<String>) -> NativeError {
    NativeError {
        category,
        operation,
        message: message.into(),
        context: HashMap::new(),
    }
}

fn guarded<T, E>(
    operation: impl FnOnce() -> Result<T, E>,
    panic_error: impl FnOnce() -> E,
) -> Result<T, E> {
    catch_unwind(AssertUnwindSafe(operation)).unwrap_or_else(|_| Err(panic_error()))
}

#[rustler::nif]
fn native_versions(env: Env<'_>) -> Term<'_> {
    let versions = VersionInfo {
        iroh: IROH_VERSION.to_owned(),
        rustler: RUSTLER_VERSION.to_owned(),
        nif: NIF_VERSION.to_owned(),
        crate_version: env!("CARGO_PKG_VERSION").to_owned(),
    };

    (atoms::ok(), versions).encode(env)
}

#[rustler::nif]
fn operation_start<'a>(
    env: Env<'a>,
    caller: LocalPid,
    operation_ref: Term<'a>,
    kind: Atom,
    delay_ms: u64,
) -> Term<'a> {
    let runtime = match runtime() {
        Ok(runtime) => runtime,
        Err(error) => return (atoms::error(), error).encode(env),
    };

    let is_panic = kind == atoms::panic_outcome();
    if kind != atoms::ok() && kind != atoms::error() && !is_panic {
        return (
            atoms::error(),
            native_error(
                atoms::native_failure(),
                atoms::native_smoke(),
                "unsupported smoke outcome",
            ),
        )
            .encode(env);
    }

    let resource = ResourceArc::new(OperationResource::new());
    let monitor = match resource.monitor(Some(env), &caller) {
        Some(monitor) => monitor,
        None => {
            return (
                atoms::error(),
                native_error(
                    atoms::cancelled(),
                    atoms::native_smoke(),
                    "caller is no longer available",
                ),
            )
                .encode(env)
        }
    };

    let message_resource = resource.clone();
    let mut owned_env = OwnedEnv::new();
    let saved_ref = owned_env.save(operation_ref);
    ACTIVE_OPERATIONS.fetch_add(1, Ordering::AcqRel);

    runtime.spawn(async move {
        tokio::select! {
            _ = tokio::time::sleep(Duration::from_millis(delay_ms)) => {}
            _ = message_resource.cancelled.notified() => {}
        }

        let should_complete = message_resource
            .state
            .compare_exchange(RUNNING, COMPLETED, Ordering::AcqRel, Ordering::Acquire)
            .is_ok();

        if should_complete {
            let result = guarded(
                || {
                    if is_panic {
                        Err(native_error(
                            atoms::internal(),
                            atoms::native_smoke(),
                            "native operation failed internally",
                        ))
                    } else if kind == atoms::error() {
                        Err(native_error(
                            atoms::native_failure(),
                            atoms::native_smoke(),
                            "native smoke failure",
                        ))
                    } else {
                        Ok(atoms::completed())
                    }
                },
                || {
                    native_error(
                        atoms::internal(),
                        atoms::native_smoke(),
                        "native operation failed internally",
                    )
                },
            );

            let _send_result = owned_env.send_and_clear(&caller, |message_env| {
                let result_term = match result {
                    Ok(value) => (atoms::ok(), value).encode(message_env),
                    Err(error) => (atoms::error(), error).encode(message_env),
                };

                (
                    atoms::native_module(),
                    saved_ref.load(message_env),
                    result_term,
                )
                    .encode(message_env)
            });
        }

        let _demonitored = owned_env.demonitor(&message_resource, &monitor);
        ACTIVE_OPERATIONS.fetch_sub(1, Ordering::AcqRel);
    });

    (atoms::ok(), resource).encode(env)
}

#[rustler::nif]
fn operation_cancel(operation: ResourceArc<OperationResource>) -> bool {
    operation.cancel()
}

#[rustler::nif]
fn operation_snapshot() -> usize {
    ACTIVE_OPERATIONS.load(Ordering::Acquire)
}

rustler::init!("Elixir.IrohBeam.Native");

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn operation_cancel_is_idempotent() {
        let operation = OperationResource::new();
        assert!(operation.cancel());
        assert!(!operation.cancel());
        assert_eq!(operation.state.load(Ordering::Acquire), CANCELLED);
    }

    #[test]
    fn guarded_contains_panics() {
        let result = guarded::<(), String>(
            || panic!("private panic detail"),
            || "native operation failed internally".to_owned(),
        );
        let error = result.expect_err("panic must become an error");
        assert_eq!(error, "native operation failed internally");
    }
}
