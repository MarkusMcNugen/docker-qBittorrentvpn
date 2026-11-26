---
title: Logs
weight: 5
---

Everything the container does is in `docker logs`. What a failing line means, and what to do about it, is in [Troubleshoot](../../how-to/troubleshoot/).

## Format

Three kinds of lines share the log:

| Written by | Format |
|---|---|
| The container's scripts | `<date> <time> [<level>] <component>: <message>`. The level is `info`, `warn`, `error`, or `debug` with `DEBUG=yes` |
| OpenVPN | `<date> <time> <message>`, OpenVPN's own; its warnings contain `WARNING` |
| qBittorrent | Its own lines, without a timestamp, such as the WebUI notice at start and `Catching signal: SIGTERM` at stop |

Privoxy's lines are passed on as the scripts' own, prefixed `privoxy:`: its `Error:` and `Fatal error:` lines at level `error`, the rest at `info`.

## A start

From the end-to-end tests over WireGuard, with `PRIVOXY_ENABLED=yes` and `PRIVOXY_CONF_DEBUG` set:

```text
2026-11-26 08:40:28 [info] qbittorrentvpn starting: QBITTORRENT_VERSION=5.3.1 LIBTORRENT_VERSION=2.1.3 LIBTORRENT_SERIES=2.1 LIBTORRENT_CXX_STANDARD=20 QT_VERSION=6.11.1 
2026-11-26 08:40:28 [info] VPN_ENABLED=yes VPN_TYPE=auto VPN_CONFIG=<auto>
2026-11-26 08:40:28 [info] LAN_NETWORK=172.31.250.0/24 NAME_SERVERS=<from VPN> VPN_DNS_FALLBACK=1.1.1.1 9.9.9.9
2026-11-26 08:40:28 [info] VPN_PORT_FORWARDING=natpmp VPN_RECOVERY_TIMEOUT=45s VPN_BLOCK_DOCKER_DNS=yes FIREWALL_BACKEND=auto
2026-11-26 08:40:28 [info] PUID=99 PGID=100 UMASK=002 WEBUI_PORT=8080 INCOMING_PORT=<from qBittorrent.conf>
2026-11-26 08:40:28 [info] PRIVOXY_ENABLED=yes PRIVOXY_PORT=8118 PRIVOXY_CONF_ options: debug
2026-11-26 08:40:28 [info] WebUI credentials: provided
2026-11-26 08:40:28 [info] qbittorrent: qbittorrent-nox 5.3.1
2026-11-26 08:40:28 [info] network: default route via 172.31.250.1 dev eth0, address 172.31.250.10
2026-11-26 08:40:28 [info] network: local subnets eth0 172.31.250.0/24; resolvers 127.0.0.11
2026-11-26 08:40:28 [info] firewall: iptables-nft backend, IPv6 filtering yes
2026-11-26 08:40:28 [info] firewall: lockdown in place; nothing but bootstrap DNS leaves the container
2026-11-26 08:40:28 [info] vpn: using wireguard (VPN_TYPE=auto)
2026-11-26 08:40:28 [info] wireguard: configuration /config/wireguard/wg0.conf
2026-11-26 08:40:28 [info] wireguard: endpoint qbtvpn-e2e-wg:51820 -> 172.31.250.2
2026-11-26 08:40:28 [info] route: LAN 172.31.250.0/24 is directly connected
2026-11-26 08:40:28 [info] firewall: kill switch active on wg0; 1 endpoint(s) pinned
2026-11-26 08:40:28 [info] wireguard: using the kernel module
2026-11-26 08:40:28 [info] wireguard: wg0 up, mtu 1420, addresses 10.13.0.2/32
2026-11-26 08:40:28 [info] wireguard: handshake complete
2026-11-26 08:40:28 [info] dns: using 10.13.0.1 from the VPN provider
2026-11-26 08:40:28 [info] port forwarding: natpmp loop started (pid 321)
2026-11-26 08:40:28 [info] nat-pmp: forwarded port 40123 from 10.13.0.1
2026-11-26 08:40:29 [info] firewall: tunnel accepts inbound on port(s) 40123
2026-11-26 08:40:29 [info] qbittorrent: gave 3 file(s) under /config/qBittorrent to 99:100
2026-11-26 08:40:29 [info] qbittorrent: creating /config/qBittorrent/config/qBittorrent.conf
2026-11-26 08:40:30 [info] qbittorrent: WebUI password set from WEBUI_PASSWORD
2026-11-26 08:40:30 [info] qbittorrent: generated a WebUI API key so forwarded-port changes apply without a restart (WebUI > Options > WebUI shows it)
2026-11-26 08:40:30 [info] qbittorrent: [BitTorrent] Session\MaxConnections set from QBT_CONF_BitTorrent__Session__MaxConnections
2026-11-26 08:40:30 [info] qbittorrent: listen port 40123, WebUI port 8080
2026-11-26 08:40:30 [info] qbittorrent: started as 99:100 with no capabilities (pid 409)
2026-11-26 08:40:30 [info] privoxy: Info: Privoxy version 4.0.0
2026-11-26 08:40:30 [info] privoxy: Info: Program name: privoxy
2026-11-26 08:40:30 [info] privoxy: started as user privoxy with no capabilities on port 8118 (pid 412)
2026-11-26 08:40:30 [info] privoxy: Connect: Initialized 100 socket slots.
2026-11-26 08:40:30 [info] privoxy: Connect: Waiting for the next client connection. Currently active threads: 0
WebUI will be started shortly after internal preparations. Please wait...

******** Information ********
To control qBittorrent, access the WebUI at: http://localhost:8080
```

The lines follow the start-up order: the settings in effect, without secrets; the network the container found; the lockdown; the VPN's configuration and its pinned servers; the final kill switch; the tunnel; DNS; port forwarding; qBittorrent's settings and start; Privoxy. The WebUI notice is qBittorrent's own; it names `localhost`, but the WebUI is reached at the Docker host's address.

## Privoxy's refusals

With `debug 2`, Privoxy logs each connection, so its refusals show. These come from the same run, where the tests ask Privoxy for a web server on the LAN and for the WebUI on loopback:

```text
2026-11-26 08:40:46 [info] privoxy: Request: 172.31.250.20/cgi-bin/ip
2026-11-26 08:40:46 [info] privoxy: Connect: to 172.31.250.20
2026-11-26 08:40:46 [info] privoxy: Connect: Could not connect to [172.31.250.20]:80: Host is unreachable.
2026-11-26 08:40:47 [info] privoxy: Request: 127.0.0.1:8080/
2026-11-26 08:40:47 [info] privoxy: Connect: to 127.0.0.1:8080
2026-11-26 08:40:47 [info] privoxy: Connect: Could not connect to [127.0.0.1]:8080: Host is unreachable.
```

## Recovery and shutdown

When the tunnel goes, the container logs the repair and the recovery; when it stays down past `VPN_RECOVERY_TIMEOUT`, the shutdown, in order. From the same run, after the tests delete `wg0` and later stop the server:

```text
2026-11-26 08:41:06 [warn] vpn: wg0 is gone; recreating it
2026-11-26 08:41:06 [info] wireguard: wg0 removed
2026-11-26 08:41:06 [info] wireguard: using the kernel module
2026-11-26 08:41:06 [info] wireguard: wg0 up, mtu 1420, addresses 10.13.0.2/32
2026-11-26 08:41:06 [warn] vpn: tunnel down (wg0 is gone; recreating it); traffic stays blocked while it recovers
2026-11-26 08:41:09 [info] vpn: recovered after 3 s (wireguard handshake age 3)
2026-11-26 08:41:43 [warn] nat-pmp: no mapping from 10.13.0.1 (natpmpc exited with status 143); retrying every 10 s, logged again only when the reason changes
2026-11-26 08:44:29 [warn] vpn: tunnel down (wireguard handshake age 183); traffic stays blocked while it recovers
2026-11-26 08:45:15 [error] vpn: down for 46 s, past VPN_RECOVERY_TIMEOUT=45; stopping so the restart policy starts afresh
2026-11-26 08:45:15 [info] privoxy: stopped
2026-11-26 08:45:15 [info] qbittorrent: stopping (up to 120 s to save resume data)
Catching signal: SIGTERM
Exiting cleanly
2026-11-26 08:45:16 [info] qbittorrent: stopped
2026-11-26 08:45:16 [info] wireguard: wg0 removed
2026-11-26 08:45:16 [info] shut down with status 1
```

`natpmpc exited with status 143` means the 15-second limit on each NAT-PMP request ended it, which is what happens while the server does not answer. Each NAT-PMP reason is logged once, and again only when it changes. `docker stop` runs the same sequence, starting with `[info] received SIGTERM; shutting down` instead of the `vpn:` lines and ending with `shut down with status 0`.

## Components

| Component | What it reports |
|---|---|
| `network` | The container's route, address, local subnets and resolvers, found before the VPN changes them |
| `firewall` | The iptables backend, the lockdown, the final kill switch and the ports open on the tunnel |
| `vpn` | Which VPN runs, the tunnel going down, recovering, and the container giving up |
| `openvpn`, `openvpn config` | The configuration used, each pinned server, every change made to the private copy, the connection |
| `wireguard` | The configuration, the endpoint, the kernel module or `wireguard-go`, the interface and the handshake |
| `route` | Return routes for `LAN_NETWORK` |
| `dns` | Which servers `/etc/resolv.conf` names, and where they came from |
| `port forwarding`, `nat-pmp`, `pia` | The forwarding loop, each forwarded port, and each failure's reason |
| `qbittorrent` | Ownership changes, the settings written, the ports, the start and the stop |
| `privoxy` | Privoxy's start, stop and restarts, and Privoxy's own lines |
