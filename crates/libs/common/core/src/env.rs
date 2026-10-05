//! Shared parsing for boolean ("flag") environment variables.
//!
//! SPACE services read on/off knobs from env vars in many places, and each
//! call site historically re-invented the truthy/falsy vocabulary with a
//! local `matches!`. This module is the single vocabulary:
//!
//! - truthy: `1`, `true`, `yes`, `on`, `enabled`
//! - falsy: `0`, `false`, `no`, `off`, `disabled`
//!
//! Matching is case-insensitive and whitespace-trimmed. Unset, empty, or
//! unrecognized values fall back to the caller's default, so a typo in a
//! deployment env degrades to the shipped behavior instead of silently
//! flipping a feature. Callers pick the default per knob: opt-in features
//! pass `false`, kill switches that must fail toward the fixed behavior
//! pass `true`.

/// Admission gate for create-time sandbox node-pool placement.
pub const SANDBOX_ALLOW_PLACEMENT_ENV: &str = "SPACE_ALLOW_SANDBOX_PLACEMENT";
/// Placement is operator-only and remains disabled unless explicitly enabled.
pub const DEFAULT_SANDBOX_ALLOW_PLACEMENT: bool = false;

/// Read a test-only override.
///
/// A few settings exist only so kind, smoke scenarios and tests can shrink a
/// timer or flip a scenario switch. They are not part of the public
/// configuration: this returns `None` unless the `test-hooks` feature is
/// compiled in, which release binaries never do. Use it for a value that
/// no operator should set, never for a setting a deployment may need.
#[cfg(feature = "test-hooks")]
pub fn test_hook(env: &dyn Environment, name: &str) -> Option<String> {
    env.var(name).ok()
}

/// See the `test-hooks` variant. Without the feature there is no override.
#[cfg(not(feature = "test-hooks"))]
pub fn test_hook(_env: &dyn Environment, _name: &str) -> Option<String> {
    None
}

/// [`test_hook`] over the live process environment.
pub fn test_hook_var(name: &str) -> Option<String> {
    test_hook(&ProcessEnvironment, name)
}

/// Interpret an env var's raw value as an on/off flag, falling back to
/// `default` when the value is absent or not in the shared vocabulary.
pub fn env_flag(raw: Option<&str>, default: bool) -> bool {
    let Some(raw) = raw else {
        return default;
    };
    match raw.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "on" | "enabled" => true,
        "0" | "false" | "no" | "off" | "disabled" => false,
        _ => default,
    }
}

/// [`env_flag`] over `std::env::var(name)`.
pub fn env_flag_var(name: &str, default: bool) -> bool {
    env_flag(std::env::var(name).ok().as_deref(), default)
}

/// Gate for DESTRUCTIVE paths: enabled only when unset or explicitly
/// truthy. Unlike [`env_flag`], falsy and unrecognized values BOTH read
/// as disabled — an emergency kill-switch flip with a typo must stop the
/// destructive path, never silently leave it running. Unset stays
/// enabled so a rollout that has not rendered the knob keeps the shipped
/// default.
pub fn env_destructive_gate(raw: Option<&str>) -> bool {
    match raw {
        None => true,
        Some(raw) => matches!(
            raw.trim().to_ascii_lowercase().as_str(),
            "1" | "true" | "yes" | "on" | "enabled"
        ),
    }
}

/// [`env_destructive_gate`] over `std::env::var(name)`.
pub fn env_destructive_gate_var(name: &str) -> bool {
    env_destructive_gate(std::env::var(name).ok().as_deref())
}

/// `Some(value)` when `value` is finite and strictly positive, else `None`.
/// The shared sanity check for rate/burst-style knobs, where a zero, negative,
/// NaN, or infinite value is never a legal configuration.
#[must_use]
pub fn valid_positive_f64(value: f64) -> Option<f64> {
    value.is_finite().then_some(value).filter(|v| *v > 0.0)
}

/// Parse env var `name` as a strictly-positive `f64`, falling back to `default`
/// when it is unset, unparseable, or not [`valid_positive_f64`]. Kept
/// dependency-free (no logging) so this base crate stays minimal; callers that
/// want a misconfiguration warning can compare against `default` at their edge.
#[must_use]
pub fn parse_positive_f64_env(name: &str, default: f64) -> f64 {
    std::env::var(name)
        .ok()
        .and_then(|raw| raw.trim().parse::<f64>().ok())
        .and_then(valid_positive_f64)
        .unwrap_or(default)
}

#[cfg(test)]
mod tests;

/// Read-only configuration source. Production reads the process environment;
/// callers constructing isolated configurations can supply an owned map.
pub trait Environment {
    fn var_os(&self, name: &str) -> Option<std::ffi::OsString>;

    fn var(&self, name: &str) -> Result<String, std::env::VarError> {
        self.var_os(name)
            .ok_or(std::env::VarError::NotPresent)?
            .into_string()
            .map_err(std::env::VarError::NotUnicode)
    }
}

/// The live process environment; reading never mutates it.
pub struct ProcessEnvironment;

impl Environment for ProcessEnvironment {
    fn var_os(&self, name: &str) -> Option<std::ffi::OsString> {
        std::env::var_os(name)
    }
}
