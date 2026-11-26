<div align="center">

# qBittorrent VPN

**qBittorrent built from source, reachable only through an OpenVPN or WireGuard tunnel.**

[![Docker Pulls](https://img.shields.io/docker/pulls/markusmcnugen/qbittorrentvpn?style=flat-square)](https://hub.docker.com/r/markusmcnugen/qbittorrentvpn)
[![License: GPL-3.0-only](https://img.shields.io/badge/license-GPL--3.0--only-blue.svg?style=flat-square)](https://github.com/MarkusMcNugen/docker-qBittorrentvpn/blob/main/LICENSE)
[![Platforms](https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-informational?style=flat-square)](#platforms)

**[Documentation](https://markusmcnugen.github.io/docker-qBittorrentvpn/)** | [Configuration reference](https://markusmcnugen.github.io/docker-qBittorrentvpn/docs/reference/environment-variables/) | [Changelog](https://github.com/MarkusMcNugen/docker-qBittorrentvpn/blob/main/CHANGELOG.md)

The image compiles the newest qBittorrent and libtorrent releases from signed source, then runs qBittorrent behind a firewall that is closed before the VPN starts and stays closed if the VPN drops. Torrent traffic, DNS lookups and IPv6 have no way out except the tunnel.

</div>

---

<details>
<summary><b>Table of contents</b></summary>

- [Features](#features)
- [Quick start](#quick-start)
- [Why this image](#why-this-image)
- [How the kill switch works](#how-the-kill-switch-works)
- [Configuration](#configuration)
- [Port forwarding](#port-forwarding)
- [Upgrading from 1.x](#upgrading-from-1x)
- [Repository layout](#repository-layout)
- [Building and testing](#building-and-testing)
- [Platforms](#platforms)
- [Documentation](#documentation)
- [License](#license)

</details>

---

## Features

<details open>
<summary>What the image does</summary>

- qBittorrent and libtorrent built from source on Alpine Linux for every release, the qBittorrent tarball checked against its OpenPGP signature
- A new image published automatically when qBittorrent or libtorrent releases, and rebuilt weekly for Alpine security fixes
- OpenVPN 2.7 and WireGuard, with a userspace WireGuard fallback for kernels without the module
- A fail-closed IPv4 and IPv6 firewall that pins each VPN server to its resolved address ([how it works](https://markusmcnugen.github.io/docker-qBittorrentvpn/docs/explanation/the-kill-switch/))
- DNS only through the tunnel, with Docker's own resolver blocked
- qBittorrent bound to the tunnel interface and run as PUID:PGID with no Linux capabilities; OpenVPN runs as its own user with only `CAP_NET_ADMIN`
- The tunnel recovers in place while qBittorrent keeps running; a tunnel down longer than `VPN_RECOVERY_TIMEOUT` restarts the container
- Port forwarding for ProtonVPN and other NAT-PMP providers, Private Internet Access, and fixed ports ([setup](https://markusmcnugen.github.io/docker-qBittorrentvpn/docs/how-to/forward-a-port/))
- An optional Privoxy HTTP proxy whose traffic uses only the tunnel ([settings](https://markusmcnugen.github.io/docker-qBittorrentvpn/docs/how-to/use-privoxy/))
- Other containers, such as a Soulseek client, can share the tunnel and its kill switch ([example](https://markusmcnugen.github.io/docker-qBittorrentvpn/docs/how-to/run-other-containers-through-the-tunnel/))
- WebUI username and password from environment variables or Docker secrets
- Any qBittorrent setting from an environment variable through `QBT_CONF_*`
- Existing 1.x setups keep working: same folders, same variables

</details>

## Quick start

Put your provider's OpenVPN file in `./config/openvpn/` (or its WireGuard file in `./config/wireguard/`), then:

```yaml
services:
  qbittorrentvpn:
    image: markusmcnugen/qbittorrentvpn:latest
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun
    environment:
      LAN_NETWORK: 192.168.1.0/24
      VPN_USERNAME: your-vpn-username
      VPN_PASSWORD: your-vpn-password
      PUID: "99"
      PGID: "100"
    volumes:
      - ./config:/config
      - ./downloads:/downloads
    ports:
      - 8080:8080
    restart: unless-stopped
    stop_grace_period: 150s
```

```bash
docker compose up -d
docker logs -f qbittorrentvpn
```

Open `http://<host>:8080`. Without `WEBUI_PASSWORD`, qBittorrent prints a temporary password in the log on first start; set your own under Options, WebUI.

Check that traffic leaves through the VPN:

```bash
docker exec qbittorrentvpn qbtvpn-status
```

The [commands page](https://markusmcnugen.github.io/docker-qBittorrentvpn/docs/reference/commands/) shows what each section means, with example output.

WireGuard users drop `VPN_USERNAME` and `VPN_PASSWORD`. `LAN_NETWORK` is the network your browser is on; without it the WebUI is reachable only from the Docker network.

## Why this image

A VPN container is only as good as what happens when the VPN is not there. Here the firewall comes first: it is loaded before any VPN process starts, it allows traffic out only through the tunnel and to the exact address and port of each VPN server, and it never opens again. If the tunnel drops, packets are refused, not rerouted. Every rule set is loaded in one atomic step, so there is no moment with half a firewall.

Building from source keeps qBittorrent current. Upstream publishes no Linux headless binaries, and distribution packages lag. Each build resolves the newest stable qBittorrent and libtorrent releases, verifies the downloads, and links against Alpine's maintained Qt, Boost and OpenSSL. libtorrent 2.1 is the default. Its disk backend uses `pread` and `pwrite` rather than memory-mapped files, which is faster on spinning disks, network mounts and FUSE shares such as Unraid's.

## How the kill switch works

Start-up runs in a fixed order:

1. The firewall drops everything except loopback and the DNS lookups needed to find the VPN server.
2. VPN server names are resolved once and pinned. OpenVPN and WireGuard are given addresses, never names, so a reconnect needs no DNS outside the tunnel.
3. The final rules load: out through the tunnel, out to each pinned server address and port, in and out for your LAN and the Docker network, nothing else. IPv6 leaves only through the tunnel.
4. The VPN starts, then DNS is pointed at the VPN's servers. Lookups to any other server, including Docker's at 127.0.0.11, are dropped.
5. qBittorrent starts bound to the tunnel interface.

The end-to-end tests run this against real WireGuard and OpenVPN servers in containers. They record every packet the container sends on its network and fail on any packet that is not VPN transport or a WebUI or Privoxy reply. The full rule set, and how to check it yourself, are on the [kill switch page](https://markusmcnugen.github.io/docker-qBittorrentvpn/docs/explanation/the-kill-switch/).

## Configuration

The settings most setups touch. Every variable, with its default, is in the [configuration reference](https://markusmcnugen.github.io/docker-qBittorrentvpn/docs/reference/environment-variables/).

<details>
<summary>Common variables</summary>

| Variable | Default | Purpose |
|---|---|---|
| `VPN_ENABLED` | `yes` | `no` runs qBittorrent with no VPN and no firewall |
| `VPN_TYPE` | `auto` | `openvpn` or `wireguard`; `auto` picks by which config folder has a file |
| `VPN_USERNAME`, `VPN_PASSWORD` | none | OpenVPN credentials; `_FILE` variants read Docker secrets |
| `LAN_NETWORK` | none | Comma-separated networks allowed to reach the WebUI, such as `192.168.1.0/24` |
| `NAME_SERVERS` | from the VPN | DNS servers, used through the tunnel |
| `VPN_PORT_FORWARDING` | `auto` | `off`, `auto`, `protonvpn`, `natpmp` or `pia` |
| `VPN_RECOVERY_TIMEOUT` | `300` | Seconds the tunnel may stay down before the container exits; `0` never exits |
| `PUID`, `PGID` | `99`, `100` | User and group qBittorrent runs as |
| `UMASK` | `002` | Permissions for new files |
| `WEBUI_PORT` | `8080` | WebUI port; publish the same port |
| `INCOMING_PORT` | from qBittorrent | Listen port, for providers that forward a fixed port |
| `WEBUI_USERNAME`, `WEBUI_PASSWORD` | none | WebUI login, applied on every start |
| `QBT_CONF_<Section>__<Key>` | none | Any qBittorrent.conf setting, such as `QBT_CONF_BitTorrent__Session__MaxConnections=500` |
| `PRIVOXY_ENABLED` | `no` | `yes` starts Privoxy on port 8118 (`PRIVOXY_PORT`); publish that port too |

</details>

| Volume | Holds |
|---|---|
| `/config` | `openvpn/`, `wireguard/`, qBittorrent's profile in `qBittorrent/`, and your own Privoxy rules in `privoxy/` |
| `/downloads` | The default save path |

The container needs `NET_ADMIN` and `/dev/net/tun`. It refuses to start with host networking, where its firewall would replace the host's.

## Port forwarding

Incoming connections are what make torrents fast behind a VPN. With the default `VPN_PORT_FORWARDING=auto`, a Private Internet Access configuration uses PIA's port API, and for any other provider the container sends one NAT-PMP request, which ProtonVPN supports. A forwarded port is opened on the tunnel and set in qBittorrent while it runs. Providers that assign a fixed port in their dashboard need only `INCOMING_PORT`. Setup per provider is on the [port forwarding page](https://markusmcnugen.github.io/docker-qBittorrentvpn/docs/how-to/forward-a-port/).

## Upgrading from 1.x

Pull the new image and start it with the same volumes and variables. The OpenVPN file, `credentials.conf` and qBittorrent's settings are read where they were. Two things change: qBittorrent no longer runs as root when `PUID` and `PGID` are unset (it runs as 99:100), and the WebUI no longer ships the old default password. The [upgrade page](https://markusmcnugen.github.io/docker-qBittorrentvpn/docs/how-to/upgrade-from-1x/) lists every difference.

## Repository layout

| Path | Contents |
|---|---|
| `Dockerfile` | Source, build and runtime stages |
| `build/` | Version resolution, verified source download, the compile script |
| `keys/` | The OpenPGP key qBittorrent's tarballs are signed with |
| `rootfs/usr/local/bin/` | `qbtvpn-entrypoint`, `qbtvpn-healthcheck`, `qbtvpn-status` |
| `rootfs/usr/local/lib/qbtvpn/` | Firewall, network, DNS, OpenVPN, WireGuard, port forwarding, Privoxy and qBittorrent configuration |
| `tests/` | Unit tests, end-to-end leak tests and their test doubles |
| `wiki/` | The documentation site, built with Hugo and the Hextra theme |
| `docs/` | Pointers from the old documentation pages to the wiki |
| `.github/workflows/` | CI on every branch but `main`; scheduled publishing and the wiki's deployment from `main` |

## Building and testing

```bash
docker buildx build --build-arg "$(bash build/resolve-qt.sh)" -t qbittorrentvpn:dev .
bash tests/run.sh unit qbittorrentvpn:dev
bash tests/run.sh e2e qbittorrentvpn:dev
```

Build arguments select versions: `QBITTORRENT_VERSION`, `LIBTORRENT_SERIES` (`2.1`, `2.0` or `1.2`), `LIBTORRENT_VERSION`, `QT_VERSION` (printed by `build/resolve-qt.sh`), and `INSTALL_PYTHON=no` for an image without the search plugins' Python. [Build and test](https://markusmcnugen.github.io/docker-qBittorrentvpn/docs/how-to/build-and-test/) covers them and the tests.

## Platforms

Published for `linux/amd64` and `linux/arm64`. Any Docker or Podman host whose kernel has iptables or nftables works; WireGuard uses the kernel module when present and `wireguard-go` otherwise.

## Documentation

The [wiki](https://markusmcnugen.github.io/docker-qBittorrentvpn/) holds a getting-started tutorial; how-to guides for OpenVPN, WireGuard, the WebUI, port forwarding, Privoxy, other containers, settings, secrets, Unraid, upgrades, building and troubleshooting; the kill switch and the security model explained; and a reference of every environment variable, command, file, log message, build argument and test.

## License

GPL-3.0-only. See [LICENSE](https://github.com/MarkusMcNugen/docker-qBittorrentvpn/blob/main/LICENSE).
