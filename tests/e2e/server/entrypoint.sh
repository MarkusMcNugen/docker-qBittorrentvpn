#!/bin/bash
# Roles for the end-to-end test double. The container is started on the lan
# network and attached to wan before it starts, so both interfaces exist.
#   target            HTTP server; GET /cgi-bin/ip returns the caller's address
#   wg                WireGuard server 10.13.0.1/24 with NAT, DNS and NAT-PMP;
#                     writes the client configuration to /shared/client.conf
#   ovpn              OpenVPN server 10.14.0.1/24 and fd00:14::1/64 with NAT,
#                     DNS, NAT-PMP and user/password check; writes
#                     /shared/client.ovpn
#   capture <iface>   tcpdump of every packet on <iface> to /shared/lan.pcap
set -euo pipefail
role="${1:?role}"
shift
TARGET_NAME=target.e2e
TARGET_IP="${TARGET_IP:-172.31.251.10}"
MAPPED_PORT="${MAPPED_PORT:-40123}"
# dnsmasq with --no-resolv needs an upstream server or it warns; nothing
# listens on this one, so names other than TARGET_NAME fail. TARGET_NAME is
# a host record and --filter-AAAA answers its AAAA query with no address, as
# a real server does for an IPv4-only name: musl's getaddrinfo fails the
# whole lookup when either query goes unanswered.
DNS_UPSTREAM=127.0.0.1#1
# natpmpc refuses a public address in any private, shared, documentation or
# other reserved range, so NAT-PMP reports this stand-in. Nothing is sent to it.
NATPMP_PUBLIC_IP="${NATPMP_PUBLIC_IP:-1.2.3.4}"

wan_if() { ip -o -4 addr show | awk -v p="${WAN_PREFIX:-172.31.251.}" 'index($4, p) == 1 { print $2; exit }'; }
wan_ip() { ip -o -4 addr show | awk -v p="${WAN_PREFIX:-172.31.251.}" 'index($4, p) == 1 { split($4, a, "/"); print a[1]; exit }'; }
lan_ip() { ip -o -4 addr show | awk -v p="${LAN_PREFIX:-172.31.250.}" 'index($4, p) == 1 { split($4, a, "/"); print a[1]; exit }'; }

case "$role" in
  target)
    mkdir -p /www/cgi-bin
    # shellcheck disable=SC2016  # $REMOTE_ADDR belongs to the CGI script
    printf '#!/bin/sh\nprintf "Content-Type: text/plain\\r\\n\\r\\n%%s" "$REMOTE_ADDR"\n' >/www/cgi-bin/ip
    chmod 0755 /www/cgi-bin/ip
    echo "target: serving on :80"
    exec httpd -f -vv -p 0.0.0.0:80 -h /www
    ;;

  wg)
    mkdir -p /shared
    umask 077
    wg genkey >/shared/server.key
    wg genkey >/shared/client.key
    server_pub=$(wg pubkey </shared/server.key)
    client_pub=$(wg pubkey </shared/client.key)
    ip link add dev wg0 type wireguard
    wg set wg0 listen-port 51820 private-key /shared/server.key peer "$client_pub" allowed-ips 10.13.0.2/32
    ip address add 10.13.0.1/24 dev wg0
    ip link set wg0 up
    iptables -t nat -A POSTROUTING -s 10.13.0.0/24 -o "$(wan_if)" -j MASQUERADE
    cat >/shared/client.conf <<EOF
[Interface]
PrivateKey = $(cat /shared/client.key)
Address = 10.13.0.2/32
DNS = 10.13.0.1

[Peer]
PublicKey = ${server_pub}
AllowedIPs = 0.0.0.0/0
Endpoint = ${ENDPOINT_NAME:-e2e-wg}:51820
EOF
    chmod 0644 /shared/client.conf
    dnsmasq --keep-in-foreground --listen-address=10.13.0.1 --listen-address="$(lan_ip)" --bind-dynamic --no-resolv --no-hosts \
      --server="$DNS_UPSTREAM" --host-record="${TARGET_NAME},${TARGET_IP}" --filter-AAAA --log-queries --log-facility=- &
    natpmp-responder.py 10.13.0.1 "$NATPMP_PUBLIC_IP" "$MAPPED_PORT" &
    echo "wg: ready, wan $(wan_if) $(wan_ip)"
    while :; do sleep 3600; done
    ;;

  ovpn)
    mkdir -p /shared /pki
    cd /pki
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 \
      -subj '/CN=e2e-ca' -keyout ca.key -out ca.crt 2>/dev/null
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj '/CN=e2e-ovpn' \
      -keyout server.key -out server.csr 2>/dev/null
    printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyAgreement\nextendedKeyUsage=serverAuth\n' >server.ext
    openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 2 -extfile server.ext -out server.crt 2>/dev/null
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj '/CN=e2e-client' \
      -keyout client.key -out client.csr 2>/dev/null
    printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=clientAuth\n' >client.ext
    openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 2 -extfile client.ext -out client.crt 2>/dev/null
    cat >server.conf <<'EOF'
port 1194
proto udp
dev tun0
topology subnet
server 10.14.0.0 255.255.255.0
server-ipv6 fd00:14::/64
ca /pki/ca.crt
cert /pki/server.crt
key /pki/server.key
dh none
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
push "redirect-gateway def1"
push "dhcp-option DNS 10.14.0.1"
keepalive 5 20
script-security 2
auth-user-pass-verify /usr/local/bin/ovpn-check-user via-file
verb 3
EOF
    {
      printf 'client\ndev tun\nproto udp\nremote %s 1194\nnobind\npersist-key\npersist-tun\nremote-cert-tls server\nauth-user-pass\nverb 3\n' "${ENDPOINT_NAME:-e2e-ovpn}"
      printf '<ca>\n%s\n</ca>\n<cert>\n%s\n</cert>\n<key>\n%s\n</key>\n' "$(cat ca.crt)" "$(cat client.crt)" "$(cat client.key)"
    } >/shared/client.ovpn
    chmod 0644 /shared/client.ovpn
    iptables -t nat -A POSTROUTING -s 10.14.0.0/24 -o "$(wan_if)" -j MASQUERADE
    openvpn --config server.conf &
    for _ in $(seq 1 100); do ip -o -4 addr show dev tun0 2>/dev/null | grep -q 10.14.0.1 && break; sleep 0.2; done
    dnsmasq --keep-in-foreground --listen-address=10.14.0.1 --listen-address="$(lan_ip)" --bind-dynamic --no-resolv --no-hosts \
      --server="$DNS_UPSTREAM" --host-record="${TARGET_NAME},${TARGET_IP}" --filter-AAAA --log-queries --log-facility=- &
    natpmp-responder.py 10.14.0.1 "$NATPMP_PUBLIC_IP" "$MAPPED_PORT" &
    echo "ovpn: ready, wan $(wan_if) $(wan_ip)"
    while :; do sleep 3600; done
    ;;

  capture)
    iface="${1:?interface}"
    echo "capture: recording ${iface}"
    exec tcpdump -i "$iface" -n -U -w /shared/lan.pcap
    ;;

  *)
    echo "unknown role ${role}" >&2
    exit 2
    ;;
esac
