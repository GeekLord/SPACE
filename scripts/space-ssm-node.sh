#!/usr/bin/env bash
# Start an AWS SSM session, or run a command through SSM, on a SPACE EKS node.

set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: scripts/space-ssm-node.sh (--builder | --workers | --general | --node NODE | --instance-id ID | ID) [options]

Options:
  --builder              Select a random node labeled space.pplx.net/node-pool=builders.
  --workers              Select a random node labeled space.pplx.net/node-pool=workers.
  --general              Select nodes labeled space.pplx.net/node-pool=general.
  --node NODE            Select an exact Kubernetes node name.
  --instance-id ID       Select an exact EC2 instance ID; does not require Kubernetes.
  --profile PROFILE      AWS profile to use for all AWS CLI calls.
  --region REGION        AWS region to use for all AWS CLI calls.
  --command COMMAND      Run COMMAND through AWS-RunShellScript and print its output.
  -h, --help             Show this help.

Examples:
  scripts/space-ssm-node.sh --builder
  scripts/space-ssm-node.sh --workers
  scripts/space-ssm-node.sh --node ip-10-0-1-23.ec2.internal
  scripts/space-ssm-node.sh i-0123456789abcdef0 --profile sandbox --region us-east-1
  scripts/space-ssm-node.sh --instance-id i-0123456789abcdef0 --profile sandbox --region us-east-1
  scripts/space-ssm-node.sh --workers --command 'journalctl -u kubelet -n 200 --no-pager'
USAGE
}

node_pool=""
node=""
instance_id=""
aws_profile=""
aws_region=""
command=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --builder)
      node_pool="builders"
      shift
      ;;
    --workers)
      node_pool="workers"
      shift
      ;;
    --general)
      node_pool="general"
      shift
      ;;
    --node)
      node="${2:-}"
      [[ -n "$node" ]] || { echo "error: --node requires a value" >&2; exit 2; }
      shift 2
      ;;
    --instance-id)
      instance_id="${2:-}"
      [[ "$instance_id" =~ ^i-[0-9a-fA-F]+$ ]] || { echo "error: --instance-id requires an EC2 instance id" >&2; exit 2; }
      shift 2
      ;;
    --profile)
      aws_profile="${2:-}"
      [[ -n "$aws_profile" ]] || { echo "error: --profile requires a value" >&2; exit 2; }
      shift 2
      ;;
    --region)
      aws_region="${2:-}"
      [[ -n "$aws_region" ]] || { echo "error: --region requires a value" >&2; exit 2; }
      shift 2
      ;;
    --command)
      command="${2:-}"
      [[ -n "$command" ]] || { echo "error: --command requires a value" >&2; exit 2; }
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    i-[0-9a-fA-F]*)
      if [[ -n "$instance_id" ]]; then
        echo "error: use only one instance id" >&2
        exit 2
      fi
      instance_id="$1"
      [[ "$instance_id" =~ ^i-[0-9a-fA-F]+$ ]] || { echo "error: instance id must match i-[0-9a-fA-F]+" >&2; exit 2; }
      shift
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

target_count=0
[[ -n "$node" ]] && target_count=$((target_count + 1))
[[ -n "$node_pool" ]] && target_count=$((target_count + 1))
[[ -n "$instance_id" ]] && target_count=$((target_count + 1))

if [[ "$target_count" -gt 1 ]]; then
  echo "error: use only one of --node, --instance-id, --builder, --workers, or --general" >&2
  exit 2
fi

if [[ "$target_count" -eq 0 ]]; then
  echo "error: choose a node target with --builder, --workers, --general, --node, or --instance-id" >&2
  usage
  exit 2
fi

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    exit 127
  fi
}

require aws
if [[ -z "$instance_id" ]]; then
  require kubectl
fi

aws_cli() {
  local args=()
  [[ -n "$aws_profile" ]] && args+=(--profile "$aws_profile")
  [[ -n "$aws_region" ]] && args+=(--region "$aws_region")
  aws "${args[@]}" "$@"
}

provider_id_for_node() {
  local k8s_node="$1"
  kubectl get node "$k8s_node" -o jsonpath='{.spec.providerID}'
}

instance_id_from_provider_id() {
  local provider_id="$1"
  local instance_id="${provider_id##*/}"
  if [[ ! "$instance_id" =~ ^i-[0-9a-fA-F]+$ ]]; then
    echo "error: node providerID did not contain an EC2 instance id: ${provider_id:-<empty>}" >&2
    exit 1
  fi
  printf '%s\n' "$instance_id"
}

wait_for_ssm_online() {
  local instance_id="$1"

  echo "Waiting for SSM managed instance to come online"
  for _ in {1..60}; do
    local ping_status
    if ! ping_status="$(
      aws_cli ssm describe-instance-information \
        --filters "Key=InstanceIds,Values=$instance_id" \
        --query 'InstanceInformationList[0].PingStatus' \
        --output text
    )"; then
      echo "error: failed to describe SSM instance information: $instance_id" >&2
      exit 1
    fi

    if [[ "$ping_status" == "Online" ]]; then
      return
    fi

    sleep 5
  done

  echo "error: SSM managed instance did not become Online: $instance_id" >&2
  exit 1
}

run_ssm_command() {
  local instance_id="$1"
  local shell_command="$2"
  local command_id

  command_id="$(
    aws_cli ssm send-command \
      --instance-ids "$instance_id" \
      --document-name AWS-RunShellScript \
      --comment "space operator command" \
      --parameters "commands=$shell_command" \
      --query 'Command.CommandId' \
      --output text
  )"

  set +e
  aws_cli ssm wait command-executed \
    --command-id "$command_id" \
    --instance-id "$instance_id"
  local wait_status=$?
  set -e

  aws_cli ssm get-command-invocation \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --query '{Status:Status,ResponseCode:ResponseCode,Stdout:StandardOutputContent,Stderr:StandardErrorContent}' \
    --output json

  local response_code
  response_code="$(
    aws_cli ssm get-command-invocation \
      --command-id "$command_id" \
      --instance-id "$instance_id" \
      --query 'ResponseCode' \
      --output text
  )"

  if [[ "$wait_status" -ne 0 || "$response_code" != "0" ]]; then
    return 1
  fi
}

selected_node=""
if [[ -z "$instance_id" ]]; then
  declare -a nodes=()
  if [[ -n "$node" ]]; then
    nodes=("$node")
  else
    node_label="space.pplx.net/node-pool=${node_pool}"
    node_output="$(
      kubectl get nodes -l "$node_label" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
    )" || {
      echo "error: failed to list Kubernetes nodes for pool: $node_pool" >&2
      exit 1
    }

    while IFS= read -r matched_node; do
      [[ -n "$matched_node" ]] && nodes+=("$matched_node")
    done < <(printf '%s\n' "$node_output" | sort)
  fi

  if [[ "${#nodes[@]}" -eq 0 ]]; then
    echo "error: no matching nodes found" >&2
    exit 1
  fi

  selected_node="${nodes[$((RANDOM % ${#nodes[@]}))]}"
  provider_id="$(provider_id_for_node "$selected_node")"
  instance_id="$(instance_id_from_provider_id "$provider_id")"
fi

echo "Resolved SPACE node"
if [[ -n "$selected_node" ]]; then
  echo "  node:             $selected_node"
fi
echo "  instance_id:      $instance_id"
echo

wait_for_ssm_online "$instance_id"

if [[ -n "$command" ]]; then
  run_ssm_command "$instance_id" "$command"
else
  echo "Starting SSM session"
  aws_cli ssm start-session \
    --target "$instance_id"
fi
