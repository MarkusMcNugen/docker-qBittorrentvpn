---
title: Build arguments
weight: 6
---

The arguments the `Dockerfile` takes, with `docker buildx build --build-arg NAME=VALUE`. How to run a build is in [Build and test](../../how-to/build-and-test/).

| Argument | Default | Meaning |
|---|---|---|
| `QBITTORRENT_VERSION` | `latest` | qBittorrent release, 5.0 or newer |
| `LIBTORRENT_SERIES` | `2.1` | `2.1`, `2.0` or `1.2` |
| `LIBTORRENT_VERSION` | `latest` | Release within the series |
| `QT_VERSION` | none | Alpine's `qt6-qtbase` version to compile against; `build/resolve-qt.sh` prints the current one for the machine's architecture |
| `INSTALL_PYTHON` | `yes` | `no` leaves out Python, which qBittorrent's search plugins need |
| `BUILD_JOBS` | from the CPUs and memory | Compiler parallelism |
| `ALPINE_VERSION` | `3.24` | Base image |
| `IMAGE_VERSION`, `IMAGE_REVISION`, `IMAGE_CREATED` | `dev`, `unknown`, `unknown` | Written to the image's OCI labels; the publish workflow sets them |

`latest` is resolved through the GitHub API when the build runs. Pass `--secret id=github_token,env=GITHUB_TOKEN` to stay clear of its rate limit. Docker caches the resolved step, so pass explicit versions, or `--no-cache`, to pick up a new release.

## What the build checks

- The qBittorrent tarball must carry a valid OpenPGP signature from the key in `keys/`, and both tarballs must match the SHA-256 digests GitHub records for the release assets. The build stops otherwise.
- musl declares `ioctl` with an `int` request, and libtorrent passes `FS_IOC_*` requests that do not fit one, which GCC reports as `-Woverflow`. Before compiling, the build casts each such request to `int`, which keeps every bit the kernel reads. Calls that already cast, and releases without such calls, are left alone. The log names each line it changed, and the libtorrent and qBittorrent steps each end with their count of compiler and CMake warnings.
- qBittorrent compiles against Qt's private headers, so it must run on the exact Qt build it was compiled against. The build records a SHA-256 digest of that Qt's core library, and the final stage fails when its own Qt does not match it. `QT_VERSION` pins the compile to the Qt that Alpine ships, so a Qt update recompiles qBittorrent instead of reusing a cached build.
- The final stage creates the vpn (873) and privoxy (874) users with fixed ids, checks the shell syntax of the entrypoint and its libraries, and runs `qbittorrent-nox --version` and `privoxy --version`.

## Labels

| Label | Value |
|---|---|
| `org.opencontainers.image.version` | `IMAGE_VERSION`, such as `2.1.0` |
| `org.opencontainers.image.revision` | `IMAGE_REVISION`, the commit built |
| `org.opencontainers.image.created` | `IMAGE_CREATED` |
| `org.opencontainers.image.licenses` | `GPL-3.0-only` |
| `io.github.markusmcnugen.qbittorrent.version` | The qBittorrent release built |
| `io.github.markusmcnugen.libtorrent.version` | The libtorrent release built |

The publish workflow compares the qBittorrent, libtorrent and image versions on the published image with the ones it resolves, and builds only when one differs, apart from the weekly rebuild.
