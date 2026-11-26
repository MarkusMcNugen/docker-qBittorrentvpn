# Building and testing

```bash
docker buildx build --build-arg "$(bash build/resolve-qt.sh)" -t qbittorrentvpn:dev .
```

## Build arguments

| Argument | Default | Meaning |
|---|---|---|
| `QBITTORRENT_VERSION` | `latest` | qBittorrent release, 5.0 or newer |
| `LIBTORRENT_SERIES` | `2.1` | `2.1`, `2.0` or `1.2` |
| `LIBTORRENT_VERSION` | `latest` | Release within the series |
| `QT_VERSION` | none | Alpine's `qt6-qtbase` version to compile against; `build/resolve-qt.sh` prints the current one for this machine's architecture |
| `INSTALL_PYTHON` | `yes` | `no` leaves out Python, which the search plugins need |
| `BUILD_JOBS` | from CPUs and memory | Compiler parallelism |
| `ALPINE_VERSION` | `3.24` | Base image |

`latest` is resolved through the GitHub API when the build runs. Pass `--secret id=github_token,env=GITHUB_TOKEN` to avoid its rate limit. Docker caches the resolved step, so pass explicit versions, or `--no-cache`, to pick up a new release.

The qBittorrent tarball must carry a valid signature from the key in `keys/`, and both tarballs must match the SHA-256 digests GitHub records; the build stops otherwise.

musl declares `ioctl` with an `int` request, and libtorrent passes `FS_IOC_*` requests that do not fit one, which GCC reports as `-Woverflow`. Before compiling, the build casts each such request to `int`, which keeps every bit the kernel reads. Calls that already cast, and releases without such calls, are left alone. The log names each line it changed, and the libtorrent and qBittorrent steps each end with their count of compiler and CMake warnings.

qBittorrent compiles against Qt's private headers, so it must run on the exact Qt build it was compiled against. The build records a SHA-256 digest of that Qt's core library, and the final stage fails when its own Qt does not match it. `QT_VERSION` pins the compile to the Qt that Alpine ships, so a Qt update recompiles qBittorrent instead of reusing a cached build.

## Tests

```bash
bash tests/run.sh unit qbittorrentvpn:dev
bash tests/run.sh e2e qbittorrentvpn:dev
```

The unit tests run inside the image, against its own bash, busybox and awk, with Python's `hashlib` and `ipaddress` as oracles, the kernel's `iptables-restore` and `wg` checking the generated rules and configurations, and the image's `natpmpc` talking to the test double's NAT-PMP responder. They need an image built with Python, which is the default. The end-to-end tests need a Docker host with the WireGuard module; they build a small test double and record the container's traffic with tcpdump.
