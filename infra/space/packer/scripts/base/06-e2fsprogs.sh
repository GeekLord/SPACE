#!/usr/bin/env bash
# Install e2fsprogs new enough to handle ext4 features used by current seed
# rootfs images. AL2023 currently ships e2fsck 1.46.5, which fails on Ubuntu
# rootfs FEATURE_C12 during recipe builds.
set -euo pipefail

MIN_E2FSPROGS_VERSION="${MIN_E2FSPROGS_VERSION:-1.47.0}"
E2FSPROGS_VERSION="${E2FSPROGS_VERSION:-1.47.0}"
E2FSPROGS_URL="${E2FSPROGS_URL:-https://mirrors.edge.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v${E2FSPROGS_VERSION}/e2fsprogs-${E2FSPROGS_VERSION}.tar.xz}"
# The tarball's SHA-256, from the sha256sums.asc published beside it. A version
# override must bring its own.
if [[ -z "${E2FSPROGS_SHA256:-}" && "$E2FSPROGS_VERSION" == "1.47.0" ]]; then
  E2FSPROGS_SHA256="144af53f2bbd921cef6f8bea88bb9faddca865da3fbc657cc9b4d2001097d5db"
fi
E2FSPROGS_PREFIX="${E2FSPROGS_PREFIX:-/opt/space/e2fsprogs}"
AL2023_RELEASEVER="${AL2023_RELEASEVER:-latest}"

version_ge() {
  local actual="$1"
  local minimum="$2"
  [[ "$(printf '%s\n%s\n' "$minimum" "$actual" | sort -V | head -n1)" == "$minimum" ]]
}

e2fsck_version_output="$(e2fsck -V 2>&1 || true)"
current_version="$(awk 'NR == 1 {print $2}' <<< "$e2fsck_version_output")"
current_lib_version="$(awk '/Using EXT2FS Library version/ {gsub(",", "", $5); print $5}' <<< "$e2fsck_version_output")"
wrapper_ok=false
if [[ -f /usr/local/sbin/e2fsck ]] && grep -q "$E2FSPROGS_PREFIX/sbin/e2fsck" /usr/local/sbin/e2fsck 2>/dev/null; then
  wrapper_ok=true
fi
if [[ -n "$current_version" ]] \
  && version_ge "$current_version" "$MIN_E2FSPROGS_VERSION" \
  && { [[ -z "$current_lib_version" ]] || version_ge "$current_lib_version" "$MIN_E2FSPROGS_VERSION"; } \
  && [[ "$wrapper_ok" == "true" ]] \
  && [[ ! -f /etc/ld.so.conf.d/space-e2fsprogs.conf ]]; then
  echo "e2fsprogs $current_version is new enough"
  exit 0
fi

echo "Installing e2fsprogs ${E2FSPROGS_VERSION}; current e2fsck is ${current_version:-unknown}, libext2fs is ${current_lib_version:-unknown}, wrapper_ok=${wrapper_ok}"

if command -v dnf >/dev/null 2>&1; then
  dnf --releasever="$AL2023_RELEASEVER" install -y gcc make tar xz
elif command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y gcc make tar xz-utils
else
  echo "No supported package manager found" >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

if [[ -z "${E2FSPROGS_SHA256:-}" ]]; then
  echo "ERROR: set E2FSPROGS_SHA256 for e2fsprogs ${E2FSPROGS_VERSION}" >&2
  exit 1
fi
curl --retry 5 --retry-delay 2 --retry-max-time 180 --connect-timeout 20 --retry-all-errors \
  -fsSL "$E2FSPROGS_URL" -o "$tmpdir/e2fsprogs.tar.xz"
echo "${E2FSPROGS_SHA256}  $tmpdir/e2fsprogs.tar.xz" | sha256sum -c -
tar -C "$tmpdir" -xJf "$tmpdir/e2fsprogs.tar.xz"

cd "$tmpdir/e2fsprogs-${E2FSPROGS_VERSION}"
./configure --prefix="$E2FSPROGS_PREFIX" --enable-elf-shlibs --disable-uuidd
make -j"$(nproc)"
make install
make install-libs

# Do not add the private library directory to the global dynamic linker path:
# e2fsprogs also builds libblkid, which can break util-linux tools like btrfs
# and findmnt if it shadows the system libblkid. Use command wrappers instead.
rm -f /etc/ld.so.conf.d/space-e2fsprogs.conf
legacy_lib_dir="/usr/local/lib/space-e2fsprogs-legacy"
for lib_glob in libblkid.so* libuuid.so* libext2fs.so* libe2p.so* libcom_err.so* libss.so*; do
  if compgen -G "/usr/local/lib/$lib_glob" >/dev/null; then
    mkdir -p "$legacy_lib_dir"
    mv -f /usr/local/lib/$lib_glob "$legacy_lib_dir"/
  fi
done
ldconfig || true
mkdir -p /usr/local/sbin
for tool in e2fsck resize2fs dumpe2fs tune2fs; do
  cat > "/usr/local/sbin/$tool" <<EOF
#!/usr/bin/env bash
export LD_LIBRARY_PATH="$E2FSPROGS_PREFIX/lib:\${LD_LIBRARY_PATH:-}"
exec "$E2FSPROGS_PREFIX/sbin/$tool" "\$@"
EOF
  chmod 0755 "/usr/local/sbin/$tool"
done

hash -r
e2fsck -V
resize2fs 2>&1 | head -n1 || true
