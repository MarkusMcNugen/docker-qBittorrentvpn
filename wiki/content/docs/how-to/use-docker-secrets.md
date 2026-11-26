---
title: Use Docker secrets
weight: 8
---

Environment variables show up in `docker inspect` and in Compose files. The four credential variables can name a file instead, which Docker secrets mount under `/run/secrets`:

| Variable | File form |
|---|---|
| `VPN_USERNAME` | `VPN_USERNAME_FILE` |
| `VPN_PASSWORD` | `VPN_PASSWORD_FILE` |
| `WEBUI_USERNAME` | `WEBUI_USERNAME_FILE` |
| `WEBUI_PASSWORD` | `WEBUI_PASSWORD_FILE` |

The file's contents are used, with trailing newlines removed. Setting both forms of one variable stops the container with `set VPN_PASSWORD or VPN_PASSWORD_FILE, not both`, and a file it cannot read stops it with the file's name.

```yaml
services:
  qbittorrentvpn:
    image: markusmcnugen/qbittorrentvpn:latest
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun
    environment:
      LAN_NETWORK: 192.168.1.0/24
      VPN_USERNAME_FILE: /run/secrets/vpn_username
      VPN_PASSWORD_FILE: /run/secrets/vpn_password
      WEBUI_PASSWORD_FILE: /run/secrets/webui_password
    secrets:
      - vpn_username
      - vpn_password
      - webui_password
    volumes:
      - ./config:/config
      - ./downloads:/downloads
    ports:
      - 8080:8080
    restart: unless-stopped
    stop_grace_period: 150s

secrets:
  vpn_username:
    file: ./secrets/vpn_username
  vpn_password:
    file: ./secrets/vpn_password
  webui_password:
    file: ./secrets/webui_password
```

Inside the container, OpenVPN gets the credentials from a file only its own user can read, and the WebUI password is stored only as qBittorrent's PBKDF2 hash. The log says `VPN credentials: provided` or `WebUI credentials: provided`, never the values.
