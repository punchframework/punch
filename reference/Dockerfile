# The reference app as one static binary in an image without a shell or
# package manager (lib/punch/docs/deployment.md). Punch is a path dependency here, so
# the build context is Punch's root:
#
#   docker build -f reference/Dockerfile -t invoicing .                  # the image
#   docker build -f reference/Dockerfile --target binary --output out .  # only the binary, for systemd
#
# The image runs `serve` as user 1000 with the database files in /data, a
# volume on local disk. It migrates at boot (PUNCH_MIGRATE) and replicates
# with the Litestream it carries when PUNCH_BACKUP_URL is set.

# Pinned like toolchain.env. Move it deliberately, with the checksums.
ARG CRYSTAL_IMAGE=crystallang/crystal:1.22.0-alpine
ARG LITESTREAM_VERSION=0.5.17

FROM ${CRYSTAL_IMAGE} AS build
ARG LITESTREAM_VERSION
ARG TARGETARCH
# bash runs scripts/build-sqlite.sh, which Punch's link step calls.
RUN apk add --no-cache bash tzdata ca-certificates
# Litestream's release archive, checked against the checksums it publishes.
RUN case "${TARGETARCH:-$(uname -m)}" in \
      arm64|aarch64) asset=arm64 sum=f8ca4a050095c1efbda2c4365172e61bf9d955ea0d9ac42f448b52e51819baa5 ;; \
      amd64|x86_64) asset=x86_64 sum=cfb371176d164437ae869f8351cfde49bd1804ae71c61923f75c9cba9c9c006d ;; \
      *) echo "no Litestream for ${TARGETARCH}" >&2; exit 1 ;; \
    esac && \
    wget -q -O /tmp/litestream.tar.gz "https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-${LITESTREAM_VERSION}-linux-${asset}.tar.gz" && \
    echo "${sum}  /tmp/litestream.tar.gz" | sha256sum -c - && \
    tar xzf /tmp/litestream.tar.gz -C /usr/local/bin litestream && rm /tmp/litestream.tar.gz

WORKDIR /src
COPY . .
WORKDIR /src/reference
RUN rm -rf lib /src/build && shards install --production --frozen
RUN mkdir -p /out/data /out/tmp && chmod 1777 /out/tmp && \
    crystal build --release --static src/main.cr -o /out/invoicing

# Only the binary: `--target binary --output DIR` writes it to DIR.
FROM scratch AS binary
COPY --from=build /out/invoicing /invoicing

FROM scratch
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=build /usr/local/bin/litestream /usr/local/bin/litestream
COPY --from=build --chown=1000:1000 /out/data /data
COPY --from=build /out/tmp /tmp
COPY --from=build /out/invoicing /app/invoicing
ENV PATH=/usr/local/bin \
    PUNCH_ENV=production \
    PUNCH_STORAGE=/data \
    PUNCH_HOST=0.0.0.0 \
    PUNCH_PORT=3000
USER 1000:1000
VOLUME /data
EXPOSE 3000
# SIGTERM drains (lib/punch/docs/http.md); give it PUNCH_SHUTDOWN_TIMEOUT_SECONDS plus
# a margin before SIGKILL: `docker stop -t 30`, Kamal's drain_timeout.
STOPSIGNAL SIGTERM
ENTRYPOINT ["/app/invoicing"]
CMD ["serve"]
