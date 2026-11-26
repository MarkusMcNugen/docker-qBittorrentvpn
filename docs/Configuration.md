# Configuration reference

Every environment variable the container reads. Booleans accept `yes`/`no`, `true`/`false`, `on`/`off` and `1`/`0`. A variable ending in `_FILE` names a file whose contents are used instead, for Docker secrets.

## VPN

| Variable | Default | Meaning |
|---|---|---|
| `VPN_ENABLED` | `yes` | `no` runs qBittorrent with no VPN and no firewall |
| `VPN_TYPE` | `auto` | `openvpn`, `wireguard`, or `auto`: the one whose folder in `/config` holds a configuration |
| `VPN_CONFIG` | first file | File name in `/config/openvpn` or `/config/wireguard`, or an absolute path |
| `VPN_CONFIG_RANDOM` | `no` | Pick a random configuration when the folder holds several |
| `VPN_USERNAME`, `VPN_PASSWORD` | none | OpenVPN username and password; also used for PIA port forwarding |
| `VPN_OPTIONS` | none | Extra OpenVPN command-line options, split on spaces |
| `VPN_CONNECT_TIMEOUT` | `120` | Seconds to wait for the first connection before exiting |
| `VPN_CHECK_INTERVAL` | `15` | Seconds between health checks |
| `VPN_RECOVERY_TIMEOUT` | `300` | Seconds the tunnel may stay down before the container exits; `0` never exits |
| `WIREGUARD_KEEPALIVE` | `25` | PersistentKeepalive for peers whose configuration sets none; `0` adds none |
| `WIREGUARD_HANDSHAKE_MAX_AGE` | `180` | Seconds since the last handshake after which WireGuard counts as down |
| `WIREGUARD_USERSPACE` | `auto` | `auto` uses `wireguard-go` only when the kernel module is missing; `yes` always, `no` never |

## Network and DNS

| Variable | Default | Meaning |
|---|---|---|
| `LAN_NETWORK` | none | Comma-separated IPv4 networks that may reach the WebUI and that traffic may go to outside the tunnel |
| `NAME_SERVERS` | from the VPN | Comma-separated DNS servers. Servers on a local network are allowed outside the tunnel, with a warning |
| `VPN_DNS_FALLBACK` | `1.1.1.1,9.9.9.9` | Used when neither `NAME_SERVERS` nor the VPN provides servers |
| `VPN_BLOCK_DOCKER_DNS` | `yes` | Block Docker's resolver at 127.0.0.11, which resolves outside the tunnel |
| `VPN_INPUT_PORTS` | none | Extra TCP ports accepted from local networks, for containers that share this one's network |
| `FIREWALL_BACKEND` | `auto` | `nft` or `legacy` iptables; `auto` follows the rules Docker already loaded |

## Port forwarding

| Variable | Default | Meaning |
|---|---|---|
| `VPN_PORT_FORWARDING` | `auto` | `off`, `auto`, `protonvpn`, `natpmp` or `pia`. `auto` uses `pia` for PIA configurations and otherwise tries one ProtonVPN-style NAT-PMP request |
| `VPN_PORT_FORWARDING_GATEWAY` | tunnel gateway | NAT-PMP gateway address |
| `VPN_PORT_FORWARDING_WAIT` | `30` | Seconds to wait for a forwarded port before starting qBittorrent |
| `NATPMP_RENEW_INTERVAL` | `45` | Seconds between NAT-PMP renewals |
| `NATPMP_LIFETIME` | `60` | Lifetime in seconds requested for each NAT-PMP mapping |
| `PIA_PF_HOSTNAME`, `PIA_PF_GATEWAY` | from OpenVPN | PIA server name and gateway; needed for PIA over WireGuard |
| `PIA_BIND_INTERVAL` | `900` | Seconds between PIA port renewals |

## qBittorrent

| Variable | Default | Meaning |
|---|---|---|
| `PUID`, `PGID` | `99`, `100` | User and group qBittorrent runs as; `root` means 0 |
| `UMASK` | `002` | Permissions mask for new files |
| `WEBUI_PORT` | `8080` | WebUI port; `WEBUI_PORT_ENV` is accepted too |
| `INCOMING_PORT` | from qBittorrent.conf | Listen port; `INCOMING_PORT_ENV` is accepted too |
| `WEBUI_USERNAME`, `WEBUI_PASSWORD` | none | WebUI login, applied on every start |
| `WEBUI_CSRF_PROTECTION` | unchanged | Sets the WebUI's CSRF protection on every start |
| `QBT_CONF_<Section>__<Key>` | none | Sets `[Section] Key` in qBittorrent.conf on every start; `__` separates path parts, so `QBT_CONF_BitTorrent__Session__MaxConnections=500` sets `Session\MaxConnections`. Settings the container manages (the tunnel binding, ports, credentials) cannot be overridden this way |
| `QBT_STOP_TIMEOUT` | `120` | Seconds qBittorrent gets to save its state on shutdown |
| `TZ` | UTC | Time zone for logs and qBittorrent |
| `DEBUG` | `no` | Trace every entrypoint command |

## Volumes and ports

| Path or port | Meaning |
|---|---|
| `/config/openvpn` | OpenVPN configuration; `.ovpn` or `.conf` |
| `/config/wireguard` | WireGuard configuration in wg-quick format |
| `/config/qBittorrent` | qBittorrent's profile: settings, resume data, logs |
| `/downloads` | Default save path, with incomplete files in `/downloads/temp` |
| `8080/tcp` | WebUI |

The container needs `--cap-add NET_ADMIN` and `--device /dev/net/tun`, and refuses host networking.
