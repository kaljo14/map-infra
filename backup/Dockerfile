FROM restic/restic:0.19.1 AS restic
# Backup clients match the production server major (18); no server runs here.
FROM postgres:18.6-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends jq ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=restic /usr/bin/restic /usr/local/bin/restic
COPY backup.sh /opt/backup/backup.sh
ENV RESTIC_CACHE_DIR=/tmp/restic-cache
USER 10001:10001
WORKDIR /work
ENTRYPOINT ["bash", "/opt/backup/backup.sh"]
