FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       nfs-kernel-server \
       nfs-common \
       rpcbind \
       kmod \
       procps \
       iproute2 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME ["/export"]

EXPOSE 111/tcp 111/udp 2049/tcp 2049/udp 20048/tcp 20048/udp 32803/tcp 32803/udp 875/tcp 875/udp 662/tcp 662/udp

ENTRYPOINT ["/entrypoint.sh"]
