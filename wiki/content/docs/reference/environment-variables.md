---
title: Environment variables
weight: 1
---

Every variable the container reads, from `rootfs/usr/local/lib/qbtvpn/config.sh`. A value that does not fit stops the container at start with a message naming the variable.

Booleans accept `yes`/`no`, `true`/`false`, `on`/`off`, `enable`/`disable` and `1`/`0`, in any case. A variable marked "secret" can be given as `NAME_FILE` instead, naming a file whose contents are used, for [Docker secrets](../../how-to/use-docker-secrets/); setting both is an error.

## VPN

| Variable | Default | Accepts | Meaning |
|---|---|---|---|
| `VPN_ENABLED` | `yes` | boolean | `no` runs qBittorrent with no VPN and no firewall |
| `VPN_TYPE` | `auto` | `auto`, `openvpn`, `wireguard` | `auto` uses whichever of `/config/openvpn` and `/config/wireguard` holds a configuration, and stops when both do |
| `VPN_CONFIG` | the first file | file name or absolute path | The configuration to use, a name in `/config/openvpn` or `/config/wireguard` or a full path |
| `VPN_CONFIG_RANDOM` | `no` | boolean | Pick a random configuration at every start when the folder holds several |
| `VPN_USERNAME`, `VPN_PASSWORD` | none | text, secret | OpenVPN username and password, set together; also used for PIA port forwarding |
| `VPN_OPTIONS` | none | OpenVPN options | Extra OpenVPN command-line options, split on spaces and added last |
| `VPN_CONNECT_TIMEOUT` | `120` | whole number, at least 1 | Seconds to wait for the first connection before the container exits |
| `VPN_CHECK_INTERVAL` | `15` | whole number, at least 1 | Seconds between the supervisor's checks |
| `VPN_RECOVERY_TIMEOUT` | `300` | whole number | Seconds the tunnel may stay down before the container exits; `0` never exits |
| `WIREGUARD_KEEPALIVE` | `25` | whole number | PersistentKeepalive for peers whose configuration sets none; `0` adds none |
| `WIREGUARD_HANDSHAKE_MAX_AGE` | `180` | whole number, at least 1 | Seconds since the last handshake after which WireGuard counts as down |
| `WIREGUARD_USERSPACE` | `auto` | `auto`, `yes`, `no` | `auto` uses `wireguard-go` only when the kernel has no WireGuard module |

## Network and DNS

| Variable | Default | Accepts | Meaning |
|---|---|---|---|
| `LAN_NETWORK` | none | comma-separated IPv4 networks in CIDR form | Networks that may reach the WebUI and that traffic may go to outside the tunnel. `0.0.0.0/0` is refused; a public range is allowed with a warning |
| `NAME_SERVERS` | from the VPN | comma-separated IPv4 or IPv6 addresses | DNS servers, used before the VPN's. A server on a local network is reached outside the tunnel, with a warning |
| `VPN_DNS_FALLBACK` | `1.1.1.1,9.9.9.9` | comma-separated addresses | Used when neither `NAME_SERVERS` nor the VPN gives servers |
| `VPN_BLOCK_DOCKER_DNS` | `yes` | boolean | Block Docker's resolver at 127.0.0.11, which resolves outside the tunnel |
| `VPN_INPUT_PORTS` | none | comma-separated ports | Extra TCP ports accepted from local networks, for containers that share this one's network |
| `FIREWALL_BACKEND` | `auto` | `auto`, `nft`, `legacy` | The iptables backend; `auto` follows the rules Docker already loaded |

## Port forwarding

| Variable | Default | Accepts | Meaning |
|---|---|---|---|
| `VPN_PORT_FORWARDING` | `auto` | `off`, `auto`, `natpmp`, `protonvpn`, `pia` | `auto` uses `pia` for PIA's OpenVPN files and otherwise tries one NAT-PMP request |
| `VPN_PORT_FORWARDING_GATEWAY` | the tunnel's gateway | IPv4 address | The NAT-PMP gateway |
| `VPN_PORT_FORWARDING_WAIT` | `30` | whole number | Seconds to wait for a forwarded port before qBittorrent starts |
| `NATPMP_RENEW_INTERVAL` | `45` | whole number, at least 1 | Seconds between NAT-PMP renewals |
| `NATPMP_LIFETIME` | `60` | whole number, at least 1 | Lifetime in seconds asked for each NAT-PMP mapping |
| `PIA_PF_HOSTNAME`, `PIA_PF_GATEWAY` | from OpenVPN | host name, IPv4 address | PIA's server name and tunnel gateway; needed for PIA over WireGuard |
| `PIA_BIND_INTERVAL` | `900` | whole number, at least 60 | Seconds between PIA port renewals |

## qBittorrent

| Variable | Default | Accepts | Meaning |
|---|---|---|---|
| `PUID`, `PGID` | `99`, `100` | whole number or `root` | User and group qBittorrent runs as. 873 belongs to the vpn user and is refused |
| `UMASK` | `002` | three octal digits | Permissions mask for new files |
| `WEBUI_PORT` | `8080` | port | WebUI port; `WEBUI_PORT_ENV` is read too |
| `INCOMING_PORT` | from qBittorrent.conf | port | qBittorrent's listen port; `INCOMING_PORT_ENV` is read too |
| `WEBUI_USERNAME`, `WEBUI_PASSWORD` | none | text, secret | WebUI login, applied on every start |
| `WEBUI_CSRF_PROTECTION` | unchanged | boolean | Sets the WebUI's CSRF protection on every start; new installs start with it on |
| `QBT_CONF_<Section>__<Key>` | none | text | Sets `[Section] Key` in qBittorrent.conf on every start; `__` separates the parts, so `QBT_CONF_BitTorrent__Session__MaxConnections=500` sets `Session\MaxConnections`. Settings the container manages (the tunnel binding, ports, credentials) cannot be set this way |
| `QBT_STOP_TIMEOUT` | `120` | whole number, at least 1 | Seconds qBittorrent gets to save its state when the container stops |
| `TZ` | UTC | time zone name | Time zone for the logs and qBittorrent |
| `DEBUG` | `no` | boolean | Trace every command the entrypoint runs, and log every NAT-PMP attempt in full |

## Privoxy

| Variable | Default | Accepts | Meaning |
|---|---|---|---|
| `PRIVOXY_ENABLED` | `no` | boolean | `yes` starts [Privoxy](../../how-to/use-privoxy/) once the VPN is up; it never starts with `VPN_ENABLED=no` |
| `PRIVOXY_PORT` | `8118` | port, not the WebUI's | Port Privoxy listens on |
| `PRIVOXY_CONF_<option>` | none | text, one line per value line | Adds a line to Privoxy's configuration, `<option>` lowercased with `_` read as `-`: `PRIVOXY_CONF_SOCKET_TIMEOUT=600` adds `socket-timeout 600`. Each line of a multi-line value adds a line, and the variables are added in byte order of their names. The listen address comes from `PRIVOXY_PORT` only |

While Privoxy is enabled, `PUID` and `PGID` cannot be 874, the id of its user.
