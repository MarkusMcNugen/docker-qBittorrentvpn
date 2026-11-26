# Test double for a VPN provider and the internet behind it: a WireGuard or
# OpenVPN server with NAT and DNS, an HTTP target, a NAT-PMP responder, and
# tcpdump for capturing the client's traffic.
FROM alpine:3.24
RUN apk add --no-cache bash busybox-extras curl dnsmasq iproute2 iptables netcat-openbsd \
        openssl openvpn python3 tcpdump wireguard-tools-wg
COPY entrypoint.sh natpmp-responder.py ovpn-check-user /usr/local/bin/
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/natpmp-responder.py /usr/local/bin/ovpn-check-user
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
