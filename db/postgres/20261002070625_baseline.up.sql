-- Initial public schema. Existing databases require an explicit history cutover.
-- The inherited partial indexes preserve current query and uniqueness semantics.
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '5min';
SET LOCAL default_table_access_method = heap;

CREATE TYPE public.state_reconciliation_reason AS ENUM (
    'node_registered',
    'node_updated',
    'manual_node_status_refresh',
    'manual_node_reconcile',
    'manual_node_network_policy_reconcile',
    'node_template_pulled',
    'sandbox_registered',
    'sandbox_port_exposure_updated',
    'sandbox_network_policy_updated',
    'sandbox_desired_state_updated',
    'template_network_policy_updated',
    'template_desired_state_updated',
    'template_base_snapshot_policy_updated',
    'template_pool_policy_updated',
    'template_pool_policy_deleted',
    'node_sandbox_inventory_published',
    'node_template_inventory_published'
);

CREATE FUNCTION public.organizations_reject_owner_identity_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION 'organization owner identity fields are immutable';
END;
$$;

CREATE FUNCTION public.sandboxes_clear_command_ready_pending() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Only `started` carries a meaningful pending-readiness flag. Any move to
    -- another lifecycle (suspended/stopped/failed/deleting/…) makes it stale, so
    -- clear it rather than let it force an unnecessary confirm after a later
    -- restore.
    IF NEW.command_ready_pending
       AND NEW.lifecycle IS DISTINCT FROM OLD.lifecycle
       AND LOWER(TRIM(NEW.lifecycle)) <> 'started'
    THEN
        NEW.command_ready_pending := FALSE;
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION public.sandboxes_clear_evacuation_restore_target() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.lifecycle IS DISTINCT FROM OLD.lifecycle
       AND NEW.lifecycle NOT IN ('suspending', 'suspended', 'restoring') THEN
        NEW.evacuation_restore_target := NULL;
    END IF;
    IF NEW.evacuation_restore_target IS NULL THEN
        NEW.restore_attempt_count := 0;
        NEW.next_restore_attempt_at := NULL;
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION public.sandboxes_clear_restore_lease() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF LOWER(TRIM(NEW.lifecycle)) <> 'restoring' THEN
        NEW.restore_lease_expires_at := NULL;
        NEW.restore_lease_token := NULL;
        NEW.preserve_local_artifact_on_restore_failure := FALSE;
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION public.sandboxes_touch_lifecycle_changed_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.lifecycle IS DISTINCT FROM OLD.lifecycle THEN
        NEW.lifecycle_changed_at := NOW();
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION public.set_sandbox_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.updated_at IS DISTINCT FROM OLD.updated_at THEN
        RETURN NEW;
    END IF;

    IF (to_jsonb(NEW) - ARRAY['updated_at', 'last_used_at', 'last_access_at', 'last_command_at'])
       IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['updated_at', 'last_used_at', 'last_access_at', 'last_command_at']) THEN
        NEW.updated_at := NOW();
    ELSE
        NEW.updated_at := OLD.updated_at;
    END IF;

    RETURN NEW;
END;
$$;

CREATE FUNCTION public.set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$;

CREATE FUNCTION public.space_uuid_v7() RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
    timestamp_ms BIGINT;
    bytes BYTEA;
BEGIN
    timestamp_ms := FLOOR(EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::BIGINT;
    SELECT decode(
        lpad(to_hex(timestamp_ms), 12, '0') ||
        string_agg(lpad(to_hex(FLOOR(random() * 256)::INT), 2, '0'), ''),
        'hex'
    )
    INTO bytes
    FROM generate_series(1, 10);
    bytes := set_byte(bytes, 6, (get_byte(bytes, 6) & 15) | 112);
    bytes := set_byte(bytes, 8, (get_byte(bytes, 8) & 63) | 128);
    RETURN encode(bytes, 'hex')::uuid;
END;
$$;

CREATE FUNCTION public.users_reject_owner_identity_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION 'user owner identity fields are immutable';
END;
$$;

CREATE TABLE public.admin_audit_events (
    id uuid NOT NULL,
    actor_user_id uuid NOT NULL,
    actor_org_id uuid NOT NULL,
    actor_email text NOT NULL,
    method text NOT NULL,
    path text NOT NULL,
    status_code integer NOT NULL,
    success boolean NOT NULL,
    duration_ms bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT admin_audit_events_duration_ms_check CHECK ((duration_ms >= 0)),
    CONSTRAINT admin_audit_events_status_code_check CHECK (((status_code >= 100) AND (status_code <= 599))),
    CONSTRAINT admin_audit_events_pkey PRIMARY KEY (id)
);

CREATE TABLE public.node_k8s_tombstones (
    node_id uuid NOT NULL,
    k8s_node_name text NOT NULL,
    role text NOT NULL,
    terminated_at timestamp with time zone DEFAULT now() NOT NULL,
    reason text,
    CONSTRAINT node_k8s_tombstones_pkey PRIMARY KEY (node_id)
);

CREATE TABLE public.organizations (
    id uuid DEFAULT public.space_uuid_v7() NOT NULL,
    name text NOT NULL,
    slug text NOT NULL,
    parent_id uuid,
    theme_primary text,
    theme_secondary text,
    logo_url text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    byok_enabled boolean DEFAULT false NOT NULL,
    snapshot_base_object_storage_uri text,
    owner_source text DEFAULT 'local'::text NOT NULL,
    upstream_issuer text,
    upstream_org_id text,
    CONSTRAINT organizations_owner_identity_shape_check CHECK ((((owner_source = 'local'::text) AND (upstream_issuer IS NULL) AND (upstream_org_id IS NULL)) OR ((owner_source = 'federated_identity'::text) AND (upstream_issuer IS NOT NULL) AND (upstream_org_id IS NOT NULL) AND ((char_length(upstream_issuer) >= 1) AND (char_length(upstream_issuer) <= 128)) AND ((char_length(upstream_org_id) >= 1) AND (char_length(upstream_org_id) <= 128))))),
    CONSTRAINT organizations_owner_source_check CHECK ((owner_source = ANY (ARRAY['local'::text, 'federated_identity'::text]))),
    CONSTRAINT organizations_pkey PRIMARY KEY (id),
    CONSTRAINT organizations_slug_key UNIQUE (slug),
    CONSTRAINT organizations_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.organizations(id) ON DELETE SET NULL
);

CREATE TABLE public.clusters (
    id uuid NOT NULL,
    name text NOT NULL,
    managing_org_id uuid NOT NULL,
    singleton boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT clusters_id_uuid_v7 CHECK (((get_byte(uuid_send(id), 6) >> 4) = 7)),
    CONSTRAINT clusters_singleton_check CHECK (singleton),
    CONSTRAINT clusters_pkey PRIMARY KEY (id),
    CONSTRAINT clusters_singleton_key UNIQUE (singleton),
    CONSTRAINT clusters_managing_org_id_fkey FOREIGN KEY (managing_org_id) REFERENCES public.organizations(id) ON DELETE RESTRICT
);

CREATE TABLE public.credential_references (
    id uuid DEFAULT public.space_uuid_v7() NOT NULL,
    org_id uuid NOT NULL,
    upstream_provider text NOT NULL,
    upstream_provider_config jsonb NOT NULL,
    state text DEFAULT 'active'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT credential_references_pkey PRIMARY KEY (id),
    CONSTRAINT credential_references_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id) ON DELETE CASCADE
);

CREATE TABLE public.data_plane_org_revocation_epochs (
    org_id uuid NOT NULL,
    epoch bigint DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT data_plane_org_revocation_epochs_epoch_check CHECK ((epoch >= 0)),
    CONSTRAINT data_plane_org_revocation_epochs_pkey PRIMARY KEY (org_id),
    CONSTRAINT data_plane_org_revocation_epochs_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id) ON DELETE CASCADE
);

CREATE TABLE public.node_groups (
    id uuid NOT NULL,
    name text NOT NULL,
    org_id uuid,
    template_policy text DEFAULT 'default'::text NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT node_groups_default_is_generic CHECK (((NOT is_default) OR (org_id IS NULL))),
    CONSTRAINT node_groups_name_check CHECK ((name ~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'::text)),
    CONSTRAINT node_groups_restricted_requires_org CHECK (((org_id IS NOT NULL) OR (template_policy = 'default'::text))),
    CONSTRAINT node_groups_template_policy_check CHECK ((template_policy = ANY (ARRAY['default'::text, 'restricted'::text]))),
    CONSTRAINT node_groups_name_key UNIQUE (name),
    CONSTRAINT node_groups_pkey PRIMARY KEY (id),
    CONSTRAINT node_groups_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id)
);

CREATE TABLE public.nodes (
    id uuid NOT NULL,
    address inet,
    role text NOT NULL,
    managed_by text DEFAULT 'space'::text NOT NULL,
    state text DEFAULT 'registered'::text,
    last_heartbeat timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    drain_phase text,
    drain_started_at timestamp with time zone,
    drain_last_error text,
    terminate_decrement_capacity boolean DEFAULT false NOT NULL,
    drain_mode text,
    node_group_id uuid,
    CONSTRAINT nodes_drain_phase_check CHECK (((drain_phase IS NULL) OR (drain_phase = ANY (ARRAY['draining'::text, 'drained'::text, 'terminating'::text])))),
    CONSTRAINT nodes_managed_by_check CHECK ((managed_by = ANY (ARRAY['space'::text, 'k8s'::text]))),
    CONSTRAINT nodes_role_check CHECK (((managed_by <> 'space'::text) OR (role = ANY (ARRAY['worker'::text, 'builder'::text, 'cluster'::text])))),
    CONSTRAINT nodes_pkey PRIMARY KEY (id)
);

CREATE TABLE public.node_artifact_components (
    node_id uuid NOT NULL,
    kind text NOT NULL,
    role_key text DEFAULT ''::text NOT NULL,
    version_key text DEFAULT ''::text NOT NULL,
    digest_key text DEFAULT ''::text NOT NULL,
    format_key text DEFAULT ''::text NOT NULL,
    version text,
    digest text,
    format text,
    default_for_new boolean NOT NULL,
    legacy_default boolean NOT NULL,
    observed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT node_artifact_components_pkey PRIMARY KEY (node_id, kind, role_key, version_key, digest_key, format_key),
    CONSTRAINT node_artifact_components_node_id_fkey FOREIGN KEY (node_id) REFERENCES public.nodes(id) ON DELETE CASCADE
);

CREATE TABLE public.node_direct (
    node_id uuid NOT NULL,
    name text,
    node_api_endpoint text NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT node_direct_metadata_is_object CHECK ((jsonb_typeof(metadata) = 'object'::text)),
    CONSTRAINT node_direct_pkey PRIMARY KEY (node_id),
    CONSTRAINT node_direct_node_id_fkey FOREIGN KEY (node_id) REFERENCES public.nodes(id) ON DELETE CASCADE
);

CREATE TABLE public.node_facet_observed_status (
    node_id uuid NOT NULL,
    facet text NOT NULL,
    element text DEFAULT ''::text NOT NULL,
    observed_generation bigint,
    observed_payload jsonb,
    applied_source text,
    observed_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    applied_authority text,
    CONSTRAINT node_facet_observed_status_applied_authority_check CHECK (((applied_authority IS NULL) OR (applied_authority = ANY (ARRAY['cluster'::text, 'local'::text])))),
    CONSTRAINT node_facet_observed_status_pkey PRIMARY KEY (node_id, facet, element),
    CONSTRAINT node_facet_observed_status_node_id_fkey FOREIGN KEY (node_id) REFERENCES public.nodes(id) ON DELETE CASCADE
);

CREATE TABLE public.node_facet_conditions (
    node_id uuid NOT NULL,
    facet text NOT NULL,
    element text DEFAULT ''::text NOT NULL,
    condition_type text NOT NULL,
    condition_status text NOT NULL,
    reason text,
    message text,
    last_transition_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT node_facet_conditions_pkey PRIMARY KEY (node_id, facet, element, condition_type),
    CONSTRAINT node_facet_conditions_node_id_facet_element_fkey FOREIGN KEY (node_id, facet, element) REFERENCES public.node_facet_observed_status(node_id, facet, element) ON DELETE CASCADE
);

CREATE TABLE public.node_k8s (
    node_id uuid NOT NULL,
    k8s_node_name text NOT NULL,
    k8s_node_uid text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT node_k8s_pkey PRIMARY KEY (node_id),
    CONSTRAINT node_k8s_node_id_fkey FOREIGN KEY (node_id) REFERENCES public.nodes(id) ON DELETE CASCADE
);

CREATE TABLE public.node_reconcile_queue (
    node_id uuid NOT NULL,
    facet text NOT NULL,
    element text DEFAULT ''::text NOT NULL,
    generation bigint DEFAULT 0 NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    last_error text DEFAULT ''::text NOT NULL,
    claim_token text DEFAULT ''::text NOT NULL,
    claim_generation bigint DEFAULT 0 NOT NULL,
    claimed_at timestamp with time zone,
    next_attempt_at timestamp with time zone DEFAULT now() NOT NULL,
    requested_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    dead_at timestamp with time zone,
    dead_reason text DEFAULT ''::text NOT NULL,
    CONSTRAINT node_reconcile_queue_pkey PRIMARY KEY (node_id, facet, element),
    CONSTRAINT node_reconcile_queue_node_id_fkey FOREIGN KEY (node_id) REFERENCES public.nodes(id) ON DELETE CASCADE
);

CREATE TABLE public.node_reconcile_triggers (
    node_id uuid NOT NULL,
    reason text DEFAULT ''::text NOT NULL,
    generation bigint DEFAULT 0 NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    last_error text DEFAULT ''::text NOT NULL,
    dead_at timestamp with time zone,
    dead_reason text DEFAULT ''::text NOT NULL,
    claim_token text DEFAULT ''::text NOT NULL,
    claim_generation bigint DEFAULT 0 NOT NULL,
    claimed_at timestamp with time zone,
    next_attempt_at timestamp with time zone DEFAULT now() NOT NULL,
    requested_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    reasons public.state_reconciliation_reason[] DEFAULT ARRAY[]::public.state_reconciliation_reason[] NOT NULL,
    CONSTRAINT node_reconcile_triggers_pkey PRIMARY KEY (node_id),
    CONSTRAINT node_reconcile_triggers_node_id_fkey FOREIGN KEY (node_id) REFERENCES public.nodes(id) ON DELETE CASCADE
);

CREATE TABLE public.node_runtime_installations (
    node_id uuid NOT NULL,
    runtime text NOT NULL,
    runtime_version text NOT NULL,
    observed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT node_runtime_installations_pkey PRIMARY KEY (node_id, runtime, runtime_version),
    CONSTRAINT node_runtime_installations_node_id_fkey FOREIGN KEY (node_id) REFERENCES public.nodes(id) ON DELETE CASCADE
);

CREATE TABLE public.node_runtime_guests (
    node_id uuid NOT NULL,
    runtime text NOT NULL,
    runtime_version text NOT NULL,
    guest_os text NOT NULL,
    guest_arch text NOT NULL,
    CONSTRAINT node_runtime_guests_pkey PRIMARY KEY (node_id, runtime, runtime_version, guest_os, guest_arch),
    CONSTRAINT node_runtime_guests_node_id_runtime_runtime_version_fkey FOREIGN KEY (node_id, runtime, runtime_version) REFERENCES public.node_runtime_installations(node_id, runtime, runtime_version) ON DELETE CASCADE
);

CREATE TABLE public.node_runtime_state_formats (
    node_id uuid NOT NULL,
    runtime text NOT NULL,
    runtime_version text NOT NULL,
    state_format_name text NOT NULL,
    state_format_version text NOT NULL,
    can_create boolean NOT NULL,
    can_load boolean NOT NULL,
    CONSTRAINT node_runtime_state_formats_pkey PRIMARY KEY (node_id, runtime, runtime_version, state_format_name, state_format_version),
    CONSTRAINT node_runtime_state_formats_node_id_runtime_runtime_version_fkey FOREIGN KEY (node_id, runtime, runtime_version) REFERENCES public.node_runtime_installations(node_id, runtime, runtime_version) ON DELETE CASCADE
);

CREATE TABLE public.node_status_snapshots (
    node_id uuid NOT NULL,
    observed_at timestamp with time zone NOT NULL,
    stale_after timestamp with time zone NOT NULL,
    reachable boolean NOT NULL,
    error text,
    role text,
    node_id_reported text,
    scheduling_status text,
    scheduling_reason text,
    network_slots_ready integer,
    network_pool_min_ready integer,
    network_slots_degraded integer,
    network_slots_quarantined integer,
    network_slots_total integer,
    network_slots_leased integer,
    network_pool_max_slots integer,
    health_healthy boolean,
    services jsonb NOT NULL,
    node_ctl jsonb,
    updated_at timestamp with time zone NOT NULL,
    sandbox_inventory_pruned_at timestamp with time zone,
    local_backup_inventory_reported_at timestamp with time zone,
    CONSTRAINT node_status_node_ctl_object CHECK (((node_ctl IS NULL) OR (jsonb_typeof(node_ctl) = 'object'::text))),
    CONSTRAINT node_status_services_array CHECK ((jsonb_typeof(services) = 'array'::text)),
    CONSTRAINT node_status_snapshots_pkey PRIMARY KEY (node_id),
    CONSTRAINT node_status_snapshots_node_id_fkey FOREIGN KEY (node_id) REFERENCES public.nodes(id) ON DELETE CASCADE
);

CREATE TABLE public.org_credentials (
    id uuid DEFAULT public.space_uuid_v7() NOT NULL,
    org_id uuid NOT NULL,
    key text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    value bytea NOT NULL,
    wrapped_key bytea NOT NULL,
    CONSTRAINT org_credentials_org_id_key_key UNIQUE (org_id, key),
    CONSTRAINT org_credentials_pkey PRIMARY KEY (id),
    CONSTRAINT org_credentials_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id) ON DELETE CASCADE
);

CREATE TABLE public.org_master_keys (
    id uuid DEFAULT public.space_uuid_v7() NOT NULL,
    org_id uuid NOT NULL,
    provider text NOT NULL,
    key_identifier text NOT NULL,
    retired_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT org_master_keys_id_org_id_key UNIQUE (id, org_id),
    CONSTRAINT org_master_keys_pkey PRIMARY KEY (id),
    CONSTRAINT org_master_keys_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id) ON DELETE CASCADE
);

CREATE TABLE public.org_branching_keys (
    cmk_id uuid NOT NULL,
    org_id uuid NOT NULL,
    wrapped_key bytea NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT org_branching_keys_pkey PRIMARY KEY (cmk_id),
    CONSTRAINT org_branching_keys_cmk_id_org_id_fkey FOREIGN KEY (cmk_id, org_id) REFERENCES public.org_master_keys(id, org_id) ON DELETE CASCADE
);

CREATE TABLE public.org_storage_vend_identities (
    org_id uuid NOT NULL,
    provider text NOT NULL,
    identity text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT org_storage_vend_identities_pkey PRIMARY KEY (org_id),
    CONSTRAINT org_storage_vend_identities_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id) ON DELETE CASCADE
);

CREATE TABLE public.sandbox_observed_states (
    sandbox_id uuid NOT NULL,
    node_id uuid NOT NULL,
    status text,
    runtime text,
    pid integer,
    namespace text,
    uptime text,
    sandbox_user text,
    sandbox_owner text,
    image_hash text,
    snapshots_enabled boolean DEFAULT false NOT NULL,
    disk_usage_bytes bigint,
    pool_template text,
    failure_reason text,
    observed_created_at text,
    network_tx_bytes bigint,
    network_rx_bytes bigint,
    observed_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    missing_publish_count integer DEFAULT 0 NOT NULL,
    template text,
    network_policy_authority text,
    auto_lifecycle_authority text,
    runtime_version text,
    guest_os text,
    guest_arch text,
    state_format_name text,
    state_format_version text,
    execution_metadata jsonb,
    spaced_version text,
    CONSTRAINT sandbox_observed_states_auto_lifecycle_authority_check CHECK (((auto_lifecycle_authority IS NULL) OR (auto_lifecycle_authority = ANY (ARRAY['cluster'::text, 'local'::text])))),
    CONSTRAINT sandbox_observed_states_network_policy_authority_check CHECK (((network_policy_authority IS NULL) OR (network_policy_authority = ANY (ARRAY['cluster'::text, 'local'::text])))),
    CONSTRAINT sandbox_observed_states_pkey PRIMARY KEY (sandbox_id),
    CONSTRAINT sandbox_observed_states_node_id_fkey FOREIGN KEY (node_id) REFERENCES public.nodes(id) ON DELETE CASCADE
);

CREATE TABLE public.sandbox_quarantine_history (
    id uuid NOT NULL,
    quarantine_id uuid NOT NULL,
    sandbox_id uuid NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    source text NOT NULL,
    action text NOT NULL,
    reason_code text,
    message text,
    next_action text,
    next_action_after timestamp with time zone,
    attempt_count bigint,
    claim_token uuid,
    evidence jsonb DEFAULT '{}'::jsonb NOT NULL,
    error text,
    CONSTRAINT sandbox_quarantine_history_attempt_count_nonnegative CHECK (((attempt_count IS NULL) OR (attempt_count >= 0))),
    CONSTRAINT sandbox_quarantine_history_evidence_object CHECK ((jsonb_typeof(evidence) = 'object'::text)),
    CONSTRAINT sandbox_quarantine_history_pkey PRIMARY KEY (id)
);

CREATE TABLE public.sandbox_snapshot_inventory (
    sandbox_id uuid NOT NULL,
    snapshot_id text NOT NULL,
    type text NOT NULL,
    state text NOT NULL,
    "timestamp" text,
    source_node_id text,
    label text,
    retention_tier text,
    vcpu integer,
    memory_mib integer,
    size_bytes bigint DEFAULT 0 NOT NULL,
    template_id text,
    content_hash text,
    locations jsonb DEFAULT '[]'::jsonb NOT NULL,
    observed_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT sandbox_snapshot_inventory_locations_array CHECK ((jsonb_typeof(locations) = 'array'::text)),
    CONSTRAINT sandbox_snapshot_inventory_pkey PRIMARY KEY (sandbox_id, snapshot_id),
    CONSTRAINT sandbox_snapshot_inventory_sandbox_id_fkey FOREIGN KEY (sandbox_id) REFERENCES public.sandbox_observed_states(sandbox_id) ON DELETE CASCADE
);

CREATE TABLE public.template_build_blobs (
    template_id text NOT NULL,
    files_hash text NOT NULL,
    blob_sha256 text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    org_id uuid,
    CONSTRAINT template_build_blobs_pkey PRIMARY KEY (template_id, files_hash)
);

CREATE TABLE public.template_build_jobs (
    template_id text NOT NULL,
    build_id text NOT NULL,
    daemon_job_id text,
    cpu_count integer,
    memory_mb integer,
    tags text[] DEFAULT '{}'::text[] NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    builder_node_id uuid,
    org_id uuid,
    CONSTRAINT template_build_jobs_pkey PRIMARY KEY (template_id, build_id),
    CONSTRAINT template_build_jobs_builder_node_id_fkey FOREIGN KEY (builder_node_id) REFERENCES public.nodes(id) ON DELETE SET NULL
);

CREATE TABLE public.users (
    id uuid DEFAULT public.space_uuid_v7() NOT NULL,
    email text NOT NULL,
    password_hash text NOT NULL,
    display_name text NOT NULL,
    org_id uuid NOT NULL,
    role text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    owner_source text DEFAULT 'local'::text NOT NULL,
    upstream_issuer text,
    upstream_subject_id text,
    CONSTRAINT users_owner_identity_shape_check CHECK ((((owner_source = 'local'::text) AND (upstream_issuer IS NULL) AND (upstream_subject_id IS NULL)) OR ((owner_source = 'federated_identity'::text) AND (upstream_issuer IS NOT NULL) AND (upstream_subject_id IS NOT NULL) AND ((char_length(upstream_issuer) >= 1) AND (char_length(upstream_issuer) <= 128)) AND ((char_length(upstream_subject_id) >= 1) AND (char_length(upstream_subject_id) <= 128))))),
    CONSTRAINT users_owner_source_check CHECK ((owner_source = ANY (ARRAY['local'::text, 'federated_identity'::text]))),
    CONSTRAINT users_role_check CHECK ((role = ANY (ARRAY['organization_admin'::text, 'member'::text]))),
    CONSTRAINT users_email_key UNIQUE (email),
    CONSTRAINT users_pkey PRIMARY KEY (id),
    CONSTRAINT users_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id)
);

CREATE TABLE public.api_keys (
    id uuid DEFAULT public.space_uuid_v7() NOT NULL,
    org_id uuid NOT NULL,
    name text NOT NULL,
    key_hash text NOT NULL,
    created_by uuid,
    last_used_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    federated_owner_assertions_enabled boolean DEFAULT false NOT NULL,
    allowed_surfaces text[] DEFAULT ARRAY['ecw'::text] NOT NULL,
    CONSTRAINT api_keys_allowed_surfaces_known CHECK (((cardinality(allowed_surfaces) > 0) AND (allowed_surfaces <@ ARRAY['ecw'::text, 'native'::text]))),
    CONSTRAINT api_keys_key_hash_key UNIQUE (key_hash),
    CONSTRAINT api_keys_pkey PRIMARY KEY (id),
    CONSTRAINT api_keys_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE SET NULL,
    CONSTRAINT api_keys_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id) ON DELETE CASCADE
);

CREATE TABLE public.public_operations (
    operation_id uuid NOT NULL,
    org_id uuid NOT NULL,
    actor_user_id uuid,
    api_product text DEFAULT 'native'::text NOT NULL,
    kind text NOT NULL,
    target_type text,
    target_id text,
    state text DEFAULT 'queued'::text NOT NULL,
    progress_message text DEFAULT ''::text NOT NULL,
    terminal_error_code text,
    terminal_error_json jsonb,
    result_json jsonb,
    payload_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    claim_token text DEFAULT ''::text NOT NULL,
    claim_generation bigint DEFAULT 0 NOT NULL,
    claimed_at timestamp with time zone,
    next_attempt_at timestamp with time zone DEFAULT now() NOT NULL,
    requested_at timestamp with time zone DEFAULT now() NOT NULL,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    gc_after timestamp with time zone DEFAULT (now() + '7 days'::interval) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT public_operations_state_check CHECK ((state = ANY (ARRAY['queued'::text, 'running'::text, 'succeeded'::text, 'failed'::text, 'canceled'::text, 'expired'::text]))),
    CONSTRAINT public_operations_target_type_check CHECK (((target_type IS NULL) OR (target_type = ANY (ARRAY['sandbox'::text, 'session'::text, 'template'::text, 'snapshot'::text, 'volume'::text])))),
    CONSTRAINT public_operations_pkey PRIMARY KEY (operation_id),
    CONSTRAINT public_operations_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES public.users(id) ON DELETE SET NULL,
    CONSTRAINT public_operations_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id) ON DELETE CASCADE
);

CREATE TABLE public.public_idempotency_records (
    id uuid NOT NULL,
    org_id uuid NOT NULL,
    api_product text DEFAULT 'native'::text NOT NULL,
    method text NOT NULL,
    path_template text NOT NULL,
    idempotency_key text NOT NULL,
    request_fingerprint text NOT NULL,
    operation_id uuid,
    response_json jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone DEFAULT (now() + '24:00:00'::interval) NOT NULL,
    CONSTRAINT public_idempotency_records_fingerprint_check CHECK ((request_fingerprint ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT public_idempotency_records_response_check CHECK (((operation_id IS NOT NULL) OR (response_json IS NOT NULL))),
    CONSTRAINT public_idempotency_records_pkey PRIMARY KEY (id),
    CONSTRAINT public_idempotency_records_operation_id_fkey FOREIGN KEY (operation_id) REFERENCES public.public_operations(operation_id) ON DELETE SET NULL,
    CONSTRAINT public_idempotency_records_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id) ON DELETE CASCADE
);

CREATE TABLE public.public_operation_events (
    operation_id uuid NOT NULL,
    sequence bigint NOT NULL,
    event_type text NOT NULL,
    event_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT public_operation_events_pkey PRIMARY KEY (operation_id, sequence),
    CONSTRAINT public_operation_events_operation_id_fkey FOREIGN KEY (operation_id) REFERENCES public.public_operations(operation_id) ON DELETE CASCADE
);

CREATE TABLE public.sandboxes (
    id uuid NOT NULL,
    name text,
    user_id uuid NOT NULL,
    org_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    managed_by text DEFAULT 'space'::text NOT NULL,
    lifecycle text DEFAULT 'creating'::text NOT NULL,
    placement text DEFAULT 'unplaced'::text NOT NULL,
    active_node_id uuid,
    target_node_id uuid,
    placement_changed_at timestamp with time zone,
    template_id text,
    content_hash text,
    env jsonb DEFAULT '{}'::jsonb NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    auto_lifecycle_json jsonb DEFAULT '{"wake": {"on": []}, "stages": [], "condition_sets": {}}'::jsonb NOT NULL,
    auto_lifecycle_state_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    next_auto_event_at bigint,
    vcpu integer,
    memory_mib integer,
    disk_mib integer,
    network_policy_override_json jsonb,
    network_policy_generation bigint NOT NULL,
    snapshots_enabled_desired boolean DEFAULT false NOT NULL,
    last_used_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    lifecycle_changed_at timestamp with time zone DEFAULT now() NOT NULL,
    evacuation_restore_target text,
    current_local_artifact_id uuid,
    current_local_artifact_kind text,
    current_local_artifact_origin text,
    command_ready_pending boolean DEFAULT false NOT NULL,
    restore_lease_expires_at timestamp with time zone,
    restore_lease_token uuid,
    restore_attempt_count integer DEFAULT 0 NOT NULL,
    next_restore_attempt_at timestamp with time zone,
    last_access_at timestamp with time zone,
    last_command_at timestamp with time zone,
    volume_encryption boolean,
    preserve_local_artifact_on_restore_failure boolean DEFAULT false NOT NULL,
    disk_io_max_operations_per_sec bigint DEFAULT 1000 NOT NULL,
    disk_io_max_bandwidth_mib_per_sec bigint DEFAULT 100 NOT NULL,
    CONSTRAINT sandboxes_current_local_artifact_identity_check CHECK ((((current_local_artifact_id IS NULL) AND (current_local_artifact_kind IS NULL) AND (current_local_artifact_origin IS NULL)) OR ((current_local_artifact_id IS NOT NULL) AND (current_local_artifact_kind IS NOT NULL) AND (current_local_artifact_origin IS NOT NULL)))),
    CONSTRAINT sandboxes_current_local_artifact_kind_check CHECK (((current_local_artifact_kind IS NULL) OR (current_local_artifact_kind = ANY (ARRAY['disk'::text, 'full'::text])))),
    CONSTRAINT sandboxes_current_local_artifact_origin_check CHECK (((current_local_artifact_origin IS NULL) OR (current_local_artifact_origin = ANY (ARRAY['stop'::text, 'suspend'::text])))),
    CONSTRAINT sandboxes_disk_io_max_bandwidth_mib_per_sec_positive CHECK ((disk_io_max_bandwidth_mib_per_sec > 0)),
    CONSTRAINT sandboxes_disk_io_max_operations_per_sec_positive CHECK ((disk_io_max_operations_per_sec > 0)),
    CONSTRAINT sandboxes_evacuation_restore_target_check CHECK (((evacuation_restore_target IS NULL) OR (evacuation_restore_target = ANY (ARRAY['started'::text, 'paused'::text])))),
    CONSTRAINT sandboxes_managed_by_check CHECK ((managed_by = ANY (ARRAY['space'::text, 'k8s'::text]))),
    CONSTRAINT sandboxes_metadata_is_object CHECK ((jsonb_typeof(metadata) = 'object'::text)),
    CONSTRAINT sandboxes_restore_lease_pair CHECK (((restore_lease_expires_at IS NULL) = (restore_lease_token IS NULL))),
    CONSTRAINT sandboxes_id_org_id_key UNIQUE (id, org_id),
    CONSTRAINT sandboxes_pkey PRIMARY KEY (id),
    CONSTRAINT sandboxes_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id),
    CONSTRAINT sandboxes_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id)
);

CREATE TABLE public.data_plane_sessions (
    session_id text NOT NULL,
    protocol_session_id text,
    org_id uuid NOT NULL,
    sandbox_id uuid NOT NULL,
    kind text NOT NULL,
    state text DEFAULT 'open'::text NOT NULL,
    route_generation bigint DEFAULT 1 NOT NULL,
    current_node_id uuid,
    backend_endpoint text,
    backend_transport text,
    revocation_epoch bigint DEFAULT 0 NOT NULL,
    revocation_status text DEFAULT 'active'::text NOT NULL,
    revocation_reason text,
    revocation_updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone,
    actor_user_id uuid,
    scopes text[] DEFAULT '{}'::text[] NOT NULL,
    token_hash text,
    token_expires_at timestamp with time zone,
    attach_deadline_at timestamp with time zone,
    target_port integer,
    target_protocol text,
    target_path text,
    adapter_state jsonb DEFAULT '{}'::jsonb NOT NULL,
    output_cursor bigint DEFAULT 0 NOT NULL,
    input_sequence bigint DEFAULT 0 NOT NULL,
    reconnect_count bigint DEFAULT 0 NOT NULL,
    last_reconnect_reason text,
    backend_process_id text,
    backend_process_bound_at timestamp with time zone,
    backend_output_cursor bigint DEFAULT 0 NOT NULL,
    CONSTRAINT data_plane_sessions_backend_output_cursor_check CHECK ((backend_output_cursor >= 0)),
    CONSTRAINT data_plane_sessions_input_sequence_check CHECK ((input_sequence >= 0)),
    CONSTRAINT data_plane_sessions_kind_check CHECK ((kind = ANY (ARRAY['terminal'::text, 'process'::text, 'file_watch'::text, 'port'::text, 'protocol'::text]))),
    CONSTRAINT data_plane_sessions_output_cursor_check CHECK ((output_cursor >= 0)),
    CONSTRAINT data_plane_sessions_reconnect_count_check CHECK ((reconnect_count >= 0)),
    CONSTRAINT data_plane_sessions_revocation_epoch_check CHECK ((revocation_epoch >= 0)),
    CONSTRAINT data_plane_sessions_revocation_status_check CHECK ((revocation_status = ANY (ARRAY['active'::text, 'revoking'::text, 'revoked'::text]))),
    CONSTRAINT data_plane_sessions_route_generation_check CHECK ((route_generation >= 1)),
    CONSTRAINT data_plane_sessions_state_check CHECK ((state = ANY (ARRAY['pending'::text, 'attaching'::text, 'open'::text, 'reconnecting'::text, 'closing'::text, 'closed'::text, 'revoked'::text, 'failed'::text]))),
    CONSTRAINT data_plane_sessions_target_port_check CHECK (((target_port >= 1) AND (target_port <= 65535))),
    CONSTRAINT data_plane_sessions_pkey PRIMARY KEY (session_id),
    CONSTRAINT data_plane_sessions_protocol_session_id_key UNIQUE (protocol_session_id),
    CONSTRAINT data_plane_sessions_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES public.users(id) ON DELETE SET NULL,
    CONSTRAINT data_plane_sessions_current_node_id_fkey FOREIGN KEY (current_node_id) REFERENCES public.nodes(id) ON DELETE SET NULL,
    CONSTRAINT data_plane_sessions_sandbox_id_fkey FOREIGN KEY (sandbox_id) REFERENCES public.sandboxes(id) ON DELETE CASCADE
);

CREATE TABLE public.data_plane_session_output_events (
    session_id text NOT NULL,
    sequence bigint NOT NULL,
    event_name text NOT NULL,
    frame jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT data_plane_session_output_events_sequence_check CHECK ((sequence > 0)),
    CONSTRAINT data_plane_session_output_events_pkey PRIMARY KEY (session_id, sequence),
    CONSTRAINT data_plane_session_output_events_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.data_plane_sessions(session_id) ON DELETE CASCADE
);

CREATE TABLE public.node_local_backup_pending (
    node_id uuid NOT NULL,
    sandbox_id uuid NOT NULL,
    artifact_id uuid NOT NULL,
    artifact_kind text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT node_local_backup_pending_artifact_kind_check CHECK ((artifact_kind = ANY (ARRAY['disk'::text, 'full'::text]))),
    CONSTRAINT node_local_backup_pending_pkey PRIMARY KEY (node_id, sandbox_id),
    CONSTRAINT node_local_backup_pending_sandbox_id_fkey FOREIGN KEY (sandbox_id) REFERENCES public.sandboxes(id) ON DELETE CASCADE
);

CREATE TABLE public.sandbox_credential_injection_rules (
    sandbox_id uuid NOT NULL,
    version bigint NOT NULL,
    rules bytea NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT sandbox_credential_injection_rules_pkey PRIMARY KEY (sandbox_id),
    CONSTRAINT sandbox_credential_injection_rules_sandbox_id_fkey FOREIGN KEY (sandbox_id) REFERENCES public.sandboxes(id) ON DELETE CASCADE
);

CREATE TABLE public.sandbox_direct_route_identities (
    sandbox_id uuid NOT NULL,
    route_generation bigint NOT NULL,
    current_node_id uuid NOT NULL,
    substrate_kind text NOT NULL,
    execution_generation bigint NOT NULL,
    activation_attempt_id uuid NOT NULL,
    pod_uid text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT sandbox_direct_route_identities_execution_generation_check CHECK ((execution_generation > 0)),
    CONSTRAINT sandbox_direct_route_identities_pod_uid_check CHECK ((pod_uid IS NULL)),
    CONSTRAINT sandbox_direct_route_identities_route_generation_check CHECK ((route_generation > 0)),
    CONSTRAINT sandbox_direct_route_identities_substrate_kind_check CHECK ((substrate_kind = 'space'::text)),
    CONSTRAINT sandbox_direct_route_identities_pkey PRIMARY KEY (sandbox_id),
    CONSTRAINT sandbox_direct_route_identities_sandbox_id_fkey FOREIGN KEY (sandbox_id) REFERENCES public.sandboxes(id) ON DELETE CASCADE
);

CREATE TABLE public.sandbox_direct_route_provenance (
    sandbox_id uuid NOT NULL,
    last_route_generation bigint NOT NULL,
    last_execution_generation bigint NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT sandbox_direct_route_provenance_last_execution_generation_check CHECK ((last_execution_generation > 0)),
    CONSTRAINT sandbox_direct_route_provenance_last_route_generation_check CHECK ((last_route_generation > 0)),
    CONSTRAINT sandbox_direct_route_provenance_pkey PRIMARY KEY (sandbox_id),
    CONSTRAINT sandbox_direct_route_provenance_sandbox_id_fkey FOREIGN KEY (sandbox_id) REFERENCES public.sandboxes(id) ON DELETE CASCADE
);

CREATE TABLE public.sandbox_ecw_credential_epochs (
    sandbox_id uuid NOT NULL,
    epoch bigint DEFAULT 1 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT sandbox_ecw_credential_epochs_epoch_check CHECK ((epoch > 0)),
    CONSTRAINT sandbox_ecw_credential_epochs_pkey PRIMARY KEY (sandbox_id),
    CONSTRAINT sandbox_ecw_credential_epochs_sandbox_id_fkey FOREIGN KEY (sandbox_id) REFERENCES public.sandboxes(id) ON DELETE CASCADE
);

CREATE TABLE public.sandbox_encrypted_fields (
    id uuid DEFAULT public.space_uuid_v7() NOT NULL,
    sandbox_id uuid NOT NULL,
    org_id uuid NOT NULL,
    master_key_id uuid NOT NULL,
    wrapped_dek bytea NOT NULL,
    env bytea NOT NULL,
    metadata bytea NOT NULL,
    network_policy_override_json bytea,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT sandbox_encrypted_fields_pkey PRIMARY KEY (id),
    CONSTRAINT sandbox_encrypted_fields_sandbox_id_key UNIQUE (sandbox_id),
    CONSTRAINT sandbox_encrypted_fields_master_key_id_org_id_fkey FOREIGN KEY (master_key_id, org_id) REFERENCES public.org_master_keys(id, org_id) ON DELETE RESTRICT,
    CONSTRAINT sandbox_encrypted_fields_sandbox_id_org_id_fkey FOREIGN KEY (sandbox_id, org_id) REFERENCES public.sandboxes(id, org_id) ON DELETE CASCADE
);

CREATE TABLE public.sandbox_federated_service_grants (
    sandbox_id uuid NOT NULL,
    grant_audience text NOT NULL,
    grant_purpose text NOT NULL,
    grant_blob bytea NOT NULL,
    grant_expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    grant_issued_at timestamp with time zone,
    CONSTRAINT sandbox_federated_service_grants_audience_nonempty CHECK ((grant_audience <> ''::text)),
    CONSTRAINT sandbox_federated_service_grants_blob_size CHECK (((octet_length(grant_blob) >= 1) AND (octet_length(grant_blob) <= 65536))),
    CONSTRAINT sandbox_federated_service_grants_expires_after_update CHECK ((grant_expires_at > updated_at)),
    CONSTRAINT sandbox_federated_service_grants_purpose_nonempty CHECK ((grant_purpose <> ''::text)),
    CONSTRAINT sandbox_federated_service_grants_pkey PRIMARY KEY (sandbox_id, grant_audience, grant_purpose),
    CONSTRAINT sandbox_federated_service_grants_sandbox_id_fkey FOREIGN KEY (sandbox_id) REFERENCES public.sandboxes(id) ON DELETE CASCADE
);

CREATE TABLE public.sandbox_k8s_executions (
    id uuid DEFAULT public.space_uuid_v7() NOT NULL,
    sandbox_id uuid NOT NULL,
    generation bigint NOT NULL,
    pod_name text NOT NULL,
    pod_namespace text NOT NULL,
    pod_uid text,
    pod_ip inet,
    k8s_node_name text,
    state text DEFAULT 'creating'::text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    terminated_at timestamp with time zone,
    activation_attempt_id uuid,
    activation_attempt_expires_at timestamp with time zone,
    activation_attempt_target_state text,
    route_activation_id uuid,
    CONSTRAINT sandbox_k8s_executions_pkey PRIMARY KEY (id),
    CONSTRAINT sandbox_k8s_executions_sandbox_id_fkey FOREIGN KEY (sandbox_id) REFERENCES public.sandboxes(id) ON DELETE CASCADE
);

CREATE TABLE public.sandbox_network_credential_injection_ruleset_version (
    sandbox_id uuid NOT NULL,
    version bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT sandbox_network_credential_injection_ruleset_vers_version_check CHECK ((version > 0)),
    CONSTRAINT sandbox_network_credential_injection_ruleset_version_pkey PRIMARY KEY (sandbox_id),
    CONSTRAINT sandbox_network_credential_injection_ruleset_ve_sandbox_id_fkey FOREIGN KEY (sandbox_id) REFERENCES public.sandboxes(id) ON DELETE CASCADE
);

CREATE TABLE public.sandbox_network_credential_injection_rules (
    sandbox_id uuid NOT NULL,
    rule_id text NOT NULL,
    credential_reference_id uuid NOT NULL,
    transformation_rule jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT sandbox_network_credential_injection_rules_pkey PRIMARY KEY (sandbox_id, rule_id),
    CONSTRAINT sandbox_network_credential_injecti_credential_reference_id_fkey FOREIGN KEY (credential_reference_id) REFERENCES public.credential_references(id),
    CONSTRAINT sandbox_network_credential_injection_rules_sandbox_id_fkey FOREIGN KEY (sandbox_id) REFERENCES public.sandbox_network_credential_injection_ruleset_version(sandbox_id) ON DELETE CASCADE
);

CREATE TABLE public.sandbox_port_exposures (
    sandbox_id uuid NOT NULL,
    protocol text NOT NULL,
    guest_port integer NOT NULL,
    visibility text NOT NULL,
    source text NOT NULL,
    desired_state text NOT NULL,
    apply_state text NOT NULL,
    last_applied_node_id uuid,
    last_error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    last_bridge_status text,
    last_applied_bridge_generation text,
    last_observed_at timestamp with time zone,
    CONSTRAINT sandbox_port_exposures_apply_state_check CHECK ((apply_state = ANY (ARRAY['pending'::text, 'applied'::text, 'failed'::text]))),
    CONSTRAINT sandbox_port_exposures_desired_state_check CHECK ((desired_state = ANY (ARRAY['open'::text, 'closed'::text]))),
    CONSTRAINT sandbox_port_exposures_guest_port_check CHECK (((guest_port >= 1) AND (guest_port <= 65535))),
    CONSTRAINT sandbox_port_exposures_last_bridge_status_check CHECK (((last_bridge_status IS NULL) OR (last_bridge_status = ANY (ARRAY['direct'::text, 'loopback_forwarded'::text, 'waiting_for_listener'::text, 'bind_conflict'::text, 'failed'::text])))),
    CONSTRAINT sandbox_port_exposures_protocol_check CHECK ((protocol = 'tcp'::text)),
    CONSTRAINT sandbox_port_exposures_visibility_check CHECK ((visibility = ANY (ARRAY['private'::text, 'public'::text]))),
    CONSTRAINT sandbox_port_exposures_pkey PRIMARY KEY (sandbox_id, protocol, guest_port),
    CONSTRAINT sandbox_port_exposures_sandbox_id_fkey FOREIGN KEY (sandbox_id) REFERENCES public.sandboxes(id) ON DELETE CASCADE
);

CREATE TABLE public.sandbox_quarantine_state (
    sandbox_id uuid NOT NULL,
    quarantine_id uuid NOT NULL,
    entered_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    entered_from_lifecycle text,
    source text NOT NULL,
    reason_code text NOT NULL,
    reason_message text,
    evidence jsonb DEFAULT '{}'::jsonb NOT NULL,
    next_action text NOT NULL,
    next_action_after timestamp with time zone,
    next_action_owner text,
    attempt_count bigint DEFAULT 0 NOT NULL,
    claim_token uuid,
    claim_expires_at timestamp with time zone,
    last_error text,
    last_observed_node_id uuid,
    CONSTRAINT sandbox_quarantine_state_attempt_count_nonnegative CHECK ((attempt_count >= 0)),
    CONSTRAINT sandbox_quarantine_state_evidence_object CHECK ((jsonb_typeof(evidence) = 'object'::text)),
    CONSTRAINT sandbox_quarantine_state_pkey PRIMARY KEY (sandbox_id),
    CONSTRAINT sandbox_quarantine_state_quarantine_id_key UNIQUE (quarantine_id),
    CONSTRAINT sandbox_quarantine_state_last_observed_node_id_fkey FOREIGN KEY (last_observed_node_id) REFERENCES public.nodes(id) ON DELETE SET NULL,
    CONSTRAINT sandbox_quarantine_state_sandbox_id_fkey FOREIGN KEY (sandbox_id) REFERENCES public.sandboxes(id) ON DELETE CASCADE
);

CREATE TABLE public.sandbox_volume_encryption (
    id uuid DEFAULT public.space_uuid_v7() NOT NULL,
    sandbox_id uuid NOT NULL,
    org_id uuid NOT NULL,
    master_key_id uuid NOT NULL,
    wrapped_dek bytea NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT sandbox_volume_encryption_pkey PRIMARY KEY (id),
    CONSTRAINT sandbox_volume_encryption_sandbox_id_key UNIQUE (sandbox_id),
    CONSTRAINT sandbox_volume_encryption_master_key_id_org_id_fkey FOREIGN KEY (master_key_id, org_id) REFERENCES public.org_master_keys(id, org_id) ON DELETE RESTRICT,
    CONSTRAINT sandbox_volume_encryption_sandbox_id_org_id_fkey FOREIGN KEY (sandbox_id, org_id) REFERENCES public.sandboxes(id, org_id) ON DELETE CASCADE
);

CREATE TABLE public.sessions (
    id uuid DEFAULT public.space_uuid_v7() NOT NULL,
    user_id uuid NOT NULL,
    token_hash text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT sessions_pkey PRIMARY KEY (id),
    CONSTRAINT sessions_token_hash_key UNIQUE (token_hash),
    CONSTRAINT sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE
);

CREATE TABLE public.snapshots (
    id uuid DEFAULT public.space_uuid_v7() NOT NULL,
    sandbox_id uuid NOT NULL,
    type text NOT NULL,
    state text DEFAULT 'creating'::text NOT NULL,
    "timestamp" timestamp with time zone DEFAULT now() NOT NULL,
    source_node_id uuid,
    label text,
    retention_tier text,
    vcpu integer,
    memory_mib integer,
    size_bytes bigint,
    template_id text,
    content_hash text,
    org_id uuid,
    failure_reason text,
    last_attempt_at timestamp with time zone,
    local_artifact_id uuid,
    artifact_kind text,
    artifact_origin text,
    artifact_snapshot_name text,
    runtime text,
    runtime_version text,
    guest_os text,
    guest_arch text,
    state_format_name text,
    state_format_version text,
    execution_metadata jsonb,
    generation bigint,
    CONSTRAINT snapshots_artifact_kind_check CHECK (((artifact_kind IS NULL) OR (artifact_kind = ANY (ARRAY['disk'::text, 'full'::text])))),
    CONSTRAINT snapshots_artifact_origin_snapshot_name_check CHECK (((artifact_origin IS NULL) OR ((artifact_origin = 'snapshot'::text) AND (artifact_snapshot_name IS NOT NULL)) OR ((artifact_origin <> 'snapshot'::text) AND (artifact_snapshot_name IS NULL)))),
    CONSTRAINT snapshots_state_check CHECK ((state = ANY (ARRAY['creating'::text, 'ready'::text, 'failed'::text, 'deleting'::text]))),
    CONSTRAINT snapshots_type_check CHECK ((type = ANY (ARRAY['disk'::text, 'full'::text]))),
    CONSTRAINT snapshots_id_org_id_key UNIQUE (id, org_id),
    CONSTRAINT snapshots_pkey PRIMARY KEY (id),
    CONSTRAINT snapshots_sandbox_id_fkey FOREIGN KEY (sandbox_id) REFERENCES public.sandboxes(id) ON DELETE CASCADE,
    CONSTRAINT snapshots_sandbox_id_org_id_fkey FOREIGN KEY (sandbox_id, org_id) REFERENCES public.sandboxes(id, org_id) ON DELETE CASCADE
);

CREATE TABLE public.snapshot_storage_locations (
    id uuid DEFAULT public.space_uuid_v7() NOT NULL,
    snapshot_id uuid,
    storage_connection_string text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    org_id uuid,
    orphaned_at timestamp with time zone,
    CONSTRAINT snapshot_storage_locations_id_org_id_key UNIQUE (id, org_id),
    CONSTRAINT snapshot_storage_locations_pkey PRIMARY KEY (id),
    CONSTRAINT snapshot_storage_locations_snapshot_id_fkey FOREIGN KEY (snapshot_id) REFERENCES public.snapshots(id) ON DELETE RESTRICT,
    CONSTRAINT snapshot_storage_locations_snapshot_id_org_id_fkey FOREIGN KEY (snapshot_id, org_id) REFERENCES public.snapshots(id, org_id) ON DELETE RESTRICT
);

CREATE TABLE public.snapshot_storage_location_encrypted_fields (
    id uuid DEFAULT public.space_uuid_v7() NOT NULL,
    snapshot_storage_location_id uuid NOT NULL,
    org_id uuid NOT NULL,
    master_key_id uuid NOT NULL,
    wrapped_dek bytea NOT NULL,
    storage_connection_string bytea NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT snapshot_storage_location_encr_snapshot_storage_location_id_key UNIQUE (snapshot_storage_location_id),
    CONSTRAINT snapshot_storage_location_encrypted_fields_pkey PRIMARY KEY (id),
    CONSTRAINT snapshot_storage_location_encrypted_fields_kek_fkey FOREIGN KEY (master_key_id, org_id) REFERENCES public.org_master_keys(id, org_id) ON DELETE RESTRICT,
    CONSTRAINT snapshot_storage_location_encrypted_fields_loc_fkey FOREIGN KEY (snapshot_storage_location_id, org_id) REFERENCES public.snapshot_storage_locations(id, org_id) ON DELETE CASCADE
);

CREATE TABLE public.templates (
    name text NOT NULL,
    description text,
    org_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    network_policy_json jsonb DEFAULT '{"egress": {"default_action": "deny"}, "version": "v1"}'::jsonb NOT NULL,
    network_policy_generation bigint DEFAULT 1 NOT NULL,
    id uuid NOT NULL,
    last_used_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    visibility text DEFAULT 'generic'::text NOT NULL,
    desired_state text DEFAULT 'present'::text NOT NULL,
    delete_requested_at timestamp with time zone,
    delete_requested_by uuid,
    delete_operation_id uuid,
    CONSTRAINT org_specific_requires_owner CHECK (((visibility <> 'org_specific'::text) OR (org_id IS NOT NULL))),
    CONSTRAINT templates_desired_state_check CHECK ((desired_state = ANY (ARRAY['present'::text, 'deleting'::text, 'deleted'::text]))),
    CONSTRAINT templates_id_uuid_v7 CHECK (((get_byte(uuid_send(id), 6) >> 4) = 7)),
    CONSTRAINT templates_visibility_check CHECK ((visibility = ANY (ARRAY['generic'::text, 'org_specific'::text]))),
    CONSTRAINT templates_name_key UNIQUE (name),
    CONSTRAINT templates_name_org_id_key UNIQUE (name, org_id),
    CONSTRAINT templates_pkey PRIMARY KEY (id),
    CONSTRAINT templates_delete_operation_id_fkey FOREIGN KEY (delete_operation_id) REFERENCES public.public_operations(operation_id) ON DELETE SET NULL,
    CONSTRAINT templates_delete_requested_by_fkey FOREIGN KEY (delete_requested_by) REFERENCES public.users(id) ON DELETE SET NULL,
    CONSTRAINT templates_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id)
);

CREATE TABLE public.node_group_template_compat (
    node_group_id uuid NOT NULL,
    template_name text NOT NULL,
    CONSTRAINT node_group_template_compat_pkey PRIMARY KEY (node_group_id, template_name),
    CONSTRAINT node_group_template_compat_node_group_id_fkey FOREIGN KEY (node_group_id) REFERENCES public.node_groups(id) ON DELETE CASCADE,
    CONSTRAINT node_group_template_compat_template_name_fkey FOREIGN KEY (template_name) REFERENCES public.templates(name) ON DELETE CASCADE
);

CREATE TABLE public.node_template_inventory (
    node_id uuid NOT NULL,
    template_name text NOT NULL,
    content_hash text DEFAULT ''::text NOT NULL,
    runtime text,
    arch text,
    built_at text,
    artifact_size_bytes bigint,
    has_base_snapshot boolean DEFAULT false NOT NULL,
    base_snapshot_size_bytes bigint,
    pool_target integer,
    pool_current integer DEFAULT 0 NOT NULL,
    pool_pending integer DEFAULT 0 NOT NULL,
    pool_sandbox_ids jsonb DEFAULT '[]'::jsonb NOT NULL,
    snapshots jsonb DEFAULT '[]'::jsonb NOT NULL,
    default_auto_lifecycle_json jsonb,
    ensure_base_snapshot boolean,
    snapshot_vcpu integer,
    snapshot_memory_mib integer,
    observed_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    missing_publish_count integer DEFAULT 0 NOT NULL,
    vcpu integer,
    memory_mib integer,
    disk_size_mb integer,
    cache_size_bytes bigint,
    network_policy_authority text,
    default_auto_lifecycle_authority text,
    runtime_version text,
    guest_os text,
    state_format_name text,
    state_format_version text,
    execution_metadata jsonb,
    CONSTRAINT node_template_inventory_default_auto_lifecycle_authority_check CHECK (((default_auto_lifecycle_authority IS NULL) OR (default_auto_lifecycle_authority = ANY (ARRAY['cluster'::text, 'local'::text])))),
    CONSTRAINT node_template_inventory_network_policy_authority_check CHECK (((network_policy_authority IS NULL) OR (network_policy_authority = ANY (ARRAY['cluster'::text, 'local'::text])))),
    CONSTRAINT node_template_inventory_pool_ids_array CHECK ((jsonb_typeof(pool_sandbox_ids) = 'array'::text)),
    CONSTRAINT node_template_inventory_snapshots_array CHECK ((jsonb_typeof(snapshots) = 'array'::text)),
    CONSTRAINT node_template_inventory_pkey PRIMARY KEY (node_id, template_name, content_hash),
    CONSTRAINT node_template_inventory_node_id_fkey FOREIGN KEY (node_id) REFERENCES public.nodes(id) ON DELETE CASCADE,
    CONSTRAINT node_template_inventory_template_name_fkey FOREIGN KEY (template_name) REFERENCES public.templates(name) ON DELETE CASCADE
);

CREATE TABLE public.node_template_components (
    node_id uuid NOT NULL,
    template_name text NOT NULL,
    content_hash text DEFAULT ''::text NOT NULL,
    kind text NOT NULL,
    role_key text DEFAULT ''::text NOT NULL,
    version text,
    digest text,
    format text,
    CONSTRAINT node_template_components_pkey PRIMARY KEY (node_id, template_name, content_hash, kind, role_key),
    CONSTRAINT node_template_components_node_id_template_name_content_has_fkey FOREIGN KEY (node_id, template_name, content_hash) REFERENCES public.node_template_inventory(node_id, template_name, content_hash) ON DELETE CASCADE
);

CREATE TABLE public.template_base_snapshot_policies (
    template text NOT NULL,
    ensure_base_snapshot boolean DEFAULT false NOT NULL,
    snapshot_vcpu integer DEFAULT 2 NOT NULL,
    snapshot_memory_mib integer DEFAULT 1024 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT template_base_snapshot_policies_snapshot_memory_mib_check CHECK ((snapshot_memory_mib > 0)),
    CONSTRAINT template_base_snapshot_policies_snapshot_vcpu_check CHECK ((snapshot_vcpu > 0)),
    CONSTRAINT template_base_snapshot_policies_pkey PRIMARY KEY (template),
    CONSTRAINT template_base_snapshot_policies_template_fkey FOREIGN KEY (template) REFERENCES public.templates(name) ON DELETE CASCADE
);

CREATE TABLE public.template_default_auto_lifecycle_policies (
    template text NOT NULL,
    default_auto_lifecycle_json jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT template_default_auto_lifecycle_policies_pkey PRIMARY KEY (template),
    CONSTRAINT template_default_auto_lifecycle_policies_template_fkey FOREIGN KEY (template) REFERENCES public.templates(name) ON DELETE CASCADE
);

CREATE TABLE public.template_encrypted_fields (
    id uuid DEFAULT public.space_uuid_v7() NOT NULL,
    template_name text NOT NULL,
    org_id uuid NOT NULL,
    master_key_id uuid NOT NULL,
    wrapped_dek bytea NOT NULL,
    description bytea,
    network_policy_json bytea NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT template_encrypted_fields_pkey PRIMARY KEY (id),
    CONSTRAINT template_encrypted_fields_template_name_key UNIQUE (template_name),
    CONSTRAINT template_encrypted_fields_master_key_id_org_id_fkey FOREIGN KEY (master_key_id, org_id) REFERENCES public.org_master_keys(id, org_id) ON DELETE RESTRICT,
    CONSTRAINT template_encrypted_fields_template_name_org_id_fkey FOREIGN KEY (template_name, org_id) REFERENCES public.templates(name, org_id) ON DELETE CASCADE
);

CREATE TABLE public.template_pool_policies (
    template text NOT NULL,
    target_count integer NOT NULL,
    boot_mode text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT template_pool_policies_boot_mode_check CHECK ((boot_mode = ANY (ARRAY['cold'::text, 'snapshot'::text]))),
    CONSTRAINT template_pool_policies_target_count_check CHECK ((target_count > 0)),
    CONSTRAINT template_pool_policies_pkey PRIMARY KEY (template),
    CONSTRAINT template_pool_policies_template_fkey FOREIGN KEY (template) REFERENCES public.templates(name) ON DELETE CASCADE
);

CREATE TABLE public.template_releases (
    id uuid DEFAULT public.space_uuid_v7() NOT NULL,
    template_name text NOT NULL,
    type text NOT NULL,
    hash text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    org_id uuid,
    execution_metadata jsonb,
    CONSTRAINT template_releases_type_check CHECK ((type = 'fc'::text)),
    CONSTRAINT template_releases_id_org_id_key UNIQUE (id, org_id),
    CONSTRAINT template_releases_id_template_name_key UNIQUE (id, template_name),
    CONSTRAINT template_releases_pkey PRIMARY KEY (id),
    CONSTRAINT template_releases_template_name_fkey FOREIGN KEY (template_name) REFERENCES public.templates(name) ON DELETE RESTRICT,
    CONSTRAINT template_releases_template_name_org_id_fkey FOREIGN KEY (template_name, org_id) REFERENCES public.templates(name, org_id) ON DELETE RESTRICT
);

CREATE TABLE public.kubernetes_pool_configs (
    id uuid DEFAULT public.space_uuid_v7() NOT NULL,
    template_release_id uuid NOT NULL,
    vcpu integer NOT NULL,
    memory_mib integer NOT NULL,
    target_ready_slots integer NOT NULL,
    refill_per_tick integer NOT NULL,
    max_warming_slots integer NOT NULL,
    namespace text NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    managed_by text DEFAULT 'manual'::text NOT NULL,
    disk_io_max_operations_per_sec bigint DEFAULT 1000 NOT NULL,
    disk_io_max_bandwidth_mib_per_sec bigint DEFAULT 100 NOT NULL,
    encryptable boolean DEFAULT false NOT NULL,
    disk_mib integer,
    CONSTRAINT k8s_pool_configs_disk_mib_positive CHECK (((disk_mib IS NULL) OR (disk_mib > 0))),
    CONSTRAINT kubernetes_pool_configs_disk_io_max_bandwidth_mib_per_sec_check CHECK ((disk_io_max_bandwidth_mib_per_sec > 0)),
    CONSTRAINT kubernetes_pool_configs_disk_io_max_operations_per_sec_check CHECK ((disk_io_max_operations_per_sec > 0)),
    CONSTRAINT kubernetes_pool_configs_managed_by_check CHECK ((managed_by = ANY (ARRAY['manual'::text, 'autoscaler'::text]))),
    CONSTRAINT kubernetes_pool_configs_max_warming_slots_check CHECK ((max_warming_slots >= 0)),
    CONSTRAINT kubernetes_pool_configs_memory_mib_check CHECK ((memory_mib > 0)),
    CONSTRAINT kubernetes_pool_configs_refill_per_tick_check CHECK ((refill_per_tick >= 0)),
    CONSTRAINT kubernetes_pool_configs_target_ready_slots_check CHECK ((target_ready_slots >= 0)),
    CONSTRAINT kubernetes_pool_configs_vcpu_check CHECK ((vcpu > 0)),
    CONSTRAINT kubernetes_pool_configs_pkey PRIMARY KEY (id),
    CONSTRAINT kubernetes_pool_configs_template_release_id_fkey FOREIGN KEY (template_release_id) REFERENCES public.template_releases(id) ON DELETE RESTRICT
);

CREATE TABLE public.kubernetes_pool_slots (
    id uuid DEFAULT public.space_uuid_v7() NOT NULL,
    config_id uuid NOT NULL,
    template_release_id uuid NOT NULL,
    reserved_sandbox_id uuid NOT NULL,
    template_name text NOT NULL,
    content_hash text NOT NULL,
    vcpu integer NOT NULL,
    memory_mib integer NOT NULL,
    pod_name text NOT NULL,
    pod_namespace text NOT NULL,
    pod_uid text,
    pod_ip inet,
    k8s_node_name text,
    state text NOT NULL,
    claim_id uuid,
    ready_at timestamp with time zone,
    claimed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    disk_io_max_operations_per_sec bigint DEFAULT 1000 NOT NULL,
    disk_io_max_bandwidth_mib_per_sec bigint DEFAULT 100 NOT NULL,
    disk_mib integer,
    CONSTRAINT k8s_pool_slots_disk_io_bandwidth_positive CHECK ((disk_io_max_bandwidth_mib_per_sec > 0)),
    CONSTRAINT k8s_pool_slots_disk_io_ops_positive CHECK ((disk_io_max_operations_per_sec > 0)),
    CONSTRAINT k8s_pool_slots_disk_mib_positive CHECK (((disk_mib IS NULL) OR (disk_mib > 0))),
    CONSTRAINT kubernetes_pool_slots_memory_mib_check CHECK ((memory_mib > 0)),
    CONSTRAINT kubernetes_pool_slots_vcpu_check CHECK ((vcpu > 0)),
    CONSTRAINT kubernetes_pool_slots_pkey PRIMARY KEY (id),
    CONSTRAINT kubernetes_pool_slots_reserved_sandbox_id_key UNIQUE (reserved_sandbox_id),
    CONSTRAINT kubernetes_pool_slots_config_id_fkey FOREIGN KEY (config_id) REFERENCES public.kubernetes_pool_configs(id) ON DELETE CASCADE,
    CONSTRAINT kubernetes_pool_slots_template_release_id_fkey FOREIGN KEY (template_release_id) REFERENCES public.template_releases(id) ON DELETE RESTRICT
)
WITH (vacuum_truncate='false');

CREATE TABLE public.sandbox_archives (
    sandbox_id uuid NOT NULL,
    org_id uuid NOT NULL,
    user_id uuid NOT NULL,
    sandbox_created_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    purge_at timestamp with time zone,
    manifest_id uuid NOT NULL,
    manifest_sha256 bytea NOT NULL,
    stored_bytes bigint NOT NULL,
    template_release_id uuid,
    CONSTRAINT sandbox_archives_pkey PRIMARY KEY (sandbox_id),
    CONSTRAINT sandbox_archives_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id) ON DELETE RESTRICT,
    CONSTRAINT sandbox_archives_template_release_id_fkey FOREIGN KEY (template_release_id) REFERENCES public.template_releases(id) ON DELETE RESTRICT,
    CONSTRAINT sandbox_archives_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT
);

CREATE TABLE public.template_release_storage_locations (
    id uuid DEFAULT public.space_uuid_v7() NOT NULL,
    template_release_id uuid NOT NULL,
    storage_connection_string text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    org_id uuid,
    CONSTRAINT template_release_storage_loca_template_release_id_storage_c_key UNIQUE (template_release_id, storage_connection_string),
    CONSTRAINT template_release_storage_locations_id_org_id_key UNIQUE (id, org_id),
    CONSTRAINT template_release_storage_locations_pkey PRIMARY KEY (id),
    CONSTRAINT template_release_storage_locations_release_id_org_id_fkey FOREIGN KEY (template_release_id, org_id) REFERENCES public.template_releases(id, org_id) ON DELETE RESTRICT,
    CONSTRAINT template_release_storage_locations_template_release_id_fkey FOREIGN KEY (template_release_id) REFERENCES public.template_releases(id) ON DELETE RESTRICT
);

CREATE TABLE public.template_release_storage_location_encrypted_fields (
    id uuid DEFAULT public.space_uuid_v7() NOT NULL,
    template_release_storage_location_id uuid NOT NULL,
    org_id uuid NOT NULL,
    master_key_id uuid NOT NULL,
    wrapped_dek bytea NOT NULL,
    storage_connection_string bytea NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT template_release_storage_loca_template_release_storage_loca_key UNIQUE (template_release_storage_location_id),
    CONSTRAINT template_release_storage_location_encrypted_fields_pkey PRIMARY KEY (id),
    CONSTRAINT template_release_storage_location_encrypted_fields_kek_fkey FOREIGN KEY (master_key_id, org_id) REFERENCES public.org_master_keys(id, org_id) ON DELETE RESTRICT,
    CONSTRAINT template_release_storage_location_encrypted_fields_loc_fkey FOREIGN KEY (template_release_storage_location_id, org_id) REFERENCES public.template_release_storage_locations(id, org_id) ON DELETE CASCADE
);

CREATE TABLE public.template_release_tags (
    id uuid DEFAULT public.space_uuid_v7() NOT NULL,
    template_release_id uuid NOT NULL,
    template_name text NOT NULL,
    tag text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    modified_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT template_release_tags_pkey PRIMARY KEY (id),
    CONSTRAINT template_release_tags_template_name_tag_key UNIQUE (template_name, tag),
    CONSTRAINT template_release_tags_template_release_id_template_name_fkey FOREIGN KEY (template_release_id, template_name) REFERENCES public.template_releases(id, template_name) ON DELETE RESTRICT
);

CREATE TABLE public.user_credentials (
    id uuid DEFAULT public.space_uuid_v7() NOT NULL,
    user_id uuid NOT NULL,
    key text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    value bytea NOT NULL,
    wrapped_key bytea NOT NULL,
    org_id uuid NOT NULL,
    CONSTRAINT user_credentials_pkey PRIMARY KEY (id),
    CONSTRAINT user_credentials_user_id_key_key UNIQUE (user_id, key),
    CONSTRAINT user_credentials_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organizations(id) ON DELETE CASCADE,
    CONSTRAINT user_credentials_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE
);

CREATE TABLE public.warm_pool_policies (
    template_name text NOT NULL,
    runtime text DEFAULT 'fc'::text NOT NULL,
    vcpu integer NOT NULL,
    memory_mib integer NOT NULL,
    min_ready_slots integer NOT NULL,
    max_ready_slots integer NOT NULL,
    retain_releases integer DEFAULT 2 NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    refill_per_tick integer DEFAULT 5 NOT NULL,
    max_warming_slots integer DEFAULT 10 NOT NULL,
    disk_io_max_operations_per_sec bigint,
    disk_io_max_bandwidth_mib_per_sec bigint,
    retain_shape_on_miss boolean DEFAULT false NOT NULL,
    disk_mib integer,
    CONSTRAINT warm_pool_policies_check CHECK ((max_ready_slots >= min_ready_slots)),
    CONSTRAINT warm_pool_policies_disk_io_max_bandwidth_mib_per_sec_check CHECK ((disk_io_max_bandwidth_mib_per_sec > 0)),
    CONSTRAINT warm_pool_policies_disk_io_max_operations_per_sec_check CHECK ((disk_io_max_operations_per_sec > 0)),
    CONSTRAINT warm_pool_policies_disk_mib_positive CHECK (((disk_mib IS NULL) OR (disk_mib > 0))),
    CONSTRAINT warm_pool_policies_max_warming_slots_check CHECK ((max_warming_slots >= 0)),
    CONSTRAINT warm_pool_policies_memory_mib_check CHECK ((memory_mib > 0)),
    CONSTRAINT warm_pool_policies_min_ready_slots_check CHECK ((min_ready_slots >= 0)),
    CONSTRAINT warm_pool_policies_refill_lte_warming CHECK ((refill_per_tick <= max_warming_slots)),
    CONSTRAINT warm_pool_policies_refill_per_tick_check CHECK ((refill_per_tick >= 0)),
    CONSTRAINT warm_pool_policies_retain_releases_check CHECK ((retain_releases > 0)),
    CONSTRAINT warm_pool_policies_runtime_check CHECK ((runtime = 'fc'::text)),
    CONSTRAINT warm_pool_policies_vcpu_check CHECK ((vcpu > 0)),
    CONSTRAINT warm_pool_policies_pkey PRIMARY KEY (template_name, runtime, vcpu, memory_mib)
);

COMMENT ON COLUMN public.kubernetes_pool_configs.disk_mib IS 'Materialized warm-slot rootfs capacity override in MiB; NULL uses the template-baked capacity.';

COMMENT ON COLUMN public.kubernetes_pool_slots.disk_mib IS 'Immutable rootfs capacity override used to create this warm slot; NULL uses the template-baked capacity.';

COMMENT ON COLUMN public.node_artifact_components.role_key IS 'Projection sentinel: empty string represents an absent optional component role.';

COMMENT ON COLUMN public.warm_pool_policies.disk_io_max_operations_per_sec IS 'Optional override; NULL inherits the platform default of 1000 operations per second.';

COMMENT ON COLUMN public.warm_pool_policies.disk_io_max_bandwidth_mib_per_sec IS 'Optional override; NULL inherits the platform default of 100 MiB per second.';

COMMENT ON COLUMN public.warm_pool_policies.retain_shape_on_miss IS 'When enabled, cold fallthrough retains this policy CPU, memory, and disk I/O shape if the resolved release has no materialized pool config.';

COMMENT ON COLUMN public.warm_pool_policies.disk_mib IS 'Optional warm-slot rootfs capacity override in MiB; NULL uses the template-baked capacity.';

ALTER TABLE public.public_operations
    ADD CONSTRAINT public_operations_kind_check CHECK ((kind = ANY (ARRAY['create_sandbox'::text, 'fork_sandbox'::text, 'update_sandbox'::text, 'delete_sandbox'::text, 'start_sandbox'::text, 'stop_sandbox'::text, 'pause_sandbox'::text, 'resume_sandbox'::text, 'suspend_sandbox'::text, 'restore_sandbox'::text, 'wake_sandbox'::text, 'kill_sandbox'::text, 'checkpoint_sandbox'::text, 'enable_sandbox_snapshots'::text, 'disable_sandbox_snapshots'::text, 'rollback_sandbox'::text, 'delete_template'::text, 'create_session'::text]))) NOT VALID;

ALTER TABLE public.snapshots
    ADD CONSTRAINT snapshots_artifact_identity_check CHECK ((((local_artifact_id IS NULL) AND (artifact_kind IS NULL) AND (artifact_origin IS NULL) AND (artifact_snapshot_name IS NULL)) OR ((artifact_kind IS NOT NULL) AND (artifact_origin IS NOT NULL) AND ((local_artifact_id IS NOT NULL) OR (artifact_origin = 'fork'::text))))) NOT VALID;

ALTER TABLE public.snapshots
    ADD CONSTRAINT snapshots_artifact_origin_check CHECK (((artifact_origin IS NULL) OR (artifact_origin = ANY (ARRAY['stop'::text, 'suspend'::text, 'snapshot'::text, 'fork'::text])))) NOT VALID;

CREATE INDEX admin_audit_events_created_at_id_idx ON public.admin_audit_events USING btree (created_at DESC, id DESC);

CREATE INDEX data_plane_sessions_org_sandbox_created_session_idx ON public.data_plane_sessions USING btree (org_id, sandbox_id, created_at DESC, session_id DESC);

CREATE INDEX data_plane_sessions_org_sandbox_idx ON public.data_plane_sessions USING btree (org_id, sandbox_id);

CREATE INDEX data_plane_sessions_org_sandbox_kind_created_session_idx ON public.data_plane_sessions USING btree (org_id, sandbox_id, kind, created_at DESC, session_id DESC);

CREATE INDEX idx_api_keys_created_by ON public.api_keys USING btree (created_by);

CREATE INDEX idx_api_keys_org_id ON public.api_keys USING btree (org_id);

CREATE INDEX idx_k8s_executions_active_pod_ip ON public.sandbox_k8s_executions USING btree (pod_ip) INCLUDE (sandbox_id) WHERE (active AND (terminated_at IS NULL) AND (pod_ip IS NOT NULL));

CREATE UNIQUE INDEX idx_k8s_executions_active_sandbox ON public.sandbox_k8s_executions USING btree (sandbox_id) WHERE active;

CREATE UNIQUE INDEX idx_k8s_executions_pod_name ON public.sandbox_k8s_executions USING btree (pod_name);

CREATE INDEX idx_k8s_executions_sandbox_created ON public.sandbox_k8s_executions USING btree (sandbox_id, created_at DESC);

CREATE UNIQUE INDEX idx_k8s_executions_sandbox_generation ON public.sandbox_k8s_executions USING btree (sandbox_id, generation);

CREATE INDEX idx_kubernetes_pool_configs_autoscaler ON public.kubernetes_pool_configs USING btree (managed_by) WHERE (managed_by = 'autoscaler'::text);

CREATE INDEX idx_kubernetes_pool_configs_enabled ON public.kubernetes_pool_configs USING btree (enabled) WHERE enabled;

CREATE UNIQUE INDEX idx_kubernetes_pool_configs_release_shape_kind ON public.kubernetes_pool_configs USING btree (template_release_id, vcpu, memory_mib, encryptable);

CREATE INDEX idx_kubernetes_pool_slots_claim_lookup ON public.kubernetes_pool_slots USING btree (template_release_id, vcpu, memory_mib, ready_at) WHERE (state = 'ready'::text);

CREATE INDEX idx_kubernetes_pool_slots_inventory ON public.kubernetes_pool_slots USING btree (config_id, state, ready_at);

CREATE UNIQUE INDEX idx_kubernetes_pool_slots_pod_name ON public.kubernetes_pool_slots USING btree (pod_name);

CREATE INDEX idx_kubernetes_pool_slots_reserved_sandbox ON public.kubernetes_pool_slots USING btree (reserved_sandbox_id);

CREATE INDEX idx_node_direct_deleted_at ON public.node_direct USING btree (deleted_at);

CREATE UNIQUE INDEX idx_node_direct_endpoint_active ON public.node_direct USING btree (node_api_endpoint) WHERE (deleted_at IS NULL);

CREATE INDEX idx_node_facet_observed_status_facet_element ON public.node_facet_observed_status USING btree (facet, element);

CREATE INDEX idx_node_facet_observed_status_updated_at ON public.node_facet_observed_status USING btree (updated_at, node_id, facet, element);

CREATE UNIQUE INDEX idx_node_groups_single_default ON public.node_groups USING btree (NULLIF(is_default, false));

CREATE INDEX idx_node_k8s_k8s_node_name ON public.node_k8s USING btree (k8s_node_name);

CREATE INDEX idx_node_reconcile_queue_claim ON public.node_reconcile_queue USING btree (node_id, next_attempt_at, requested_at);

CREATE INDEX idx_node_reconcile_queue_dead ON public.node_reconcile_queue USING btree (node_id, facet, requested_at) WHERE (dead_at IS NOT NULL);

CREATE INDEX idx_node_reconcile_queue_facet_element ON public.node_reconcile_queue USING btree (facet, element);

CREATE INDEX idx_node_reconcile_queue_requested_at ON public.node_reconcile_queue USING btree (requested_at);

CREATE INDEX idx_node_reconcile_triggers_claim ON public.node_reconcile_triggers USING btree (requested_at, node_id, next_attempt_at) WHERE (dead_at IS NULL);

CREATE INDEX idx_node_reconcile_triggers_claimed ON public.node_reconcile_triggers USING btree (claimed_at) WHERE (claim_token <> ''::text);

CREATE INDEX idx_node_reconcile_triggers_dead ON public.node_reconcile_triggers USING btree (updated_at) WHERE (dead_at IS NOT NULL);

CREATE INDEX idx_node_template_inventory_observed_at ON public.node_template_inventory USING btree (observed_at);

CREATE INDEX idx_node_template_inventory_template ON public.node_template_inventory USING btree (template_name);

CREATE INDEX idx_nodes_drain_phase ON public.nodes USING btree (drain_phase) WHERE (drain_phase IS NOT NULL);

CREATE INDEX idx_nodes_managed_by ON public.nodes USING btree (managed_by);

CREATE INDEX idx_nodes_role ON public.nodes USING btree (managed_by, role);

CREATE INDEX idx_nodes_state ON public.nodes USING btree (state);

CREATE INDEX idx_org_credentials_org_id ON public.org_credentials USING btree (org_id);

CREATE UNIQUE INDEX idx_org_master_keys_active ON public.org_master_keys USING btree (org_id) WHERE (retired_at IS NULL);

CREATE UNIQUE INDEX idx_organizations_federated_owner ON public.organizations USING btree (upstream_issuer, upstream_org_id) WHERE (owner_source = 'federated_identity'::text);

CREATE INDEX idx_organizations_parent_id ON public.organizations USING btree (parent_id);

CREATE INDEX idx_public_idempotency_records_expires ON public.public_idempotency_records USING btree (expires_at);

CREATE UNIQUE INDEX idx_public_idempotency_records_lookup ON public.public_idempotency_records USING btree (org_id, api_product, method, path_template, idempotency_key);

CREATE INDEX idx_public_operation_events_operation_created ON public.public_operation_events USING btree (operation_id, created_at, sequence);

CREATE INDEX idx_public_operations_claim ON public.public_operations USING btree (next_attempt_at, requested_at) WHERE ((state = ANY (ARRAY['queued'::text, 'running'::text])) AND (claim_token = ''::text));

CREATE INDEX idx_public_operations_gc ON public.public_operations USING btree (gc_after) WHERE (state = ANY (ARRAY['succeeded'::text, 'failed'::text, 'canceled'::text, 'expired'::text]));

CREATE INDEX idx_public_operations_state_next_attempt ON public.public_operations USING btree (state, next_attempt_at);

CREATE INDEX idx_public_operations_target ON public.public_operations USING btree (org_id, target_type, target_id) WHERE ((target_type IS NOT NULL) AND (target_id IS NOT NULL));

CREATE INDEX idx_public_operations_tenant_created ON public.public_operations USING btree (org_id, created_at DESC, operation_id DESC);

CREATE INDEX idx_sandbox_encrypted_master_key ON public.sandbox_encrypted_fields USING btree (master_key_id, org_id);

CREATE INDEX idx_sandbox_observed_states_node ON public.sandbox_observed_states USING btree (node_id);

CREATE INDEX idx_sandbox_observed_states_observed_at ON public.sandbox_observed_states USING btree (observed_at);

CREATE INDEX idx_sandbox_observed_states_updated_at ON public.sandbox_observed_states USING btree (updated_at, sandbox_id);

CREATE INDEX idx_sandbox_port_exposures_sandbox_desired ON public.sandbox_port_exposures USING btree (sandbox_id, desired_state);

CREATE INDEX idx_sandbox_quarantine_state_last_observed_node ON public.sandbox_quarantine_state USING btree (last_observed_node_id) WHERE (last_observed_node_id IS NOT NULL);

CREATE INDEX idx_sandbox_volume_encryption_master_key ON public.sandbox_volume_encryption USING btree (master_key_id, org_id);

CREATE INDEX idx_sandboxes_active_node ON public.sandboxes USING btree (active_node_id) WHERE (active_node_id IS NOT NULL);

CREATE INDEX idx_sandboxes_command_ready_pending ON public.sandboxes USING btree (id) WHERE command_ready_pending;

CREATE INDEX idx_sandboxes_created_at ON public.sandboxes USING btree (created_at);

CREATE INDEX idx_sandboxes_evacuation_restore_target ON public.sandboxes USING btree (lifecycle) WHERE (evacuation_restore_target IS NOT NULL);

CREATE INDEX idx_sandboxes_lifecycle ON public.sandboxes USING btree (lifecycle);

CREATE INDEX idx_sandboxes_lifecycle_changed_at ON public.sandboxes USING btree (lifecycle, lifecycle_changed_at);

CREATE INDEX idx_sandboxes_managed_by ON public.sandboxes USING btree (managed_by);

CREATE INDEX idx_sandboxes_org_created_id ON public.sandboxes USING btree (org_id, created_at DESC, id DESC);

CREATE INDEX idx_sandboxes_org_id ON public.sandboxes USING btree (org_id);

CREATE INDEX idx_sandboxes_placement ON public.sandboxes USING btree (placement);

CREATE INDEX idx_sandboxes_suspended_updated_at ON public.sandboxes USING btree (updated_at, id) WHERE (lifecycle = 'suspended'::text);

CREATE INDEX idx_sandboxes_target_node ON public.sandboxes USING btree (target_node_id) WHERE (target_node_id IS NOT NULL);

CREATE INDEX idx_sandboxes_user_id ON public.sandboxes USING btree (user_id);

CREATE INDEX idx_sessions_token_hash ON public.sessions USING btree (token_hash);

CREATE INDEX idx_snapshot_storage_location_encrypted_master_key ON public.snapshot_storage_location_encrypted_fields USING btree (master_key_id, org_id);

CREATE INDEX idx_snapshot_storage_locations_orphaned_at ON public.snapshot_storage_locations USING btree (orphaned_at) WHERE (orphaned_at IS NOT NULL);

CREATE UNIQUE INDEX idx_snapshot_storage_locations_snapshot_id_unique ON public.snapshot_storage_locations USING btree (snapshot_id);

CREATE INDEX idx_snapshots_ready_local_artifact ON public.snapshots USING btree (sandbox_id, local_artifact_id, artifact_kind, "timestamp" DESC) WHERE ((state = 'ready'::text) AND (local_artifact_id IS NOT NULL));

CREATE INDEX idx_snapshots_sandbox_id ON public.snapshots USING btree (sandbox_id);

CREATE INDEX idx_snapshots_sandbox_ready_latest_covering ON public.snapshots USING btree (sandbox_id, "timestamp" DESC) INCLUDE (id) WHERE ((state = 'ready'::text) AND (type = 'full'::text));

CREATE INDEX idx_snapshots_source_node_id ON public.snapshots USING btree (source_node_id);

CREATE INDEX idx_snapshots_state_type ON public.snapshots USING btree (state, type);

CREATE INDEX idx_template_encrypted_master_key ON public.template_encrypted_fields USING btree (master_key_id, org_id);

CREATE INDEX idx_template_release_storage_location_encrypted_master_key ON public.template_release_storage_location_encrypted_fields USING btree (master_key_id, org_id);

CREATE INDEX idx_template_release_storage_locations_release_id ON public.template_release_storage_locations USING btree (template_release_id);

CREATE INDEX idx_template_release_tags_latest ON public.template_release_tags USING btree (template_name) WHERE (tag = 'latest'::text);

CREATE INDEX idx_template_release_tags_release_id ON public.template_release_tags USING btree (template_release_id);

CREATE INDEX idx_template_releases_template_name ON public.template_releases USING btree (template_name);

CREATE UNIQUE INDEX idx_template_releases_template_name_hash_unique ON public.template_releases USING btree (template_name, hash);

CREATE INDEX idx_templates_delete_operation ON public.templates USING btree (delete_operation_id) WHERE (delete_operation_id IS NOT NULL);

CREATE INDEX idx_templates_org_id ON public.templates USING btree (org_id);

CREATE INDEX idx_user_credentials_user_id ON public.user_credentials USING btree (user_id);

CREATE UNIQUE INDEX idx_users_federated_subject ON public.users USING btree (org_id, upstream_issuer, upstream_subject_id) WHERE (owner_source = 'federated_identity'::text);

CREATE INDEX idx_users_org_id ON public.users USING btree (org_id);

CREATE INDEX node_reconcile_queue_claimed_at ON public.node_reconcile_queue USING btree (claimed_at);

CREATE INDEX sandbox_archives_org_list_idx ON public.sandbox_archives USING btree (org_id, sandbox_created_at DESC);

CREATE INDEX sandbox_archives_purge_idx ON public.sandbox_archives USING btree (purge_at);

CREATE INDEX sandbox_archives_template_release_idx ON public.sandbox_archives USING btree (template_release_id);

CREATE INDEX sandbox_archives_user_list_idx ON public.sandbox_archives USING btree (user_id, sandbox_created_at DESC);

CREATE INDEX sandbox_network_credential_injection_rules_reference_idx ON public.sandbox_network_credential_injection_rules USING btree (credential_reference_id);

CREATE TRIGGER clusters_set_updated_at BEFORE UPDATE ON public.clusters FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER credential_references_set_updated_at BEFORE UPDATE ON public.credential_references FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER network_credential_rules_set_updated_at BEFORE UPDATE ON public.sandbox_network_credential_injection_rules FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER network_credential_ruleset_set_updated_at BEFORE UPDATE ON public.sandbox_network_credential_injection_ruleset_version FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER org_master_keys_set_updated_at BEFORE UPDATE ON public.org_master_keys FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER organizations_reject_owner_identity_update BEFORE UPDATE ON public.organizations FOR EACH ROW WHEN (((new.owner_source IS DISTINCT FROM old.owner_source) OR (new.upstream_issuer IS DISTINCT FROM old.upstream_issuer) OR (new.upstream_org_id IS DISTINCT FROM old.upstream_org_id))) EXECUTE FUNCTION public.organizations_reject_owner_identity_update();

CREATE TRIGGER sandbox_credential_injection_rules_set_updated_at BEFORE UPDATE ON public.sandbox_credential_injection_rules FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER sandbox_federated_service_grants_set_updated_at BEFORE UPDATE ON public.sandbox_federated_service_grants FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER sandboxes_clear_command_ready_pending BEFORE UPDATE ON public.sandboxes FOR EACH ROW EXECUTE FUNCTION public.sandboxes_clear_command_ready_pending();

CREATE TRIGGER sandboxes_clear_evacuation_restore_target BEFORE UPDATE ON public.sandboxes FOR EACH ROW EXECUTE FUNCTION public.sandboxes_clear_evacuation_restore_target();

CREATE TRIGGER sandboxes_clear_restore_lease BEFORE UPDATE ON public.sandboxes FOR EACH ROW EXECUTE FUNCTION public.sandboxes_clear_restore_lease();

CREATE TRIGGER sandboxes_lifecycle_changed_at BEFORE UPDATE ON public.sandboxes FOR EACH ROW EXECUTE FUNCTION public.sandboxes_touch_lifecycle_changed_at();

CREATE TRIGGER sandboxes_set_updated_at BEFORE UPDATE ON public.sandboxes FOR EACH ROW EXECUTE FUNCTION public.set_sandbox_updated_at();

CREATE TRIGGER templates_set_updated_at BEFORE UPDATE ON public.templates FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER users_reject_owner_identity_update BEFORE UPDATE ON public.users FOR EACH ROW WHEN (((new.owner_source IS DISTINCT FROM old.owner_source) OR (new.upstream_issuer IS DISTINCT FROM old.upstream_issuer) OR (new.upstream_subject_id IS DISTINCT FROM old.upstream_subject_id))) EXECUTE FUNCTION public.users_reject_owner_identity_update();

ALTER TABLE ONLY public.nodes
    ADD CONSTRAINT nodes_node_group_id_fkey FOREIGN KEY (node_group_id) REFERENCES public.node_groups(id) NOT VALID;

-- Capability grants are also needed when migrations run without bootstrap-roles.
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'space_credmgr') THEN
        CREATE ROLE space_credmgr NOLOGIN;
    END IF;
END
$$;

GRANT SELECT ON TABLE public.credential_references TO space_credmgr;

GRANT SELECT ON TABLE public.node_facet_observed_status TO pg_monitor;

GRANT SELECT(node_id) ON TABLE public.node_k8s TO space_credmgr;

GRANT SELECT(k8s_node_name) ON TABLE public.node_k8s TO space_credmgr;

GRANT SELECT(k8s_node_uid) ON TABLE public.node_k8s TO space_credmgr;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.org_branching_keys TO space_credmgr;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.org_credentials TO space_credmgr;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.org_master_keys TO space_credmgr;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.org_storage_vend_identities TO space_credmgr;

GRANT SELECT ON TABLE public.organizations TO space_credmgr;

GRANT SELECT ON TABLE public.sandbox_credential_injection_rules TO space_credmgr;

GRANT SELECT(sandbox_id) ON TABLE public.sandbox_direct_route_identities TO space_credmgr;

GRANT SELECT(current_node_id) ON TABLE public.sandbox_direct_route_identities TO space_credmgr;

GRANT SELECT(execution_generation) ON TABLE public.sandbox_direct_route_identities TO space_credmgr;

GRANT SELECT(sandbox_id) ON TABLE public.sandbox_k8s_executions TO space_credmgr;

GRANT SELECT(generation) ON TABLE public.sandbox_k8s_executions TO space_credmgr;

GRANT SELECT(k8s_node_name) ON TABLE public.sandbox_k8s_executions TO space_credmgr;

GRANT SELECT(active) ON TABLE public.sandbox_k8s_executions TO space_credmgr;

GRANT SELECT ON TABLE public.sandbox_network_credential_injection_rules TO space_credmgr;

GRANT SELECT ON TABLE public.sandbox_network_credential_injection_ruleset_version TO space_credmgr;

GRANT SELECT ON TABLE public.sandbox_observed_states TO pg_monitor;

GRANT SELECT ON TABLE public.sandbox_quarantine_state TO pg_monitor;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.sandbox_volume_encryption TO space_credmgr;

GRANT SELECT ON TABLE public.sandboxes TO space_credmgr;

GRANT SELECT(id) ON TABLE public.sandboxes TO space_credmgr;

GRANT SELECT(user_id) ON TABLE public.sandboxes TO space_credmgr;

GRANT SELECT(org_id) ON TABLE public.sandboxes TO space_credmgr;

GRANT SELECT(active_node_id) ON TABLE public.sandboxes TO space_credmgr;

GRANT SELECT ON TABLE public.templates TO space_credmgr;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.user_credentials TO space_credmgr;

-- Local ownership identities remain locked until explicitly provisioned.
INSERT INTO public.organizations (id, name, slug)
VALUES ('00000000-0000-0000-0000-000000000001', 'Local', 'local');

INSERT INTO public.users (id, email, password_hash, display_name, org_id, role) VALUES
    ('00000000-0000-0000-0000-000000000010', 'root@local', '!', 'Root Admin', '00000000-0000-0000-0000-000000000001', 'organization_admin'),
    ('00000000-0000-0000-0000-000000000011', 'deploy@local', '!', 'Deploy Admin', '00000000-0000-0000-0000-000000000001', 'organization_admin'),
    ('00000000-0000-0000-0000-000000000012', 'dev@local', '!', 'Dev User', '00000000-0000-0000-0000-000000000001', 'member');

INSERT INTO public.clusters (id, name, managing_org_id)
VALUES (public.space_uuid_v7(), 'default', '00000000-0000-0000-0000-000000000001');

CREATE INDEX idx_sandboxes_target_node_ordered ON public.sandboxes (target_node_id, id);
