---
title: Getting started
weight: 1
---

This walk-through starts the container with your VPN provider's OpenVPN configuration, checks that its traffic leaves only through the tunnel, and logs in to qBittorrent's WebUI. It takes about ten minutes. You need a Docker host with Docker Compose, a VPN subscription, and the address range of your home network, such as `192.168.1.0/24`.

## 1. Make a folder for it

```bash
mkdir -p qbittorrentvpn/config/openvpn qbittorrentvpn/downloads
cd qbittorrentvpn
```

## 2. Add your VPN configuration

Download an OpenVPN configuration from your provider, a `.ovpn` file for one server, and copy it into `config/openvpn/`. Using WireGuard instead? Put its `.conf` file in `config/wireguard/` and leave out the two `VPN_` credentials below; see [Set up WireGuard](../../how-to/set-up-wireguard/).

## 3. Write the Compose file

Save this as `docker-compose.yml`, with your own network, credentials and WebUI password:

```yaml
services:
  qbittorrentvpn:
    image: markusmcnugen/qbittorrentvpn:latest
    container_name: qbittorrentvpn
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun
    environment:
      LAN_NETWORK: 192.168.1.0/24
      VPN_USERNAME: your-vpn-username
      VPN_PASSWORD: your-vpn-password
      WEBUI_USERNAME: admin
      WEBUI_PASSWORD: choose-a-password
      PUID: "99"
      PGID: "100"
      TZ: Etc/UTC
    volumes:
      - ./config:/config
      - ./downloads:/downloads
    ports:
      - 8080:8080
    restart: unless-stopped
    stop_grace_period: 150s
```

`LAN_NETWORK` is the network your browser is on; the WebUI accepts nothing else. `PUID` and `PGID` are the user and group qBittorrent writes downloads as. Every other setting is in the [environment variables](../../reference/environment-variables/).

## 4. Start it and read the log

```bash
docker compose up -d
docker logs -f qbittorrentvpn
```

The container closes its firewall, connects the VPN, opens the firewall only for the tunnel, and starts qBittorrent. These are the container's own lines from a start in the end-to-end tests (`docker logs qbittorrentvpn 2>&1 | grep -E '\[(info|warn|error)\]'` shows just those; OpenVPN's own lines sit between them):

```text
2026-11-26 08:45:24 [info] qbittorrentvpn starting: QBITTORRENT_VERSION=5.3.1 LIBTORRENT_VERSION=2.1.3 LIBTORRENT_SERIES=2.1 LIBTORRENT_CXX_STANDARD=20 QT_VERSION=6.11.1 
2026-11-26 08:45:24 [info] VPN_ENABLED=yes VPN_TYPE=auto VPN_CONFIG=<auto>
2026-11-26 08:45:24 [info] LAN_NETWORK=172.31.250.0/24 NAME_SERVERS=<from VPN> VPN_DNS_FALLBACK=1.1.1.1 9.9.9.9
2026-11-26 08:45:24 [info] VPN_PORT_FORWARDING=auto VPN_RECOVERY_TIMEOUT=0s VPN_BLOCK_DOCKER_DNS=yes FIREWALL_BACKEND=auto
2026-11-26 08:45:24 [info] PUID=99 PGID=100 UMASK=002 WEBUI_PORT=8080 INCOMING_PORT=<from qBittorrent.conf>
2026-11-26 08:45:24 [info] VPN credentials: provided
2026-11-26 08:45:24 [info] WebUI credentials: provided
2026-11-26 08:45:24 [info] qbittorrent: qbittorrent-nox 5.3.1
2026-11-26 08:45:24 [info] network: default route via 172.31.250.1 dev eth0, address 172.31.250.10
2026-11-26 08:45:24 [info] network: local subnets eth0 172.31.250.0/24; resolvers 127.0.0.11
2026-11-26 08:45:24 [info] firewall: iptables-nft backend, IPv6 filtering yes
2026-11-26 08:45:25 [info] firewall: lockdown in place; nothing but bootstrap DNS leaves the container
2026-11-26 08:45:25 [info] vpn: using openvpn (VPN_TYPE=auto)
2026-11-26 08:45:25 [info] openvpn: configuration /config/openvpn/provider.ovpn
2026-11-26 08:45:25 [info] openvpn: remote qbtvpn-e2e-ovpn 1194/udp -> 172.31.250.3 
2026-11-26 08:45:25 [info] openvpn config: removed 'dev' (managed by the container)
2026-11-26 08:45:25 [info] openvpn config: remote lines pinned to 1 resolved address(es)
2026-11-26 08:45:25 [info] openvpn config: removed 'persist-key' (OpenVPN 2.7 always keeps keys across restarts)
2026-11-26 08:45:25 [info] openvpn config: auth-user-pass replaced by VPN_USERNAME and VPN_PASSWORD
2026-11-26 08:45:25 [info] route: LAN 172.31.250.0/24 is directly connected
2026-11-26 08:45:25 [info] firewall: kill switch active on tun0; 1 endpoint(s) pinned
2026-11-26 08:45:25 [info] openvpn: started as user vpn (pid 256)
2026-11-26 08:45:26 [info] openvpn: connected, tunnel address 10.14.0.2, gateway 10.14.0.1
2026-11-26 08:45:26 [info] openvpn: IPv6 ::/3 2000::/4 3000::/4 fc00::/7 routed into tun0
2026-11-26 08:45:26 [info] dns: using 10.14.0.1 from the VPN provider
2026-11-26 08:45:26 [info] port forwarding: protonvpn loop started (pid 346)
2026-11-26 08:45:26 [info] nat-pmp: forwarded port 40123 from 10.14.0.1
2026-11-26 08:45:27 [info] firewall: tunnel accepts inbound on port(s) 40123
2026-11-26 08:45:27 [info] qbittorrent: gave 3 file(s) under /config/qBittorrent to 99:100
2026-11-26 08:45:27 [info] qbittorrent: creating /config/qBittorrent/config/qBittorrent.conf
2026-11-26 08:45:27 [info] qbittorrent: WebUI password set from WEBUI_PASSWORD
2026-11-26 08:45:27 [info] qbittorrent: generated a WebUI API key so forwarded-port changes apply without a restart (WebUI > Options > WebUI shows it)
2026-11-26 08:45:27 [info] qbittorrent: [BitTorrent] Session\MaxConnections set from QBT_CONF_BitTorrent__Session__MaxConnections
2026-11-26 08:45:27 [info] qbittorrent: listen port 40123, WebUI port 8080
2026-11-26 08:45:27 [info] qbittorrent: started as 99:100 with no capabilities (pid 437)
```

Yours will name your own network, server and file. When the VPN does not connect, the line that stops the container says why; [Troubleshoot](../../how-to/troubleshoot/) explains each.

## 5. Check the tunnel

```bash
docker exec qbittorrentvpn qbtvpn-status
```

The output, from the same test run, shows the health record, the tunnel and its server, DNS through the tunnel, a forwarded port, and every firewall chain dropping by default. On your host, the public address section shows your VPN's address; the test network has no internet, so here it reads `unreachable`.

```text
== health
ok 1795682739 openvpn CONNECTED

== build
QBITTORRENT_VERSION=5.3.1
LIBTORRENT_VERSION=2.1.3
LIBTORRENT_SERIES=2.1
LIBTORRENT_CXX_STANDARD=20
QT_VERSION=6.11.1

== tunnel
tun0 inet 10.14.0.2/24
tun0 inet6 fd00:14::1000/64
tun0 inet6 fe80::4c91:6f29:edb2:bd41/64
openvpn: CONNECTED 10.14.0.2 server 172.31.250.3

== public address through the tunnel
curl: (6) Could not resolve host: api.ipify.org (Timeout while contacting DNS servers)
unreachable

== dns
nameserver 10.14.0.1

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

== qbittorrent
qBittorrent v5.3.1
Session\Interface=tun0
Session\InterfaceName=tun0
Session\Port=40123
```

Each section is explained in [Commands](../../reference/commands/#qbtvpn-status). No forwarded port? Your provider may need setting up for it; see [Forward a port](../../how-to/forward-a-port/).

## 6. Try to get around the tunnel

Ask the container to reach the internet outside the tunnel, through its own network interface:

```bash
docker exec qbittorrentvpn sh -c 'curl -s --interface eth0 --max-time 5 https://example.com || echo blocked'
```

It prints `blocked`: the firewall refuses everything that does not go through the tunnel, and keeps refusing it while the VPN reconnects. [The kill switch](../../explanation/the-kill-switch/) explains how.

## 7. Log in to the WebUI

Open `http://<docker host>:8080` from a machine on `LAN_NETWORK` and log in with `WEBUI_USERNAME` and `WEBUI_PASSWORD`. Downloads land in `./downloads`, with incomplete files in `./downloads/temp`.

## Next

- [Reach the WebUI](../../how-to/reach-the-webui/) from other networks or through a reverse proxy.
- [Forward a port](../../how-to/forward-a-port/) so peers can connect to you.
- [Change qBittorrent settings](../../how-to/change-qbittorrent-settings/) from the environment.
- [When the tunnel drops](../../explanation/when-the-tunnel-drops/): what the container does on its own.
