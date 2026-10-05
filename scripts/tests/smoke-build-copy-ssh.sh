#!/usr/bin/env bash
# Run the build-manager COPY regression through a disposable loopback-only sshd.
# Pass the Linux unit-test executable produced by cargo test --no-run.
set -euo pipefail

if [[ $(uname -s) != Linux || $EUID != 0 || $# != 1 || ! -x $1 ]]; then
  echo "Usage: sudo $0 /absolute/path/to/pplx_space_build_mgr-<hash> (Linux)" >&2
  exit 2
fi

fixture=$(mktemp -d /var/tmp/space-copy-ssh.XXXXXX)
namespace=$(basename "$fixture")
sshd_pid=
namespace_created=false
cleanup() {
  if [[ -n $sshd_pid ]] && kill -0 "$sshd_pid" 2>/dev/null; then
    kill "$sshd_pid"
    wait "$sshd_pid" || true
  fi
  if $namespace_created; then
    ip netns delete "$namespace"
  fi
  rm -rf -- "$fixture"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -f "$fixture/client"
ssh-keygen -q -t ed25519 -N '' -f "$fixture/host"
ip netns add "$namespace"
namespace_created=true
ip netns exec "$namespace" ip link set lo up
ip netns exec "$namespace" /usr/sbin/sshd -D -e -f /dev/null \
  -h "$fixture/host" -o "PidFile=$fixture/sshd.pid" \
  -o "AuthorizedKeysFile=$fixture/client.pub" -o StrictModes=no \
  -o PermitRootLogin=yes -o PasswordAuthentication=no \
  -o KbdInteractiveAuthentication=no -o UsePAM=yes \
  -o ListenAddress=127.0.0.1 >"$fixture/sshd.log" 2>&1 &
sshd_pid=$!

ready=false
for ((attempt = 0; attempt < 50; attempt++)); do
  if ip netns exec "$namespace" ssh -i "$fixture/client" \
    -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=1 root@127.0.0.1 true 2>/dev/null; then
    ready=true
    break
  fi
  sleep 0.1
done
if ! $ready; then
  cat "$fixture/sshd.log" >&2
  exit 1
fi

# Keep host staging separate from the guest's /tmp staging on this loopback smoke.
# Shadow the real blob cache only in the test process's private mount namespace.
mkdir "$fixture/cache" "$fixture/tmp"
SPACE_COPY_SSH_SMOKE_KEY="$fixture/client" SPACE_COPY_SSH_SMOKE_NETNS="$namespace" \
  unshare --mount --propagation private sh -ec '
    mount --bind "$1/cache" /space/cache
    mkdir -p /space/cache/firecracker/build-manager/blobs/sha256
    export TMPDIR="$1/tmp"
    exec "$2" --exact ssh::tests::copy_stream_preserves_links_without_reading_their_targets --nocapture
  ' sh "$fixture" "$1"
