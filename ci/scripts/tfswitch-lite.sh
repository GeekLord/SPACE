#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--version" || "${1:-}" == "-v" ]]; then
  echo "tfswitch-lite 1.1.0"
  exit 0
fi

find_version_file() {
  local dir="${PWD}"
  while [[ "${dir}" != "/" ]]; do
    if [[ -f "${dir}/.terraform-version" ]]; then
      echo "${dir}/.terraform-version"
      return 0
    fi
    dir="$(dirname "${dir}")"
  done
  return 1
}

version="${1:-}"
if [[ -z "${version}" ]]; then
  version_file="$(find_version_file)" || {
    echo "tfswitch: no .terraform-version found in ${PWD} or its parents" >&2
    exit 1
  }
  version="$(tr -d '[:space:]' < "${version_file}")"
fi

if [[ -z "${version}" ]]; then
  echo "tfswitch: empty Terraform version" >&2
  exit 1
fi

case "$(uname -s)" in
  Linux) terraform_os="linux" ;;
  Darwin) terraform_os="darwin" ;;
  *)
    echo "tfswitch: unsupported OS $(uname -s)" >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  x86_64 | amd64) terraform_arch="amd64" ;;
  aarch64 | arm64) terraform_arch="arm64" ;;
  *)
    echo "tfswitch: unsupported architecture $(uname -m)" >&2
    exit 1
    ;;
esac

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "tfswitch: neither sha256sum nor shasum is available" >&2
    exit 1
  fi
}

resolve_uv() {
  local script_dir
  script_dir="$(cd "$(dirname "$0")" && pwd)"

  if [[ -n "${UV_BIN:-}" && -x "${UV_BIN}" ]]; then
    printf '%s\n' "${UV_BIN}"
    return
  fi
  if command -v uv >/dev/null 2>&1; then
    command -v uv
    return
  fi
  if [[ -x "${script_dir}/uv" ]]; then
    printf '%s\n' "${script_dir}/uv"
    return
  fi

  echo "tfswitch: uv is required to extract Terraform" >&2
  exit 1
}

install_dir="${TFSWITCH_INSTALL_DIR:-$(dirname "$(command -v tfswitch)")}"
cache_dir="${TFSWITCH_CACHE_DIR:-${HOME}/.cache/tfswitch-lite}"
terraform_dir="${cache_dir}/terraform/${version}/${terraform_os}_${terraform_arch}"
terraform_bin="${terraform_dir}/terraform"

mkdir -p "${terraform_dir}" "${install_dir}"

if [[ ! -x "${terraform_bin}" ]]; then
  tmp_zip="$(mktemp)"
  tmp_sums="$(mktemp)"
  trap 'rm -f "${tmp_zip}" "${tmp_sums}"' EXIT
  zip_name="terraform_${version}_${terraform_os}_${terraform_arch}.zip"
  base_url="https://releases.hashicorp.com/terraform/${version}"
  url="${base_url}/${zip_name}"
  curl -fsSL "${url}" -o "${tmp_zip}"
  curl -fsSL "${base_url}/terraform_${version}_SHA256SUMS" -o "${tmp_sums}"

  expected_sha256="$(awk -v file="${zip_name}" '$2 == file {print $1}' "${tmp_sums}")"
  if [[ -z "${expected_sha256}" ]]; then
    echo "tfswitch: no SHA256SUMS entry for ${zip_name}" >&2
    exit 1
  fi

  actual_sha256="$(sha256_file "${tmp_zip}")"
  if [[ "${actual_sha256}" != "${expected_sha256}" ]]; then
    echo "tfswitch: SHA256 mismatch for ${zip_name}" >&2
    echo "expected: ${expected_sha256}" >&2
    echo "actual:   ${actual_sha256}" >&2
    exit 1
  fi

  uv_bin="$(resolve_uv)"
  "${uv_bin}" run --no-project --python 3.11 python - "${tmp_zip}" "${terraform_dir}" <<'PY'
import sys
import zipfile

archive, dest = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(archive) as zf:
    zf.extract("terraform", dest)
PY
  chmod 0755 "${terraform_bin}"
fi

ln -sfn "${terraform_bin}" "${install_dir}/terraform"
"${install_dir}/terraform" version
