---
title: Files
weight: 3
---

What the container reads and writes. Everything you keep lives in the two volumes, `/config` and `/downloads`; `/run/qbtvpn` is cleared at every start.

## /config

| Path | The container | What |
|---|---|---|
| `/config/openvpn/*.ovpn`, `*.conf` | reads | OpenVPN configurations. A file counts only when it has a `remote` or `client` line. The first by name is used, unless `VPN_CONFIG` names one or `VPN_CONFIG_RANDOM=yes` |
| `/config/openvpn/credentials.conf` | reads | Username and password on two lines, for configurations with `auth-user-pass credentials.conf`, as 1.x used; `VPN_USERNAME` and `VPN_PASSWORD` replace it |
| `/config/openvpn/.pia-portforward.json` | writes | PIA's signed forwarded port, reused across restarts until PIA expires it |
| `/config/wireguard/*.conf` | reads | WireGuard configurations in wg-quick format |
| `/config/qBittorrent/config/qBittorrent.conf` | reads and writes | qBittorrent's settings. On every start the container writes the ones it manages and any `QBT_CONF_` values |
| `/config/qBittorrent/data/` | qBittorrent writes | Resume data, logs and search plugins |
| `/config/privoxy/user.action`, `user.filter` | reads | Your Privoxy rules, copied in at start when `PRIVOXY_ENABLED=yes` |

The container never edits your VPN configurations: it works on private copies under `/run/qbtvpn`, and logs each change it makes there. When neither folder holds a configuration, it creates both and stops with a message saying where to put the provider's file. `/config/qBittorrent` is given to `PUID:PGID` at start.

## /downloads

qBittorrent's default save path, with incomplete files in `/downloads/temp`. Settings in the WebUI can point elsewhere; mount those folders too.

## /run/qbtvpn

Runtime state, rebuilt at every start. Everything under `openvpn/` belongs to the vpn user and everything under `privoxy/` to the privoxy user; the rest belongs to root. Read it to see what the container decided; never edit it.

| Path | What |
|---|---|
| `state/health` | The supervisor's last record, which [`qbtvpn-healthcheck`](../commands/#qbtvpn-healthcheck) reads: `<status> <unix time> <detail>` |
| `state/vpn-dns` | The DNS servers the VPN gave, one per line |
| `state/openvpn-mgmt` | OpenVPN's last management interface reply, or why there was none |
| `state/privoxy` | `<port> <pid>` while Privoxy runs, or `not started: <reason>` |
| `openvpn/config/` | Private copy of `/config/openvpn` |
| `openvpn/client.conf` | The configuration OpenVPN runs: yours, with each server pinned to its address and the options the container manages removed |
| `openvpn/remotes` | The pinned `remote` lines |
| `openvpn/state/` | What OpenVPN's hook reported (tunnel gateway, DNS servers) and the management socket |
| `wireguard/` | The WireGuard configuration as `wg setconf` loads it, endpoints pinned to addresses |
| `firewall/lockdown.v4.rules`, `lockdown.v6.rules`, `final.v4.rules`, `final.v6.rules` | Each ruleset as the container loaded it |
| `firewall/tunnel-ports.rules` | The last change to the ports open on the tunnel |
| `pf/port` | The forwarded port, while there is one |
| `privoxy/` | Privoxy's configuration and private copies of your rules |
| `resolv.conf.orig` | `/etc/resolv.conf` as Docker wrote it, before the container pointed DNS at the tunnel |
| `qbittorrent.ops` | The settings start-up applied to qBittorrent.conf |
