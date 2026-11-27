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

## Rootless Docker and Podman

Rootless Docker, rootless Podman and a Docker daemon with `userns-remap` run the container in a user namespace, where the container's root is your own user on the host. OpenVPN and WireGuard both work there, with three differences:

- `/dev/net/tun` belongs to a host user the container does not map, so the container cannot give it to the vpn group. It uses the device as it is when the vpn user can open it, which the usual host mode `0666` allows, and logs `vpn: /dev/net/tun belongs to nobody:nobody outside this container's user namespace`. Where the host's device is not `0666`, start-up stops with `the vpn user cannot open /dev/net/tun`; run `chmod 0666 /dev/net/tun` on the host.
- OpenVPN runs without the kernel's data channel offload, which accepts peers only from a process privileged in the host's user namespace; the log says `openvpn: in a user namespace, so data channel offload is off`. The tun device carries the tunnel instead, as on kernels without the offload.
- Your files appear inside the container as root's. Set `PUID=0` and `PGID=0`, so qBittorrent writes as your user on the host, still with no capabilities. Any other id is one of your subordinate ids from `/etc/subuid` on the host, and cannot write folders you own.

With `PUID=0` the firewall cannot tell qBittorrent's connections from the container's own by user, so the rule that refuses qBittorrent the VPN servers' addresses is left out. The kill switch and qBittorrent's binding to the tunnel interface stay.

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

Published for `linux/amd64` and `linux/arm64`. Any Docker or Podman host whose kernel has iptables or nftables works, rootless included. WireGuard uses the kernel module when it is present and `wireguard-go` otherwise.
