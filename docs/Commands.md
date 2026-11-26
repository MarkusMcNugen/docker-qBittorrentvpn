# Commands

Two commands in the image report what the container is doing. Run them with `docker exec`.

## qbtvpn-healthcheck

Prints one line, then exits with status 0 when the container is healthy and 1 when it is not. Docker's `HEALTHCHECK` runs it every 30 seconds.

| Line | Exit status | Meaning |
|---|---|---|
| `ok: <detail>` | 0 | The supervisor's last check passed: the tunnel is up and the WebUI responds |
| `unhealthy: <detail>` | 1 | The last check failed; the detail names the tunnel state, and adds `WebUI not responding on port <port>` when the WebUI did not respond |
| `stale: last record <seconds> s old (<status> <detail>)` | 1 | The supervisor has written no record for three `VPN_CHECK_INTERVAL`s plus 30 seconds |
| `starting: no health record yet` | 1 | The supervisor has not finished its first check |
| `stopped: ` | 1 | The container is shutting down |

The detail is `wireguard handshake age <seconds>` for WireGuard, `openvpn <state>` for OpenVPN (`CONNECTED`, `RECONNECTING`, `WAIT`, `AUTH` and the other states OpenVPN reports, `NOSOCKET` before OpenVPN opens its management socket, or `UNKNOWN` when the socket gives no reply), and `vpn disabled` with `VPN_ENABLED=no`.

These lines come from the end-to-end tests, over WireGuard and then OpenVPN:

```
$ docker exec qbittorrentvpn qbtvpn-healthcheck
ok: wireguard handshake age 5
$ docker exec qbittorrentvpn qbtvpn-healthcheck
ok: openvpn CONNECTED
```

## qbtvpn-status

Prints these sections, in this order:

| Section | Shows |
|---|---|
| `health` | The supervisor's last record: its status, the Unix time it was written, and its detail |
| `build` | The qBittorrent, libtorrent and Qt versions the image was built with |
| `tunnel` | The tunnel's addresses; for WireGuard the endpoint, last handshake and traffic; for OpenVPN its state, tunnel address and server |
| `public address through the tunnel` | The address the internet sees, from `https://api.ipify.org` through the tunnel, or `unreachable` |
| `dns` | The name servers in `/etc/resolv.conf` |
| `port forwarding` | The forwarded port, or `none` |
| `firewall` | Each chain's default policy and the ports open on the tunnel, for every iptables backend that holds the container's rules |
| `privoxy` | Only with `PRIVOXY_ENABLED=yes`: the port Privoxy listens on and its process, or why it did not start |
| `qbittorrent` | qBittorrent's version and its interface and listen port settings |

This output comes from the end-to-end tests over WireGuard, which run with `PRIVOXY_ENABLED=yes`. Their test network has no internet access, so the public address reads `unreachable`.

```
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

```
== tunnel
tun0 inet 10.14.0.2/24
tun0 inet6 fd00:14::1000/64
tun0 inet6 fe80::827b:ecb5:24:813b/64
openvpn: CONNECTED 10.14.0.2 server 172.31.250.3
```
