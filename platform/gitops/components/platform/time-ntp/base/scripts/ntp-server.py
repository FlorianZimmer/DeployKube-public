#!/usr/bin/env python3

import socket
import struct
import time

NTP_EPOCH_OFFSET = 2208988800
BIND_ADDRESS = "0.0.0.0"
PORT = 123
REFERENCE_ID = b"DKTP"


def to_ntp_timestamp(unix_time):
    ntp_time = unix_time + NTP_EPOCH_OFFSET
    seconds = int(ntp_time)
    fraction = int((ntp_time - seconds) * (1 << 32)) & 0xFFFFFFFF
    return seconds, fraction


def build_response(request):
    now = time.time()
    recv_seconds, recv_fraction = to_ntp_timestamp(now)
    tx_seconds, tx_fraction = to_ntp_timestamp(time.time())

    version = (request[0] >> 3) & 0x07
    if version == 0:
        version = 4

    response = bytearray(48)
    response[0] = (0 << 6) | (version << 3) | 4
    response[1] = 3
    response[2] = 6
    response[3] = 0xEC
    struct.pack_into("!I", response, 8, 1 << 16)
    response[12:16] = REFERENCE_ID

    struct.pack_into("!II", response, 16, recv_seconds, recv_fraction)
    response[24:32] = request[40:48]
    struct.pack_into("!II", response, 32, recv_seconds, recv_fraction)
    struct.pack_into("!II", response, 40, tx_seconds, tx_fraction)
    return response


def serve():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((BIND_ADDRESS, PORT))
    while True:
        payload, remote = sock.recvfrom(1024)
        if len(payload) < 48:
            continue
        sock.sendto(build_response(payload), remote)


if __name__ == "__main__":
    serve()
