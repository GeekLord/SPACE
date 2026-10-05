FROM ubuntu:26.04@sha256:da6fc2be547864451aa253836dd926da33623312df4a9a243e35dc877c378a78

RUN apt-get update && apt-get install -y \
    squashfs-tools e2fsprogs curl wget ca-certificates gpgv ubuntu-keyring \
    && rm -rf /var/lib/apt/lists/*

COPY rootfs-builder.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/rootfs-builder.sh

ENTRYPOINT ["rootfs-builder.sh"]
