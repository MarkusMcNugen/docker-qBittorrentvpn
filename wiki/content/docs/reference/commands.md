---
title: Commands
weight: 2
---

Two commands inside the container report what it is doing; run them with `docker exec`. Two scripts in the repository resolve the versions a build uses. The test runner has its own page, [Tests](../tests/).

## qbtvpn-healthcheck

```bash
docker exec qbittorrentvpn qbtvpn-healthcheck
```

Takes no arguments. Prints one line and exits with status 0 when the container is healthy and 1 when it is not. Docker's `HEALTHCHECK` runs it every 30 seconds.

| Line | Exit status | Meaning |
|---|---|---|
| `ok: <detail>` | 0 | The supervisor's last check passed: the tunnel is up, the WebUI responds, and Privoxy runs when it is enabled |
| `unhealthy: <detail>` | 1 | The last check failed. The detail names the tunnel's state, and adds `; WebUI not responding on port <port>` or `; Privoxy not running` when those failed |
| `stale: last record <seconds> s old (<status> <detail>)` | 1 | The supervisor has written no record for three `VPN_CHECK_INTERVAL`s plus 30 seconds |
| `starting: no health record yet` | 1 | The supervisor has not finished its first check |
| `stopped: ` | 1 | The container is shutting down |

`<detail>` is one of:

| Detail | Type | When |
|---|---|---|
| `wireguard handshake age <seconds>` | whole number of seconds since the last WireGuard handshake | WireGuard |
| `openvpn <state>` | OpenVPN's state name: `CONNECTED`, `RECONNECTING`, `WAIT`, `AUTH` and the others OpenVPN reports, `NOSOCKET` before OpenVPN opens its management socket, `UNKNOWN` when the socket gives no reply | OpenVPN |
| `vpn disabled` | fixed text | `VPN_ENABLED=no` |

From the end-to-end tests, over WireGuard and then OpenVPN:

```text
$ docker exec qbittorrentvpn qbtvpn-healthcheck
ok: wireguard handshake age 5
$ docker exec qbittorrentvpn qbtvpn-healthcheck
ok: openvpn CONNECTED
```

## qbtvpn-status

```bash
docker exec qbittorrentvpn qbtvpn-status
```

Takes no arguments. Prints these sections, each headed `== <name>`, in this order:

| Section | Lines |
|---|---|
| `health` | The supervisor's last record, `<status> <unix time> <detail>`: `status` is `ok`, `unhealthy` or `stopped`, the time is whole seconds since 1970, and `detail` is as for `qbtvpn-healthcheck`. `no health record` before the first check |
| `build` | `KEY=VALUE` lines: `QBITTORRENT_VERSION`, `LIBTORRENT_VERSION`, `LIBTORRENT_SERIES`, `LIBTORRENT_CXX_STANDARD`, `QT_VERSION` |
| `tunnel` | One `<interface> <family> <address>/<prefix>` line per address on `tun0`, `tap0` or `wg0`. For WireGuard, the `endpoint`, `latest handshake` and `transfer` lines of `wg show`. For OpenVPN, `openvpn: <state> <tunnel address> server <server address>` |
| `public address through the tunnel` | The address the internet sees, from `https://api.ipify.org` through the tunnel, or curl's error and `unreachable` |
| `dns` | The `nameserver <address>` lines of `/etc/resolv.conf` |
| `port forwarding` | `forwarded port <port>`, or `none` |
| `firewall` | For every iptables backend that holds the container's rules, its name and then each chain's policy (`-P <chain> DROP`) and the ports open on the tunnel (`-A QBTVPN_TUNNEL_IN ...`) |
| `privoxy` | Only with `PRIVOXY_ENABLED=yes`: `listening on port <port> (pid <pid>)`, `not running; it last ran as pid <pid> on port <port>`, or `not started: <reason>` |
| `qbittorrent` | `qBittorrent v<version>`, then the `Session\Interface`, `Session\InterfaceName` and `Session\Port` lines of qBittorrent.conf |

This output comes from the end-to-end tests over WireGuard, which run with `PRIVOXY_ENABLED=yes`. Their test network has no internet access, so the public address reads `unreachable`.

```text
$ docker exec qbittorrentvpn qbtvpn-status

== health
ok 1795674314 wireguard handshake age 22

== build
QBITTORRENT_VERSION=5.3.1
LIBTORRENT_VERSION=2.1.3
LIBTORRENT_SERIES=2.1
LIBTORRENT_CXX_STANDARD=20
QT_VERSION=6.11.1

== tunnel
wg0 inet 10.13.0.2/32
  endpoint: 172.31.250.2:51820
  latest handshake: 23 seconds ago
  transfer: 3.06 KiB received, 4.47 KiB sent

== public address through the tunnel
curl: (6) Could not resolve host: api.ipify.org (Timeout while contacting DNS servers)
unreachable

== dns
nameserver 10.13.0.1

== port forwarding
forwarded port 40123

== firewall
iptables-nft:
-P INPUT DROP
-P FORWARD DROP
-P OUTPUT DROP
-A QBTVPN_TUNNEL_IN -p tcp -m tcp --dport 40123 -j ACCEPT
-A QBTVPN_TUNNEL_IN -p udp -m udp --dport 40123 -j ACCEPT
ip6tables-nft:
-P INPUT DROP
-P FORWARD DROP
-P OUTPUT DROP
-A QBTVPN_TUNNEL_IN -p tcp -m tcp --dport 40123 -j ACCEPT
-A QBTVPN_TUNNEL_IN -p udp -m udp --dport 40123 -j ACCEPT

== privoxy
listening on port 8118 (pid 400)

== qbittorrent
qBittorrent v5.3.1
Session\Interface=wg0
Session\InterfaceName=wg0
Session\Port=40123
```

Over OpenVPN, with a test server that assigns IPv6 in the tunnel, the tunnel section reads:

```text
== tunnel
tun0 inet 10.14.0.2/24
tun0 inet6 fd00:14::1000/64
tun0 inet6 fe80::827b:ecb5:24:813b/64
openvpn: CONNECTED 10.14.0.2 server 172.31.250.3
```

## build/resolve-versions.sh

```bash
bash build/resolve-versions.sh
```

Resolves the qBittorrent and libtorrent releases a build uses, through the GitHub API, and prints two lines. It reads every page of each project's release list, so an older libtorrent series is found however many newer releases come first.

| Input variable | Default | Meaning |
|---|---|---|
| `QBITTORRENT_VERSION` | `latest` | `latest`, the newest stable release, or an exact `x.y.z` |
| `LIBTORRENT_SERIES` | `2.1` | `2.1`, `2.0` or `1.2` |
| `LIBTORRENT_VERSION` | `latest` | `latest`, the newest stable release of the series, or an exact `x.y.z` |
| `GITHUB_TOKEN` | none | Raises the API's rate limit |

| Output line | Type |
|---|---|
| `QBITTORRENT_VERSION=<version>` | release number, `x.y.z` |
| `LIBTORRENT_VERSION=<version>` | release number, `x.y.z` |

On a failure it prints `resolve-versions: <reason>` to standard error and exits with status 1. From the publish workflow:

```text
QBITTORRENT_VERSION=5.3.1
LIBTORRENT_VERSION=2.1.3
```

## build/resolve-qt.sh

```bash
bash build/resolve-qt.sh
```

Prints the `qt6-qtbase` version Alpine ships for the machine's architecture, read from the Alpine branch's package index, as one line for `--build-arg`. It pins the builder's Qt; see [Build arguments](../build-arguments/).

| Input variable | Default | Meaning |
|---|---|---|
| `ALPINE_VERSION` | the Dockerfile's `ALPINE_VERSION` | Alpine branch |
| `APK_ARCH` | from `uname -m` | Alpine architecture, such as `x86_64` or `aarch64` |

| Output line | Type |
|---|---|
| `QT_VERSION=<version>` | Alpine package version, `x.y.z-rN` |

From a build on an x86_64 host:

```text
QT_VERSION=6.11.1-r0
```
