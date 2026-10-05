#!/usr/bin/env bash
# Run gofmt, go vet, and go test for the containerd shim module.
#
# Called by the Buildkite pipeline as the fast validation gate before the
# shim artifact is built and published.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SHIM_DIR="${REPO_ROOT}/shim"
PROTOC_VERSION="${PROTOC_VERSION:-35.0}"
PROTOC_GEN_GO_VERSION="${PROTOC_GEN_GO_VERSION:-v1.36.11}"
PROTOC_GEN_GO_GRPC_VERSION="${PROTOC_GEN_GO_GRPC_VERSION:-v1.6.1}"
TOOL_CACHE_DIR="${SPACE_BUILDKITE_TOOL_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/space-buildkite-tools}"
PINNED_PROTOC_BIN_DIR=""
GO_PROTOC_PLUGIN_BIN_DIR=""
TRANSIENT_NETWORK_EXIT_STATUS=75

curl_with_retries() {
  local status=0

  curl --retry 5 --retry-delay 2 --retry-max-time 180 --retry-all-errors "$@" || status="$?"
  if [ "${status}" -eq 0 ]; then
    return
  fi

  echo "Tool download failed after retries; requesting a fresh CI agent." >&2
  return "${TRANSIENT_NETWORK_EXIT_STATUS}"
}

is_go_transient_network_error() {
  local output_file="$1"

  # Only classify as transient when a module-download/proxy marker and a
  # network-failure marker co-occur on the SAME line. Matching the two marker
  # groups anywhere in the output is too loose: `go vet`/`go test` for this
  # networking shim exercise dial/connect retry logic and can legitimately
  # print phrases like `connection refused` or `i/o timeout` on a genuine test
  # failure, while a cold module cache separately prints `go: downloading`.
  # Requiring co-occurrence on one line keeps real download errors (the Go
  # toolchain emits the proxy host and the network error together, e.g.
  # `go: downloading ...: ... proxy.golang.org ...: unexpected EOF`) classified
  # as transient without masking real vet/test failures.
  grep -Eiq '(proxy\.golang\.org|go: downloading).*(stream error|INTERNAL_ERROR|unexpected EOF|i/o timeout|TLS handshake timeout|connection reset|connection refused|no such host|network is unreachable|temporary failure|timeout awaiting response headers|502 Bad Gateway|503 Service Unavailable|504 Gateway Timeout)' "$output_file"
}

run_go_with_transient_network_exit() {
  local output_file status

  output_file="$(mktemp)"
  set +e
  "$@" 2> >(tee "$output_file" >&2)
  status="$?"
  set -e

  if [ "$status" -eq 0 ]; then
    rm -f "$output_file"
    return 0
  fi

  if is_go_transient_network_error "$output_file"; then
    rm -f "$output_file"
    echo "Detected transient Go module download/network failure; exiting ${TRANSIENT_NETWORK_EXIT_STATUS} so Buildkite can retry." >&2
    return "$TRANSIENT_NETWORK_EXIT_STATUS"
  fi

  rm -f "$output_file"
  return "$status"
}

run_install_tools() {
  local uv_bin
  uv_bin="$(bash "${REPO_ROOT}/ci/scripts/ensure-uv.sh")"
  export UV_CACHE_DIR="${UV_CACHE_DIR:-${TMPDIR:-/tmp}/space-uv-cache}"
  mkdir -p "${UV_CACHE_DIR}"
  "${uv_bin}" run --script "${REPO_ROOT}/ci/scripts/install-tools.py" "$@"
}

install_go() {
  if command -v go &>/dev/null; then
    echo "Go already available: $(go version)"
    return
  fi

  echo "--- :golang: Installing Go via install-tools.py"
  run_install_tools go
  export PATH="/usr/local/go/bin:${PATH}"
}

extract_zip() {
  local zip_file="$1" dest_dir="$2"
  if command -v unzip &>/dev/null; then
    unzip -q "$zip_file" -d "$dest_dir"
  elif command -v busybox &>/dev/null && busybox unzip -l "$zip_file" &>/dev/null; then
    busybox unzip -q "$zip_file" -d "$dest_dir"
  elif command -v perl &>/dev/null; then
    perl -MIO::Uncompress::Unzip=unzip -e '
      use IO::Uncompress::Unzip qw(unzip $UnzipError);
      use File::Path qw(make_path);
      use File::Basename qw(dirname);
      my ($src, $dst) = @ARGV;
      my $u = IO::Uncompress::Unzip->new($src) or die "Cannot open $src: $UnzipError\n";
      my $status;
      for ($status = 1; $status > 0; $status = $u->nextStream()) {
        my $name = $u->getHeaderInfo()->{Name};
        my $out = "$dst/$name";
        if ($name =~ m{/$}) { make_path($out); next; }
        make_path(dirname($out));
        open my $fh, ">", $out or die "Cannot write $out: $!\n";
        binmode $fh;
        my $buf;
        while ($u->read($buf) > 0) { print $fh $buf; }
        close $fh;
      }
    ' "$zip_file" "$dest_dir"
  elif command -v python3 &>/dev/null; then
    python3 -m zipfile -e "$zip_file" "$dest_dir"
  else
    echo "Error: no zip extraction tool found (need unzip, busybox, perl, or python3)" >&2
    return 1
  fi
}

install_protoc() {
  local current_version platform archive tool_dir

  if command -v protoc &>/dev/null; then
    current_version="$(protoc --version | awk '{print $2}')"
    if [ "${current_version}" = "${PROTOC_VERSION}" ]; then
      PINNED_PROTOC_BIN_DIR="$(dirname "$(command -v protoc)")"
      echo "protoc already installed ($(protoc --version))"
      return
    fi
    echo "protoc version ${current_version} found, using pinned ${PROTOC_VERSION}"
  fi

  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)
      platform="linux-x86_64"
      ;;
    Darwin-arm64)
      platform="osx-aarch_64"
      ;;
    Darwin-x86_64)
      platform="osx-x86_64"
      ;;
    *)
      echo "Error: unsupported platform for protoc install: $(uname -s)-$(uname -m)" >&2
      return 1
      ;;
  esac

  tool_dir="${TOOL_CACHE_DIR}/protoc-${PROTOC_VERSION}-${platform}"
  if [ -x "${tool_dir}/bin/protoc" ]; then
    PINNED_PROTOC_BIN_DIR="${tool_dir}/bin"
    export PATH="${tool_dir}/bin:${PATH}"
    echo "protoc pinned at $("${tool_dir}"/bin/protoc --version)"
    return
  fi

  echo "--- :protobuf: Installing protoc v${PROTOC_VERSION}"
  local tmp
  tmp="$(mktemp -d)"
  archive="protoc-${PROTOC_VERSION}-${platform}.zip"
  curl_with_retries -fsSL \
    "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/${archive}" \
    -o "${tmp}/protoc.zip"
  extract_zip "${tmp}/protoc.zip" "${tmp}/protoc"
  chmod 0755 "${tmp}/protoc/bin/protoc"
  rm -rf "${tool_dir}"
  mkdir -p "$(dirname "${tool_dir}")"
  mv "${tmp}/protoc" "${tool_dir}"
  rm -rf "${tmp}"
  PINNED_PROTOC_BIN_DIR="${tool_dir}/bin"
  export PATH="${tool_dir}/bin:${PATH}"
  echo "protoc $(protoc --version)"
}

install_protoc_go_plugins() {
  local expected_go_version expected_grpc_version go_bin grpc_bin

  expected_go_version="${PROTOC_GEN_GO_VERSION#v}"
  expected_grpc_version="${PROTOC_GEN_GO_GRPC_VERSION#v}"
  go_bin="$(command -v protoc-gen-go || true)"
  grpc_bin="$(command -v protoc-gen-go-grpc || true)"
  if [[ -n "${go_bin}" && -n "${grpc_bin}" ]] \
    && [[ "$(protoc-gen-go --version)" == "protoc-gen-go v${expected_go_version}" ]] \
    && [[ "$(protoc-gen-go-grpc --version)" == "protoc-gen-go-grpc ${expected_grpc_version}" ]]; then
    GO_PROTOC_PLUGIN_BIN_DIR="$(dirname "${go_bin}"):$(dirname "${grpc_bin}")"
    echo "Go protobuf generators already installed"
    return
  fi

  echo "--- :protobuf: Installing Go protobuf generators"
  run_go_with_transient_network_exit go install "google.golang.org/protobuf/cmd/protoc-gen-go@${PROTOC_GEN_GO_VERSION}"
  run_go_with_transient_network_exit go install "google.golang.org/grpc/cmd/protoc-gen-go-grpc@${PROTOC_GEN_GO_GRPC_VERSION}"

  GO_PROTOC_PLUGIN_BIN_DIR="$(go env GOBIN)"
  if [ -z "${GO_PROTOC_PLUGIN_BIN_DIR}" ]; then
    GO_PROTOC_PLUGIN_BIN_DIR="$(go env GOPATH)/bin"
  fi
  export PATH="${GO_PROTOC_PLUGIN_BIN_DIR}:${PATH}"
}

check_generated_proto() {
  local before after generate_path

  before="$(git -C "${REPO_ROOT}" --no-pager diff -- shim/proto)"

  (
    cd "${SHIM_DIR}"
    generate_path="${PINNED_PROTOC_BIN_DIR}:${GO_PROTOC_PLUGIN_BIN_DIR}:${PATH}"
    PATH="${generate_path}" protoc --version
    run_go_with_transient_network_exit env PATH="${generate_path}" go generate ./proto
  )

  after="$(git -C "${REPO_ROOT}" --no-pager diff -- shim/proto)"

  if [ "${before}" != "${after}" ]; then
    git -C "${REPO_ROOT}" --no-pager diff -- shim/proto
    echo "Generated shim protobuf is stale. Run from repo root:" >&2
    echo "  cd shim && go generate ./proto" >&2
    return 1
  fi
}

check_gofmt() {
  local unformatted

  unformatted="$(
    cd "${SHIM_DIR}"
    find . -type f -name '*.go' -print0 | xargs -0 gofmt -l
  )"

  if [ -n "${unformatted}" ]; then
    echo "gofmt found unformatted files:" >&2
    printf '%s\n' "${unformatted}" >&2
    return 1
  fi
}

main() {
  install_go
  install_protoc
  install_protoc_go_plugins

  # Otherwise the first command below that needs a module fetches it, and one
  # dropped download fails the job. Downloads that keep failing still exit 75.
  echo "--- :golang: Downloading shim modules"
  ( cd "${SHIM_DIR}" && run_go_with_transient_network_exit bash "${SCRIPT_DIR}/go-mod-download.sh" )

  echo "--- :protobuf: Checking generated shim protobuf"
  check_generated_proto

  echo "--- :golang: Running gofmt -l"
  check_gofmt

  echo "--- :golang: Running go vet"
  ( cd "${SHIM_DIR}" && run_go_with_transient_network_exit go vet ./... )

  echo "--- :golang: Running go test"
  ( cd "${SHIM_DIR}" && run_go_with_transient_network_exit go test -v -count=1 ./... )
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
