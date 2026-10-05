//! Experimental public reference-only credential-injection document.

use super::PublicEnumParseError;
use crate::credential_references::CredentialReference;
#[cfg(feature = "serde")]
use serde::{Deserialize, Deserializer, Serialize, Serializer, de};
use std::{fmt, str::FromStr};

#[derive(Clone, Debug, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(deny_unknown_fields))]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct PutCredentialInjectionRulesRequest {
    pub ruleset: CredentialInjectionRules,
    /// Durable idempotency key, scoped to this organization and sandbox.
    pub request_id: String,
    pub expected_version: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(deny_unknown_fields))]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct PutCredentialInjectionRulesResponse {
    pub committed_version: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(deny_unknown_fields))]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct CredentialInjectionRules {
    pub rules: Vec<CredentialInjectionRule>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(deny_unknown_fields))]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct CredentialInjectionRule {
    pub rule_id: String,
    pub destination: CredentialInjectionDestination,
    pub credential: CredentialReference,
    pub transform: CredentialInjectionTransform,
}

#[derive(Clone, Debug, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(deny_unknown_fields))]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct CredentialInjectionDestination {
    pub exact_host: String,
    pub port: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(deny_unknown_fields))]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct CredentialInjectionTransform {
    pub activation: CredentialInvocationActivation,
    pub set_headers: CredentialHeaderTransform,
}

#[derive(Clone, Debug, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(deny_unknown_fields))]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct CredentialInvocationActivation {
    /// Hex-encoded SHA-256 digest of the invocation's proxy capability.
    pub proxy_capability_sha256: String,
    /// RFC 3339 activation deadline; expired entries remain part of stored intent.
    pub not_after: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(deny_unknown_fields))]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct CredentialHeaderTransform {
    pub headers: Vec<CredentialHeaderTemplate>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(deny_unknown_fields))]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct CredentialHeaderTemplate {
    pub name: String,
    pub format: CredentialHeaderFormat,
}

wire_enum!(CredentialHeaderFormat, "credential header format", {
    Raw => "raw",
    Bearer => "bearer",
});
