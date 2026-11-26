# Other containers through the tunnel

A container started with `network_mode: service:qbittorrentvpn` joins this container's network. Its internet traffic then leaves only through the tunnel, its lookups go to the tunnel's DNS servers, and the kill switch blocks it whenever the tunnel is down. Nothing in the other container needs to know about the VPN.

Four things change for the joined container:

- Its ports are published on the `qbittorrentvpn` service, and `VPN_INPUT_PORTS` must list them so the firewall accepts them from `LAN_NETWORK` and the Docker network.
- The tunnel accepts inbound connections only on qBittorrent's listen port, so the joined container gets none from the internet.
- Names of other containers do not resolve, because Docker's resolver is blocked while `VPN_BLOCK_DOCKER_DNS=yes`. Use addresses, or `extra_hosts`.
- It shares this container's network namespace. Compose restarts it along with `qbittorrentvpn` when Compose itself restarts or recreates that service (`restart: true` below). When `qbittorrentvpn` restarts on its own, after `VPN_RECOVERY_TIMEOUT` for example, the joined container keeps the old network, which has no interfaces left, and stays offline until you restart it.

## Example: Soulseek with slskd

[slskd](https://github.com/slskd/slskd) is a Soulseek client with a web UI on port 5030.

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
      VPN_USERNAME: your-vpn-username
      VPN_PASSWORD: your-vpn-password
      VPN_INPUT_PORTS: "5030"
    volumes:
      - ./config:/config
      - ./downloads:/downloads
    ports:
      - 8080:8080
      - 5030:5030
    restart: unless-stopped
    stop_grace_period: 150s

  slskd:
    image: slskd/slskd:latest
    network_mode: service:qbittorrentvpn
    depends_on:
      qbittorrentvpn:
        condition: service_healthy
        restart: true
    user: "99:100"
    environment:
      SLSKD_USERNAME: your-web-ui-username
      SLSKD_PASSWORD: your-web-ui-password
      SLSKD_SLSK_USERNAME: your-soulseek-username
      SLSKD_SLSK_PASSWORD: your-soulseek-password
      SLSKD_DOWNLOADS_DIR: /downloads/soulseek
      SLSKD_SHARED_DIR: /music
    volumes:
      - ./slskd:/app
      - ./downloads:/downloads
      - ./music:/music:ro
    restart: unless-stopped
```

Open `http://<host>:5030` and sign in with `SLSKD_USERNAME` and `SLSKD_PASSWORD`. slskd connects to the Soulseek network through the tunnel. Its listen port, 50300, is not open on the tunnel, so peers that cannot accept connections themselves cannot transfer with it; everything else works.

`condition: service_healthy` starts slskd only once the tunnel is up. Without it, slskd starts while the firewall still blocks everything and retries until the VPN connects.
