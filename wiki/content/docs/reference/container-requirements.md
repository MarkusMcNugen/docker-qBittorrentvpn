---
title: Container requirements
weight: 4
---

What the container needs from Docker and the host, and what it refuses.

## Capabilities and devices

| Needed | Why | Without it |
|---|---|---|
| `--cap-add NET_ADMIN` | The firewall, the routes and the tunnel interface | Start-up stops: `no iptables backend works: run the container with --cap-add=NET_ADMIN ...` |
| `--device /dev/net/tun` | OpenVPN and `wireguard-go` open tunnel devices through it | The container creates the device node itself when Docker allows it, and otherwise stops: `/dev/net/tun is missing and cannot be created` |

`--privileged` is not needed and gives the container far more than it uses. Nothing else is required: no sysctls, and no `src_valid_mark`, since WireGuard's endpoints are routed through the container's own gateway instead of by firewall marks.

## Networks

- A bridge network, the Docker default, or macvlan. Directly connected subnets are allowed through the firewall like `LAN_NETWORK`.
- Host networking is refused: the container would replace the host's own firewall. Start-up stops when it sees an interface that belongs to the host, such as `docker0`, `veth*` or `br-*`.
- IPv6 may be on or off. With IPv6 off in the container, OpenVPN ignores the IPv6 address and routes a server pushes, and WireGuard skips IPv6 addresses, with a warning for each.

## Ports

| Port | Publish it | What |
|---|---|---|
| `8080/tcp` | yes | The WebUI, or `WEBUI_PORT` |
| `8118/tcp` | with `PRIVOXY_ENABLED=yes` | Privoxy, or `PRIVOXY_PORT` |
| `8999/tcp`, `8999/udp` | no | qBittorrent's default listen port. Peers reach it through the VPN, on a [forwarded port](../../how-to/forward-a-port/), never through a published one |

The firewall accepts the WebUI, Privoxy and `VPN_INPUT_PORTS` from `LAN_NETWORK` and the container's own networks only.

## Volumes

| Path | Holds |
|---|---|
| `/config` | VPN configurations, qBittorrent's profile and Privoxy's rules; see [Files](../files/) |
| `/downloads` | The default save path, with incomplete files in `/downloads/temp` |

qBittorrent must be able to write `/downloads` as `PUID:PGID`; the log warns at start when it cannot.

## Health check and stopping

The image's `HEALTHCHECK` runs [`qbtvpn-healthcheck`](../commands/#qbtvpn-healthcheck) every 30 seconds with a 10-second timeout, a 180-second start period and 3 retries.

On `docker stop`, qBittorrent gets `QBT_STOP_TIMEOUT` (120 seconds) to save its resume data before the VPN goes down. Give Docker longer than that: `stop_grace_period: 150s` in Compose, or `docker stop -t 150`. `tini` runs as process 1 and passes the signal on.

## Platforms

Published for `linux/amd64` and `linux/arm64`. Any Docker or Podman host whose kernel has iptables or nftables works. WireGuard uses the kernel module when it is present and `wireguard-go` otherwise.
