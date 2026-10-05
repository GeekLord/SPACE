# One EKS cluster with SPACE's three node pools: `general` for cluster
# services on the EKS-managed AL2023 AMI, and `workers` and `builders` on the
# SPACE node AMIs that infra/space/packer bakes (Firecracker, the guest kernel,
# the btrfs cache, SPACE's host users and kernel settings). The pools carry the
# labels and taints `modules/space` gives them, so SPACE's node workloads would
# land on them unchanged. The module is referenced by path, not by a pinned
# release, so the schedule applies whatever `main` holds and a module
# regression surfaces here first.
#
# The endpoint is public so the scheduled job can reach it from a GitHub-hosted
# runner and check that nodes register; every request still needs an EKS access
# entry. The apply role gets one as the cluster's creator; people get theirs
# from the list bootstrap/ publishes, so a local plan and the schedule always
# agree on it.

data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "cluster_admin_principal_arns" {
  name = "/${var.cluster_name}/cluster-admin-principal-arns"
}

# The workers and builders node counts, set by hand (bootstrap/ creates the
# parameter at zero and never resets it). Nothing scales these pools
# dynamically; a size changes only when someone changes this value and applies.
data "aws_ssm_parameter" "node_pool_sizes" {
  name = "/${var.cluster_name}/node-pool-sizes"

  lifecycle {
    postcondition {
      condition = alltrue(concat(
        [
          for pool in ["workers", "builders"] :
          try(parseint(tostring(jsondecode(self.insecure_value)[pool]), 10) >= 0, false)
        ],
        # A key for any other pool would be silently ignored.
        [try(length(setsubtract(keys(jsondecode(self.insecure_value)), ["workers", "builders"])) == 0, false)],
        # node_group_update_timeout below covers a drain-first roll of one
        # node; a larger pool needs that raised in the same change as this cap.
        [for pool in ["workers", "builders"] : try(parseint(tostring(jsondecode(self.insecure_value)[pool]), 10) <= 1, false)],
      ))
      error_message = "The node-pool-sizes parameter must be a JSON object with exactly the keys workers and builders, each 0 or 1, such as {\"workers\":1,\"builders\":0}. Sizes above 1 need node_group_update_timeout in cluster/eks.tf, and the apply job's limit, raised in the same change."
    }
  }
}

# The newest SPACE node AMI of each role baked in this account, from
# `node_ami_branch`, for the cluster's minor. A bake at another minor is never
# picked up, so a kubelet can't land ahead of its control plane, and a bake
# from a feature branch is never picked up by accident. A new matching bake
# rolls the pool on the next apply.
data "aws_ami" "space_node" {
  for_each = toset(["worker", "builder"])

  owners      = ["self"]
  most_recent = true

  filter {
    name   = "tag:Role"
    values = [each.key]
  }

  filter {
    name   = "tag:KubernetesVersion"
    values = [var.kubernetes_version]
  }

  filter {
    name   = "tag:GitBranch"
    values = [var.node_ami_branch]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

locals {
  private_subnet_ids = values(aws_subnet.private)[*].id

  node_pool_sizes = {
    general  = 1
    workers  = tonumber(jsondecode(data.aws_ssm_parameter.node_pool_sizes.insecure_value).workers)
    builders = tonumber(jsondecode(data.aws_ssm_parameter.node_pool_sizes.insecure_value).builders)
  }

  # The same subnets, read through their route table associations and gated on
  # the NAT default route, so the node group waits for egress. A node that
  # can't reach the internet can't pull its images and never becomes Ready.
  # A module-level depends_on would do the same but would also defer every data
  # source in the module to apply time.
  node_subnet_ids = [
    for association in values(aws_route_table_association.private) : association.subnet_id
    if aws_route.private_default.id != ""
  ]

  # `general` stays in the NAT gateway's AZ. It hosts PostgreSQL (addons/),
  # whose EBS volume can only attach in the AZ it was created in; a node
  # replaced into another AZ would leave the database Pending. Losing that AZ
  # already cuts every node's egress; what this adds is that EC2 can't place
  # the node in another AZ when this one is out of capacity.
  general_subnet_ids = [
    for az, association in aws_route_table_association.private : association.subnet_id
    if az == local.nat_az && aws_route.private_default.id != ""
  ]
}

module "eks" {
  source = "../../eks/modules/eks-cluster"

  name               = var.cluster_name
  vpc_id             = aws_vpc.this.id
  subnet_ids         = local.private_subnet_ids
  kubernetes_version = var.kubernetes_version
  cluster_addons     = var.cluster_addons

  # 1 keeps pods on the pod network away from IMDS, and so from the node
  # role's credentials; the CNI gets its own through IRSA.
  node_instance_metadata_hop_limit = 1

  cluster_endpoint_public_access = true
  cluster_public_access_cidrs    = var.cluster_public_access_cidrs
  cluster_admin_principal_arns   = jsondecode(data.aws_ssm_parameter.cluster_admin_principal_arns.insecure_value)

  # The control plane's own traffic keeps the api and scheduler streams busy
  # on an idle cluster; audit and authenticator are what an investigation needs.
  enabled_cluster_log_types = ["audit", "authenticator"]

  # bootstrap/ owns this policy, and the apply role can create IAM roles only
  # with it as their boundary.
  iam_role_permissions_boundary = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/${var.cluster_name}-role-boundary"

  node_pools = {
    general = {
      instance_types = var.general_instance_types
      capacity_type  = "ON_DEMAND"
      min_size       = 1
      desired_size   = 1
      max_size       = 2
      disk_size_gib  = 50
      labels = {
        "space.pplx.net/node-pool" = "general"
        "workload"                 = "general"
      }
      taints     = []
      subnet_ids = local.general_subnet_ids
    }

    # Firecracker needs /dev/kvm, which only bare-metal instance types expose.
    workers = {
      instance_types = var.worker_instance_types
      capacity_type  = "ON_DEMAND"
      min_size       = local.node_pool_sizes.workers
      desired_size   = local.node_pool_sizes.workers
      max_size       = max(local.node_pool_sizes.workers, 1)
      disk_size_gib  = 100
      labels = {
        "space.pplx.net/node-pool" = "workers"
        "workload"                 = "workers"
      }
      taints     = []
      subnet_ids = local.node_subnet_ids
      ami_id     = data.aws_ami.space_node["worker"].id
      # Drain before replacing, so a roll never needs more metal than the pool
      # is sized for.
      update_strategy = "MINIMAL"
    }

    builders = {
      instance_types = var.builder_instance_types
      capacity_type  = "ON_DEMAND"
      min_size       = local.node_pool_sizes.builders
      desired_size   = local.node_pool_sizes.builders
      max_size       = max(local.node_pool_sizes.builders, 1)
      disk_size_gib  = 100
      labels = {
        "space.pplx.net/node-pool" = "builders"
        "workload"                 = "builders"
      }
      taints = [{
        key    = "space.pplx.net/workload"
        value  = "builders"
        effect = "NO_SCHEDULE"
      }]
      subnet_ids      = local.node_subnet_ids
      ami_id          = data.aws_ami.space_node["builder"].id
      update_strategy = "MINIMAL"
    }
  }

  # Bounded inside the apply job's limit, so a roll that stalls fails the apply
  # and releases the state lock instead of being killed holding it. This bounds
  # updates only: a change that replaces a node group (instance types, subnets)
  # waits on the provider's 60-minute create and delete defaults, so apply one
  # alongside a Kubernetes minor bump by hand, not through the schedule. The
  # provider can wait this long twice for one node group, once for a version
  # roll and once for a size change, when an apply carries both. EKS fails a
  # node that takes more than 15 minutes to join, and a drain-first roll
  # replaces nodes one at a time, so 40 minutes covers a pool of one metal node;
  # raise it, and the job's limit with it, before sizing a pool larger.
  node_group_update_timeout = "40m"

  # A custom-AMI node joins the cluster through this script, the one
  # `modules/space` uses for its builders: mount the NVMe cache, then nodeadm.
  # Workers use it too. `modules/space` gives them a variant that also installs
  # SPACE's containerd shim from a release bucket and registers it as a
  # runtime; that's part of running SPACE on the nodes, which this deployment
  # doesn't do.
  node_pool_user_data = {
    for pool in ["workers", "builders"] : pool => templatefile(
      "${path.module}/../../eks/modules/space/templates/bootstrap.sh.tftpl",
      {
        cluster_name           = module.eks.cluster_name
        cluster_endpoint       = module.eks.cluster_endpoint
        cluster_ca_data        = module.eks.cluster_certificate_authority_data
        cluster_service_cidr   = module.eks.cluster_service_cidr
        space_cache_nvme_mount = file("${path.module}/../../eks/modules/space/templates/space-cache-nvme-mount.sh")
      },
    )
  }
}
