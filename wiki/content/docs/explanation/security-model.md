---
title: Security model
weight: 3
---

What runs with which privileges, and what each layer protects against.

## Who runs what

| Process | User | Linux capabilities | Notes |
|---|---|---|---|
| `tini`, the entrypoint and its supervisor | root | the container's, including `NET_ADMIN` | Builds the firewall and routes, writes DNS, starts and stops everything else |
| OpenVPN and `wireguard-go` | `vpn` (873) | `CAP_NET_ADMIN` only, as an ambient capability, with `no_new_privs` | Read a private copy of the configuration under `/run/qbtvpn` |
| qBittorrent | `PUID:PGID`, 99:100 by default | none, with an empty bounding set and `no_new_privs` | Bound to the tunnel interface |
| Privoxy, when enabled | `privoxy` (874) | none, with an empty bounding set and `no_new_privs` | Its own connections are confined to the tunnel by an owner rule |

The ids 873 and 874 are fixed in the image, and `PUID`/`PGID` may not take them, so the firewall's owner rules can never match the wrong process.

## What each layer guards against

| Threat | Guard |
|---|---|
| Torrent traffic leaving outside the VPN when it drops, restarts or misbehaves | The [kill switch](../the-kill-switch/): `DROP` policies loaded before the VPN starts, never opened again, verified after each load |
| DNS revealing what you download | DNS only through the tunnel; Docker's resolver blocked; the VPN servers resolved once, before the final rules, so reconnects need no DNS |
| IPv6 bypassing an IPv4-only tunnel | IPv6 leaves only through the tunnel, and is removed altogether when `ip6tables` does not work |
| qBittorrent reaching the internet another way | Besides the firewall, qBittorrent is bound to the tunnel interface, and unless `PUID` is 0 its user is refused even the VPN servers' addresses |
| A local proxy becoming a way around the VPN | Privoxy's new connections may only enter the tunnel, so it cannot reach the LAN, the Docker networks or the WebUI on loopback |
| Someone else using the WebUI | It is reachable only from `LAN_NETWORK` and the container's networks; a password is required, set from `WEBUI_PASSWORD` or a temporary one in the log; CSRF protection is on for new installs |
| Peers reaching the container | The tunnel accepts inbound connections only on qBittorrent's listen port |
| Secrets in `docker inspect` | `_FILE` variants read passwords from Docker secrets; OpenVPN's credentials go to a file only the vpn user can read |
| A compromised OpenVPN | It runs as its own user with one capability and cannot gain more |

## What it does not guard against

- The VPN provider itself, which sees your traffic leave the tunnel.
- Trackers and peers, which see the VPN's address and what you share.
- Anything given `VPN_ENABLED=no`, which runs qBittorrent with no VPN and no firewall.
- Other containers joined with `network_mode: service:`: they share the firewall and the tunnel, but run with whatever privileges you give them.

## The image itself

Every release is compiled from source that is checked before the build uses it: the qBittorrent tarball against its maintainer's OpenPGP signature, both tarballs against GitHub's SHA-256 digests. Published images carry build provenance and an SBOM, and an attestation that GitHub signs. The workflows pin every action by commit. See [How the image stays current](../how-the-image-stays-current/).
