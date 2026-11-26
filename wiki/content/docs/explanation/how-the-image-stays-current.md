---
title: How the image stays current
weight: 4
---

qBittorrent publishes no headless Linux builds, and distribution packages lag behind its releases. So the image compiles qBittorrent and libtorrent from source, and a workflow publishes a new image whenever either releases. The workflow is `.github/workflows/publish.yml`; the build is the `Dockerfile` with the scripts in `build/`.

## When a new image is built

| Trigger | When | Builds |
|---|---|---|
| Daily check | 06:17 UTC | Only when the newest qBittorrent, libtorrent or the repository's `VERSION` differs from the labels on the published image |
| Weekly rebuild | Sundays, 03:43 UTC | Always, so Alpine's security fixes reach the image even when nothing else changed |
| Manual run | on demand | When the versions differ, or always with the `force` option |

## How it is built

1. **Sources.** `build/resolve-versions.sh` finds the newest stable qBittorrent release and the newest libtorrent release in the chosen series through the GitHub API. The qBittorrent tarball must carry a valid signature from the key in `keys/`, and both tarballs must match the SHA-256 digests GitHub records for them.
2. **Compile.** libtorrent is built as a static library and qBittorrent against it, both against Alpine's own Qt 6, Boost and OpenSSL, with no compiler or CMake warnings. Where libtorrent passes `ioctl` requests that musl's `int` parameter cannot hold, the build casts them, only in the releases that still need it.
3. **Pin Qt.** qBittorrent uses Qt's private headers, so it must run on the exact Qt it was compiled with. `build/resolve-qt.sh` reads the Qt version Alpine ships and passes it to the build, so a Qt update recompiles qBittorrent instead of reusing a cached build, and the final stage fails if its Qt differs from the one the build recorded.
4. **Runtime.** The final image holds the compiled programs, the runtime libraries they link against, OpenVPN, WireGuard tools, Privoxy and the scripts.

## How it is published

Each architecture, `linux/amd64` and `linux/arm64`, is built on its own GitHub runner and must pass the unit and end-to-end tests before it is pushed. The two are then joined under one set of tags on Docker Hub and GHCR, and GitHub signs an attestation of the build.

| Tag | Points at |
|---|---|
| `latest` | The newest build |
| `5.3.1` | The newest build of that qBittorrent release |
| `5.3` | The newest build of that qBittorrent series |
| `5.3.1-lt2.1.3` | That qBittorrent with that libtorrent |
| `v2.1.0` | The newest build of that release of the image |

The numbers are those of the current release; each new release adds its own. Pin `latest` to follow qBittorrent, or a `v` tag to stay on one release of the image's scripts while still receiving rebuilds.

A new image version, a change of `VERSION`, also gets a GitHub release with its changelog section as notes, created by the same workflow.
