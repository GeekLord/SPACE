use std::time::Duration;

use pplx_space_common_core::types::{PositiveDuration, snapshot_sweeper_grace_seconds};

/// A borrowed configuration source shared by the reconciler parsers.
pub(crate) struct EnvConfig<'a>(pub(crate) &'a dyn pplx_space_common_core::env::Environment);

impl EnvConfig<'_> {
    pub(crate) fn test_raw(&self, var: &str) -> Option<String> {
        pplx_space_common_core::env::test_hook(self.0, var)
    }

    pub(crate) fn test_truthy_default(&self, var: &str, default: bool) -> bool {
        pplx_space_common_core::env::env_flag(self.test_raw(var).as_deref(), default)
    }

    pub(crate) fn test_duration_secs(&self, var: &str, default: Duration) -> Duration {
        match self.test_raw(var).and_then(|raw| raw.parse::<u64>().ok()) {
            Some(secs) if secs > 0 => Duration::from_secs(secs),
            _ => default,
        }
    }

    pub(crate) fn test_positive_u32(&self, var: &str, default: u32) -> u32 {
        match self.test_raw(var).and_then(|raw| raw.parse::<u32>().ok()) {
            Some(value) if value > 0 => value,
            _ => default,
        }
    }

    pub(crate) fn test_bounded_u32(&self, var: &str, default: u32, ceiling: u32) -> u32 {
        match self.test_raw(var).and_then(|raw| raw.parse::<u64>().ok()) {
            Some(value) if value > 0 => {
                u32::try_from(value.min(u64::from(ceiling))).unwrap_or(ceiling)
            }
            _ => default,
        }
    }

    pub(crate) fn test_positive_usize(&self, var: &str, default: usize) -> usize {
        match self.test_raw(var).and_then(|raw| raw.parse::<usize>().ok()) {
            Some(value) if value > 0 => value,
            _ => default,
        }
    }

    pub(crate) fn test_optional_positive_duration_secs(
        &self,
        var: &str,
        default: Option<PositiveDuration>,
    ) -> Option<PositiveDuration> {
        match self.test_raw(var).and_then(|raw| raw.parse::<u64>().ok()) {
            Some(0) => None,
            Some(value) => PositiveDuration::new(Duration::from_secs(value)),
            None => default,
        }
    }

    pub(crate) fn truthy_default(&self, var: &str, default: bool) -> bool {
        match self.0.var(var).as_deref() {
            Ok("1" | "true" | "True" | "TRUE") => true,
            Ok("0" | "false" | "False" | "FALSE") => false,
            _ => default,
        }
    }

    /// Kill switch for a reconciler that writes or deletes and ships enabled:
    /// unset keeps it on, an explicit truthy value keeps it on, and any other
    /// present value (including `off`, whitespace, or an empty string)
    /// disables it. A misspelled switch must stop the writes, never leave them
    /// running. Same semantics as the shared `env_destructive_gate`.
    pub(crate) fn destructive_gate(&self, var: &str) -> bool {
        pplx_space_common_core::env::env_destructive_gate(self.0.var(var).ok().as_deref())
    }

    pub(crate) fn duration_secs(&self, var: &str, default: Duration) -> Duration {
        match self.0.var(var).ok().and_then(|raw| raw.parse::<u64>().ok()) {
            Some(secs) if secs > 0 => Duration::from_secs(secs),
            _ => default,
        }
    }

    pub(crate) fn positive_u32(&self, var: &str, default: u32) -> u32 {
        match self.0.var(var).ok().and_then(|raw| raw.parse::<u32>().ok()) {
            Some(n) if n > 0 => n,
            _ => default,
        }
    }

    /// Like [`Self::bounded_u32`] but `0` is a valid value.
    ///
    /// Use this for safety ceilings where zero is an operational kill switch.
    pub(crate) fn bounded_u32_allow_zero(&self, var: &str, default: u32, ceiling: u32) -> u32 {
        match self.0.var(var).ok().and_then(|raw| raw.parse::<u64>().ok()) {
            Some(n) => u32::try_from(n.min(u64::from(ceiling))).unwrap_or(ceiling),
            None => default,
        }
    }

    pub(crate) fn bounded_u32(&self, var: &str, default: u32, ceiling: u32) -> u32 {
        // Parse as u64 so a too-large value (an operator typoing extra
        // digits) clamps to `ceiling` rather than overflowing u32, failing to
        // parse, and silently falling back to `default`. Clamping is the
        // documented contract of the ceiling — an in-range over-ceiling value
        // already clamps, so an out-of-u32-range one must clamp identically.
        match self.0.var(var).ok().and_then(|raw| raw.parse::<u64>().ok()) {
            Some(n) if n > 0 => u32::try_from(n.min(u64::from(ceiling))).unwrap_or(ceiling),
            _ => default,
        }
    }

    /// Test-hook form of an optional plain `Duration` from seconds. `0` maps
    /// to `None`.
    pub(crate) fn test_optional_duration_secs(
        &self,
        var: &str,
        default: Option<Duration>,
    ) -> Option<Duration> {
        snapshot_sweeper_grace_seconds(self.test_raw(var).as_deref(), default)
    }
}

pub(crate) fn truthy_default(var: &str, default: bool) -> bool {
    EnvConfig(&pplx_space_common_core::env::ProcessEnvironment).truthy_default(var, default)
}

pub(crate) fn destructive_gate(var: &str) -> bool {
    EnvConfig(&pplx_space_common_core::env::ProcessEnvironment).destructive_gate(var)
}

pub(crate) fn duration_secs(var: &str, default: Duration) -> Duration {
    EnvConfig(&pplx_space_common_core::env::ProcessEnvironment).duration_secs(var, default)
}

pub(crate) fn positive_u32(var: &str, default: u32) -> u32 {
    EnvConfig(&pplx_space_common_core::env::ProcessEnvironment).positive_u32(var, default)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gate(value: Option<&str>) -> bool {
        let mut env = pplx_space_test_env::TestEnv::default();
        if let Some(value) = value {
            env.set("SPACE_TEST_GATE", value);
        }
        EnvConfig(&env).destructive_gate("SPACE_TEST_GATE")
    }

    #[test]
    fn destructive_gate_is_on_when_unset_or_explicitly_truthy() {
        for value in [None, Some("1"), Some("true"), Some("TRUE"), Some(" yes ")] {
            assert!(gate(value), "{value:?} should keep the gate on");
        }
    }

    #[test]
    fn destructive_gate_is_off_for_any_other_present_value() {
        for value in [
            Some("0"),
            Some("false"),
            Some(" false  "),
            Some("off"),
            Some("disabled"),
            Some("fasle"),
            Some(""),
            Some("   "),
        ] {
            assert!(!gate(value), "{value:?} should turn the gate off");
        }
    }
}
