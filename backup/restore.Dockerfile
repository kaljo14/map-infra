# A disposable recovery server; never point this image at the Bitnami data PVC.
FROM postgres:18.6-bookworm
# Install libraries only. Restore creates extensions from the database archives.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       postgresql-18-postgis-3 postgresql-18-postgis-3-scripts \
    && rm -rf /var/lib/apt/lists/*
