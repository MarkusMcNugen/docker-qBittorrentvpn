---
title: Change qBittorrent settings
weight: 7
---

Most settings are best changed in the WebUI, under Options; qBittorrent keeps them in `/config/qBittorrent/config/qBittorrent.conf`. A few come from the environment instead, applied at every start, so a container recreated from the same Compose file always gets them.

## The WebUI login and ports

| Variable | Sets |
|---|---|
| `WEBUI_USERNAME`, `WEBUI_PASSWORD` | The WebUI login. The password is stored as qBittorrent's own PBKDF2 hash |
| `WEBUI_PORT` | The WebUI's port, and the one the firewall opens |
| `INCOMING_PORT` | qBittorrent's listen port, for providers that forward a fixed port; with port forwarding, the forwarded port is used instead |
| `WEBUI_CSRF_PROTECTION` | The WebUI's CSRF protection; unset leaves qBittorrent's setting alone |

## Any other setting

`QBT_CONF_<Section>__<Key>` sets one key of qBittorrent.conf. `<Section>` is the part in brackets, and each `__` after it stands for a `\` in the key:

| Variable | Sets in qBittorrent.conf |
|---|---|
| `QBT_CONF_BitTorrent__Session__MaxConnections=500` | `[BitTorrent]` `Session\MaxConnections=500` |
| `QBT_CONF_BitTorrent__Session__GlobalMaxRatio=2` | `[BitTorrent]` `Session\GlobalMaxRatio=2` |
| `QBT_CONF_WebUI__HostHeaderValidation=false` | `[WebUI]` `HostHeaderValidation=false` |

Section and key names are case-sensitive, as qBittorrent writes them; set the option once in the WebUI and copy its line from qBittorrent.conf to find the exact name. qBittorrent 5.3 keeps the WebUI's settings in a `[WebUI]` section; earlier releases kept them under `[Preferences]`, as `WebUI\<key>`. Each value set is logged at start:

```text
2026-11-26 08:03:51 [info] qbittorrent: [BitTorrent] Session\MaxConnections set from QBT_CONF_BitTorrent__Session__MaxConnections
```

That line comes from the end-to-end tests. A value given this way replaces whatever the WebUI saved, at every start.

## What the container manages

Some settings are the container's to set, and a `QBT_CONF_` variable for one of them is ignored with a warning naming it:

- The network interface qBittorrent binds to: the tunnel, `tun0` or `wg0`.
- qBittorrent's own UPnP and NAT-PMP, which stay off: the container does the port forwarding.
- The listen port, when the VPN forwards one or `INCOMING_PORT` is set.
- The WebUI's port, its login when `WEBUI_USERNAME` or `WEBUI_PASSWORD` is set, its CSRF protection when `WEBUI_CSRF_PROTECTION` is set, and the WebAPI key the container uses to change the listen port while qBittorrent runs.
- The legal notice, which is accepted.

On a new install the container also writes defaults you can change afterwards: downloads to `/downloads`, incomplete files to `/downloads/temp`, listen port 8999, and the WebUI's CSRF, host header and clickjacking protections on. A `QBT_CONF_` value for one of these wins over the default.
