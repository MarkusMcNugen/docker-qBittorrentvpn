---
title: Run on Unraid
weight: 9
---

## Template settings

| Setting | Value |
|---|---|
| Repository | `markusmcnugen/qbittorrentvpn` |
| Network type | Bridge |
| Port 8080 TCP | `8080`, the WebUI |
| Port 8118 TCP | `8118`, only with `PRIVOXY_ENABLED=yes` |
| Path `/config` | `/mnt/user/appdata/qbittorrentvpn` |
| Path `/downloads` | your downloads share, such as `/mnt/user/downloads` |
| Variable `LAN_NETWORK` | your LAN, such as `192.168.1.0/24` |
| Variable `VPN_USERNAME`, `VPN_PASSWORD` | your provider's OpenVPN credentials; leave them out for WireGuard |
| Variable `PUID` | `99` |
| Variable `PGID` | `100` |

`PUID=99` and `PGID=100`, the image's defaults, are Unraid's `nobody:users`, so the downloads and the appdata folder can be read and changed over the network share.

## Extra parameters

Turn on the advanced view and set **Extra Parameters** to:

```text
--cap-add=NET_ADMIN --device=/dev/net/tun --stop-timeout=150
```

`--stop-timeout=150` gives qBittorrent time to save its resume data when the array stops. Leave **Privileged** off; the container does not need it.

## The VPN configuration

Put your provider's `.ovpn` file in `/mnt/user/appdata/qbittorrentvpn/openvpn/`, or its WireGuard `.conf` file in `/mnt/user/appdata/qbittorrentvpn/wireguard/`, then start the container. On its first start without one, the container creates both folders and stops, saying where the file goes. See [Set up OpenVPN](../set-up-openvpn/) and [Set up WireGuard](../set-up-wireguard/).

## Check it

Open the container's console from the Docker tab, or run from the Unraid terminal:

```bash
docker exec qbittorrentvpn qbtvpn-status
```
