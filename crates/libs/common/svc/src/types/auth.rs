use pplx_space_common_core::types::{ApiKeyId, OrgId, UserId};

/// Authenticated caller context after request authentication.
///
/// This records the organization and either a user identity or an API key
/// identity, without introducing a higher-level session concept.
///
/// ```
/// # use pplx_space_common_core::types::{OrgId, UserId};
/// # use pplx_space_common_svc::types::AuthContext;
/// let org_id = OrgId::new();
/// let user_id = UserId::new();
/// let auth = AuthContext::user(user_id, org_id);
///
/// assert_eq!(auth.org_id(), org_id);
/// assert_eq!(auth.user_id(), Some(user_id));
/// assert_eq!(auth.api_key_id(), None);
/// ```
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuthContext {
    user_id: Option<UserId>,
    org_id: OrgId,
    api_key_id: Option<ApiKeyId>,
}

impl AuthContext {
    /// Builds auth context for an authenticated user request.
    ///
    /// ```
    /// # use pplx_space_common_core::types::{OrgId, UserId};
    /// # use pplx_space_common_svc::types::AuthContext;
    /// let auth = AuthContext::user(UserId::new(), OrgId::new());
    /// assert!(auth.user_id().is_some());
    /// ```
    pub const fn user(user_id: UserId, org_id: OrgId) -> Self {
        Self {
            user_id: Some(user_id),
            org_id,
            api_key_id: None,
        }
    }

    /// Builds auth context for an authenticated API key request.
    ///
    /// ```
    /// # use pplx_space_common_core::types::{ApiKeyId, OrgId};
    /// # use pplx_space_common_svc::types::AuthContext;
    /// let auth = AuthContext::api_key(ApiKeyId::new(), OrgId::new());
    /// assert!(auth.api_key_id().is_some());
    /// assert_eq!(auth.user_id(), None);
    /// ```
    pub const fn api_key(api_key_id: ApiKeyId, org_id: OrgId) -> Self {
        Self {
            user_id: None,
            org_id,
            api_key_id: Some(api_key_id),
        }
    }

    /// Returns the authenticated user, when the request used user auth.
    ///
    /// ```
    /// # use pplx_space_common_core::types::{OrgId, UserId};
    /// # use pplx_space_common_svc::types::AuthContext;
    /// let user_id = UserId::new();
    /// let auth = AuthContext::user(user_id, OrgId::new());
    /// assert_eq!(auth.user_id(), Some(user_id));
    /// ```
    pub const fn user_id(&self) -> Option<UserId> {
        self.user_id
    }

    /// Returns the organization the request is scoped to.
    ///
    /// ```
    /// # use pplx_space_common_core::types::{OrgId, UserId};
    /// # use pplx_space_common_svc::types::AuthContext;
    /// let org_id = OrgId::new();
    /// let auth = AuthContext::user(UserId::new(), org_id);
    /// assert_eq!(auth.org_id(), org_id);
    /// ```
    pub const fn org_id(&self) -> OrgId {
        self.org_id
    }

    /// Returns the API key, when the request used API key auth.
    ///
    /// ```
    /// # use pplx_space_common_core::types::{ApiKeyId, OrgId};
    /// # use pplx_space_common_svc::types::AuthContext;
    /// let api_key_id = ApiKeyId::new();
    /// let auth = AuthContext::api_key(api_key_id, OrgId::new());
    /// assert_eq!(auth.api_key_id(), Some(api_key_id));
    /// ```
    pub const fn api_key_id(&self) -> Option<ApiKeyId> {
        self.api_key_id
    }
}
