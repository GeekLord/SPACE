# SPACE SSD usage scripts

Read-only helpers for inspecting SPACE BTRFS SSD usage under `/space/cache`.

- `get-nodes-ssd-space.py` -- cluster-wide read-only scan of SPACE `/space/cache` BTRFS SSD usage, reaching every node with a probeable template-manager pod, no matter which release owns it, and tabling the ones at or above `--threshold`. It also names the nodes whose template-manager pod isn't probeable — not Running+Ready, or terminating — plus any pod that never scheduled, and the probes that failed, each tagged with the owning release; this is the node summary table used during SSD draining.
- `get-node-sandbox-disk-usage.py` -- per-sandbox BTRFS usage for one worker node via AWS SSM.
- `get-node-template-disk-usage.py` -- per-template BTRFS usage for cached templates on one worker node via AWS SSM.

Pass `--context <kube-context>` explicitly when scanning a cluster or looking up a
Kubernetes node. The per-node SSM scripts also require `--profile <aws-profile>`;
with `--instance-id`, they skip Kubernetes lookup and do not require a context.

```sh
python3 scripts/disk-usage/get-nodes-ssd-space.py --context example-cluster
python3 scripts/disk-usage/get-node-sandbox-disk-usage.py worker-example --context example-cluster --profile example-ops
python3 scripts/disk-usage/get-node-template-disk-usage.py --instance-id i-0123456789abcdef0 --profile example-ops
```
