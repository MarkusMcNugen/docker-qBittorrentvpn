---
title: Set up WireGuard
weight: 2
---

## Use your provider's file

Download a WireGuard configuration from your provider, in the wg-quick format most providers offer, and put it in `/config/wireguard` with a `.conf` name, such as `/config/wireguard/wg0.conf`. With files in both `/config/openvpn` and `/config/wireguard`, set `VPN_TYPE=wireguard`. With several WireGuard files, the first by name is used; `VPN_CONFIG` names another, and `VPN_CONFIG_RANDOM=yes` picks one at random at every start. No username or password is needed: the keys are in the file.

```ini
[Interface]
PrivateKey = <your private key>
Address = 10.2.0.2/32
DNS = 10.2.0.1

[Peer]
PublicKey = <the server's public key>
AllowedIPs = 0.0.0.0/0
Endpoint = server.example.com:51820
```

## What the container reads

| Key | What happens |
|---|---|
| `PrivateKey`, `ListenPort`, `FwMark` | Passed to WireGuard |
| `Address` | Set on `wg0`. IPv6 addresses are skipped, with a warning, when IPv6 is off in the container |
| `DNS` | Used as the tunnel's DNS servers unless `NAME_SERVERS` is set |
| `MTU` | Set on `wg0`; without it, the MTU of the interface toward the server, less 80 |
| `Table`, `SaveConfig` | Ignored: the container routes everything into the tunnel itself |
| `PreUp`, `PostUp`, `PreDown`, `PostDown` | Ignored, with a warning: shell commands from the file are not run |
| `PublicKey`, `PresharedKey`, `AllowedIPs` | Passed to WireGuard |
| `Endpoint` | Resolved once and pinned to its first IPv4 address. An IPv6 endpoint is refused: use the provider's IPv4 one |
| `PersistentKeepalive` | Passed to WireGuard; a peer without one gets `WIREGUARD_KEEPALIVE` (25) |

Any other key stops the container with `wireguard: unknown key`, so a typing error is caught at start. A peer that does not allow `0.0.0.0/0` is accepted with a warning: traffic for destinations it does not cover is dropped, never sent around the tunnel.

## Kernel module or wireguard-go

The container uses the kernel's WireGuard module when the host has it, and `wireguard-go`, which runs in userspace through `/dev/net/tun`, when it does not. `WIREGUARD_USERSPACE=yes` always uses `wireguard-go`; `no` never does, and the container stops when the kernel has no module. Either way, `wireguard-go` runs as the vpn user with only `CAP_NET_ADMIN`.

## Check it

```bash
docker exec qbittorrentvpn qbtvpn-status
```

The tunnel section shows `wg0`'s address, the pinned endpoint and the last handshake. The container counts the tunnel as down when the handshake is older than `WIREGUARD_HANDSHAKE_MAX_AGE` (180 seconds); see [When the tunnel drops](../../explanation/when-the-tunnel-drops/).
