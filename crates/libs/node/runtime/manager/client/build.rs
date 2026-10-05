const PACKAGE: &str = ".space.node.runtime.manager.v1";

/// Enum-typed fields, which prost stores as `i32`. Each renders through the
/// matching `crate::labels` serializer so JSON carries names, not numbers.
const ENUM_FIELDS: &[(&str, &str)] = &[
    ("ExecutionArtifact.kind", "execution_artifact_kind"),
    ("ExecutionArtifact.runtime_kind", "runtime_kind"),
    (
        "ExecutionArtifact.component_kind",
        "artifact_component_kind",
    ),
    ("ExecutionArtifact.location", "artifact_location"),
    ("ExecutionArtifact.provenance", "artifact_provenance"),
    (
        "ExecutionArtifact.version_source",
        "execution_artifact_version_source",
    ),
    ("ExecutionArtifact.status", "execution_artifact_status"),
    ("ExecutionArtifact.management", "artifact_management"),
    ("ExecutionArtifact.provider", "artifact_provider"),
    ("ExecutionArtifact.for_runtime_kind", "runtime_kind"),
    ("ScannedRoot.kind", "execution_artifact_kind"),
    ("ScannedRoot.runtime_kind", "runtime_kind"),
    ("ScannedRoot.component_kind", "artifact_component_kind"),
    ("ScannedRoot.location", "artifact_location"),
    ("ScannedRoot.provenance", "artifact_provenance"),
    ("ScannedRoot.presence", "scan_root_presence"),
    ("ScanIssue.kind", "scan_issue_kind"),
    ("ProtectedPath.role", "protected_path_role"),
    ("ProtectedPath.protection", "path_protection"),
    ("AvailableKernel.presence", "kernel_presence"),
    ("AvailableKernel.runtime_kind", "runtime_kind"),
    ("ListAvailableKernelsRequest.runtime_kind", "runtime_kind"),
    ("ListAvailableKernelsResponse.runtime_kind", "runtime_kind"),
    ("InstallKernelRequest.runtime_kind", "runtime_kind"),
    ("Operation.runtime_kind", "runtime_kind"),
    ("Operation.kind", "operation_kind"),
    ("Operation.state", "operation_state"),
    ("Operation.outcome", "operation_outcome"),
];

fn main() -> anyhow::Result<()> {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR")?;
    let proto_root = std::path::Path::new(&manifest_dir).join("../../../../../../proto");
    let proto_file = proto_root.join("node/runtime/manager/v1/manager.proto");
    // The listing response is the one shape the service returns and the CLI
    // prints, so its JSON form derives from the generated messages.
    let mut builder = tonic_prost_build::configure()
        .extern_path(
            ".space.execution.v1",
            "::pplx_space_execution_common::proto",
        )
        .message_attribute(PACKAGE, "#[derive(serde::Serialize)]");
    for (field, serializer) in ENUM_FIELDS {
        builder = builder.field_attribute(
            format!("{PACKAGE}.{field}"),
            format!("#[serde(serialize_with = \"crate::labels::serialize::{serializer}\")]"),
        );
    }
    pplx_space_common_proto_build::compile_protos(builder, &[proto_file], &[proto_root])?;
    Ok(())
}
