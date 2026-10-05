"""Node-group placement is inert until enabled, then renders a term the scheduler accepts."""

import uuid

import space_smoke as smoke


# The failure mode this exists for: a required nodeAffinity term whose values
# do not match the labeler's labels is a sandbox that sits Pending for ever
# while every gate in CI is green. Only a real scheduler shows it.
@smoke.scenario(
    "local.node_group_boundary_schedules",
    # Two Deployment rollouts (enable, restore), the labeler settling, one
    # extra real sandbox boot.
    sandbox=smoke.SandboxConfig(timeout=1200),
)
def node_group_boundary_schedules(test: smoke.KindEcw) -> None:
    """With the placement gate off a created pod carries no node-group affinity
    term; a dedicated group is refused with a 409 while the cluster has no
    generic group; and with the labeler and the gate on, a generic create
    renders `node-restriction.kubernetes.io/space-node-group In (<default
    group>)` and its pod reaches Running on a labelled worker."""

    groups = test.node_groups

    with test.phase("gate off: the fixture pod carries no node-group term"):
        groups.expect_inert_by_default()

    with test.phase("provisioning order: a dedicated group is refused without a generic one"):
        groups.expect_dedicated_refused_without_generic(
            org_id=test.admin_org_id(), name=f"smoke-dedicated-{uuid.uuid4().hex[:8]}"
        )

    with test.phase("enable the labeler and the gate on both deployments"):
        groups.enable_labeler_and_gate()

    with test.phase("the labeler seeds the default group and labels the workers"):
        default = groups.wait_for_default_group_and_labels()

    with test.phase("a generic create renders the term and schedules"):
        groups.expect_generic_create_renders_and_schedules(
            default, template=test.sandbox_template_name()
        )

    with test.phase("restore the env and the workers' labels"):
        groups.restore()
