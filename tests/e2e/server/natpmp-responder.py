#!/usr/bin/env python3
"""NAT-PMP (RFC 6886) responder for the end-to-end tests.

Replies to public-address requests with PUBLIC_IP and to every mapping request
with MAPPED_PORT, echoing the requested private port and lifetime. Logs each
request on stdout.

    natpmp-responder.py <listen address> <public ip> <mapped port>
"""
import socket
import struct
import sys
import time

listen, public_ip, mapped = sys.argv[1], sys.argv[2], int(sys.argv[3])
start = time.monotonic()
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind((listen, 5351))
print(f"natpmp: listening on {listen}:5351, mapping to port {mapped}", flush=True)

while True:
    data, peer = sock.recvfrom(64)
    epoch = int(time.monotonic() - start)
    if len(data) >= 2 and data[0] == 0 and data[1] == 0:
        reply = struct.pack("!BBHI4s", 0, 128, 0, epoch, socket.inet_aton(public_ip))
        print(f"natpmp: public address request from {peer[0]}", flush=True)
    elif len(data) >= 12 and data[0] == 0 and data[1] in (1, 2):
        _, op, _, private, public, lifetime = struct.unpack("!BBHHHI", data[:12])
        reply = struct.pack("!BBHIHHI", 0, 128 + op, 0, epoch, private, mapped, lifetime)
        proto = "udp" if op == 1 else "tcp"
        print(f"natpmp: map {proto} public {public} private {private} lifetime {lifetime} -> {mapped}", flush=True)
    else:
        reply = struct.pack("!BBH", 0, 128 + (data[1] if len(data) > 1 else 0), 5)
        print(f"natpmp: unsupported request {data.hex()} from {peer[0]}", flush=True)
    sock.sendto(reply, peer)
