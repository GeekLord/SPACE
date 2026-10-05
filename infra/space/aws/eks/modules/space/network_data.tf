data "aws_vpc" "shared" {
  tags = {
    Name = "${local.name}-vpc"
  }
}

data "aws_subnet" "private" {
  for_each = toset(local.azs)

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.shared.id]
  }

  filter {
    name   = "tag:Name"
    values = ["${local.name}-private-${each.value}"]
  }
}

# Legacy tier-wide discovery for environments that have not declared named
# worker pools. Named-pool environments skip this query entirely so pool-only
# subnets do not also need the legacy `space.pplx.net/subnet-tier` tag.
data "aws_subnets" "secondary_private" {
  count = length(var.worker_subnet_pools) == 0 ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.shared.id]
  }

  filter {
    name   = "tag:space.pplx.net/subnet-tier"
    values = ["secondary"]
  }

  lifecycle {
    postcondition {
      condition     = length(self.ids) > 0
      error_message = "No tier-discovered secondary CG-NAT private subnets found. Environments without named worker pools require at least one subnet tagged `space.pplx.net/subnet-tier=secondary`; apply the VPC project or ensure the subnets have not all opted out of legacy discovery."
    }
  }
}

# Optional stable pools within secondary CG-NAT address space. Only pools used
# by the existing/default MNGs or an explicit capacity group are queried. A
# dormant inventory entry can therefore be staged before its VPC subnet exists;
# selecting it activates exact-count discovery. Pool discovery intentionally
# does not require the legacy `subnet-tier=secondary` tag: new pools can stay
# invisible to tier-wide discovery so a VPC apply cannot change the subnet set
# of an existing managed node group. Environments that declare no pools retain
# the tier-wide discovery above.
data "aws_subnets" "worker_pool" {
  for_each = local.worker_subnet_pools_in_use

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.shared.id]
  }

  filter {
    name   = "tag:space.pplx.net/subnet-pool"
    values = [each.key]
  }

  lifecycle {
    postcondition {
      condition     = length(self.ids) == each.value.expected_subnet_count
      error_message = "Worker subnet pool `${each.key}` expected ${each.value.expected_subnet_count} CG-NAT subnets but discovered ${length(self.ids)}. Apply or repair the VPC pool tags before planning node-group changes."
    }
  }
}

# A capacity group can narrow a named pool to one AZ without creating a second
# VPC pool tag for the same subnet. Exact-one discovery makes a miss or a
# duplicate tag fail before EKS can silently place the MNG in another zone.
data "aws_subnets" "worker_capacity_group" {
  for_each = {
    for name, group in var.worker_capacity_groups : name => group
    if group.availability_zone != null && group.subnet_pool != null
  }

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.shared.id]
  }

  filter {
    name   = "tag:space.pplx.net/subnet-pool"
    values = [each.value.subnet_pool]
  }

  filter {
    name   = "availability-zone"
    values = [each.value.availability_zone]
  }

  lifecycle {
    postcondition {
      condition     = length(self.ids) == 1
      error_message = "Worker capacity group `${each.key}` expected exactly one subnet in pool `${each.value.subnet_pool}` and AZ `${each.value.availability_zone}` but discovered ${length(self.ids)}. Repair the VPC pool tags or group AZ before planning node-group changes."
    }
  }
}
