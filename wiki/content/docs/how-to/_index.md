---
title: How-to guides
weight: 2
---

Each guide does one task, assuming the container already runs as in the [tutorial](../tutorials/getting-started/).

{{< cards >}}
  {{< card link="set-up-openvpn/" title="Set up OpenVPN" subtitle="The provider's file, credentials, several servers and extra options." >}}
  {{< card link="set-up-wireguard/" title="Set up WireGuard" subtitle="The provider's configuration, the kernel module or wireguard-go, IPv6 and keepalive." >}}
  {{< card link="reach-the-webui/" title="Reach the WebUI" subtitle="From your LAN, through a reverse proxy, and on another port." >}}
  {{< card link="forward-a-port/" title="Forward a port" subtitle="ProtonVPN, Private Internet Access, other NAT-PMP providers and fixed ports." >}}
  {{< card link="use-privoxy/" title="Use Privoxy" subtitle="An HTTP proxy for other applications whose traffic leaves only through the tunnel." >}}
  {{< card link="run-other-containers-through-the-tunnel/" title="Run other containers through the tunnel" subtitle="Join another container to this one's network, with Soulseek as the example." >}}
  {{< card link="change-qbittorrent-settings/" title="Change qBittorrent settings" subtitle="WebUI login, ports and any qBittorrent.conf value from the environment." >}}
  {{< card link="use-docker-secrets/" title="Use Docker secrets" subtitle="Read passwords from files instead of environment variables." >}}
  {{< card link="run-on-unraid/" title="Run on Unraid" subtitle="The template settings the container needs." >}}
  {{< card link="upgrade-from-1x/" title="Upgrade from 1.x" subtitle="What stays the same and what changes." >}}
  {{< card link="build-and-test/" title="Build and test" subtitle="Build the image yourself and run the unit and end-to-end tests." >}}
  {{< card link="troubleshoot/" title="Troubleshoot" subtitle="What a failing log line means and what to do about it." >}}
{{< /cards >}}
