#!/bin/bash
# Builds libtorrent (static) and qbittorrent-nox from the trees fetch-sources.sh
# unpacked under /src, and installs the result under /out:
#   /out/usr/bin/qbittorrent-nox
#   /out/usr/local/share/qbtvpn/runtime-deps   apk "so:" names the binary links against
#   /out/usr/local/share/qbtvpn/build-info     versions and build flags
#   /out/usr/local/share/qbtvpn/qt-core.sha256 digest of the Qt core library it was built against
#
# BUILD_JOBS sets the compiler parallelism; when empty it is the smaller of the
# CPU count and one job per 1.5 GB of available memory, at least 1.
set -euo pipefail

src=/src
out=/out
. "$src/versions.env"

log() { printf '%s build: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

# warning_report `NAME` `LOG`: logs how many compiler and CMake warnings the
# configure and compile output in `LOG` holds.
warning_report() {
  local compiler cmake
  compiler=$(awk '/: warning: / { n++ } END { print n + 0 }' "$2")
  cmake=$(awk '/^CMake (Deprecation |Developer )?Warning/ { n++ } END { print n + 0 }' "$2")
  log "$1: ${compiler} compiler warning(s), ${cmake} CMake warning(s)"
}

# An ioctl call whose request argument is a bare `FS_IOC_*` constant.
ioctl_bare_request='(ioctl[[:space:]]*[(][[:space:]]*[^,()]+,[[:space:]]*)(FS_IOC_[A-Z0-9_]+)([[:space:]]*,)'

# cast_ioctl_requests `TREE`: when the C library declares ioctl(int, int, ...),
# as musl does, gives each bare `FS_IOC_*` request under `TREE`/src an explicit
# int cast. Those constants exceed INT_MAX, so the implicit conversion draws
# -Woverflow; the cast keeps the 32 bits the kernel reads. Calls that already
# cast, and releases without such calls, are left as they are.
cast_ioctl_requests() {
  local tree="$1" file lines changed=0
  if ! grep -Eq 'ioctl[[:space:]]*[(][[:space:]]*int[[:space:]]*,[[:space:]]*int[[:space:]]*,' /usr/include/sys/ioctl.h; then
    log "libtorrent: this C library's ioctl takes an unsigned long request; no casts needed"
    return 0
  fi
  while IFS= read -r file; do
    lines=$(RE="$ioctl_bare_request" awk '$0 ~ ENVIRON["RE"] { printf "%s%d", sep, NR; sep = "," }' "$file")
    [ -n "$lines" ] || continue
    sed -E -i "s/${ioctl_bare_request}/\\1static_cast<int>(\\2)\\3/g" "$file"
    log "libtorrent: cast the ioctl request to int at ${file#"$tree"/}:${lines}"
    changed=$((changed + 1))
  done < <(find "$tree/src" -name '*.cpp' | sort)
  if [ "$changed" -eq 0 ]; then
    log "libtorrent: no ioctl request needs a cast"
  fi
}

if [ -n "${BUILD_JOBS:-}" ]; then
  jobs="$BUILD_JOBS"
else
  cpus=$(nproc)
  mem_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  by_mem=$((mem_kb / 1572864))
  jobs=$(( cpus < by_mem ? cpus : by_mem ))
  [ "$jobs" -ge 1 ] || jobs=1
fi
log "qBittorrent ${QBITTORRENT_VERSION}, libtorrent ${LIBTORRENT_VERSION}, ${jobs} parallel jobs"

case "$LIBTORRENT_SERIES" in
  1.2) lt_std=17 ;;
  *) lt_std=20 ;;
esac

hardening_c="-fstack-clash-protection"
hardening_ld="-Wl,-z,relro,-z,now,-z,noexecstack"

lt_opts=(
  -G Ninja
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX=/opt/libtorrent
  -DCMAKE_CXX_STANDARD="$lt_std"
  -DCMAKE_CXX_FLAGS="$hardening_c"
  -DBUILD_SHARED_LIBS=OFF
  -DCMAKE_POLICY_DEFAULT_CMP0167=NEW
  -DCMAKE_POLICY_DEFAULT_CMP0183=NEW
  -Ddeprecated-functions=OFF
  -Dencryption=ON
)
if [ "$LIBTORRENT_SERIES" = 2.1 ]; then
  lt_opts+=(-Dwebtorrent=OFF)
fi

cast_ioctl_requests "$src/libtorrent"
log "configuring libtorrent"
cmake -S "$src/libtorrent" -B /build/libtorrent "${lt_opts[@]}" 2>&1 | tee /build/libtorrent.log
log "compiling libtorrent"
cmake --build /build/libtorrent --parallel "$jobs" 2>&1 | tee -a /build/libtorrent.log
warning_report libtorrent /build/libtorrent.log
cmake --install /build/libtorrent

log "configuring qBittorrent"
cmake -S "$src/qbittorrent" -B /build/qbittorrent \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_PREFIX_PATH=/opt/libtorrent \
  -DCMAKE_CXX_FLAGS="$hardening_c" \
  -DCMAKE_EXE_LINKER_FLAGS="$hardening_ld" \
  -DGUI=OFF \
  -DSTACKTRACE=OFF \
  -DTESTING=OFF \
  -DQT_NO_PRIVATE_MODULE_WARNING=ON 2>&1 | tee /build/qbittorrent.log
log "compiling qBittorrent"
cmake --build /build/qbittorrent --parallel "$jobs" 2>&1 | tee -a /build/qbittorrent.log
warning_report qBittorrent /build/qbittorrent.log
DESTDIR="$out" cmake --install /build/qbittorrent
strip --strip-unneeded "$out/usr/bin/qbittorrent-nox"

share="$out/usr/local/share/qbtvpn"
mkdir -p "$share"
scanelf --needed --nobanner --format '%n#p' "$out/usr/bin/qbittorrent-nox" \
  | tr ',' '\n' | awk 'NF {print "so:" $1}' | sort -u >"$share/runtime-deps"
log "runtime libraries: $(tr '\n' ' ' <"$share/runtime-deps")"

# qBittorrent uses Qt's private headers, so it must run on this exact Qt
# build; the final stage checks its Qt against this digest.
qt_version=$(pkg-config --modversion Qt6Core)
sha256sum "$(readlink -f /usr/lib/libQt6Core.so.6)" >"$share/qt-core.sha256"
log "Qt ${qt_version}: $(cat "$share/qt-core.sha256")"

"$out/usr/bin/qbittorrent-nox" --version 2>&1 | tee "$share/qbittorrent-version" >&2

cat >"$share/build-info" <<EOF
QBITTORRENT_VERSION=${QBITTORRENT_VERSION}
LIBTORRENT_VERSION=${LIBTORRENT_VERSION}
LIBTORRENT_SERIES=${LIBTORRENT_SERIES}
LIBTORRENT_CXX_STANDARD=${lt_std}
QT_VERSION=${qt_version}
EOF
log "done"
