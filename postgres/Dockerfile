# ARM64 base is the exact PostgreSQL 18.1 image currently running in production.
# Build separately from backup tools; never replace this with an unpinned latest.
FROM registry-1.docker.io/bitnami/postgresql@sha256:4237ea262ad7aa0fdbb5f04015581cc6372aecb6741cce97ddaca3fe51ebeceb AS build
USER 0
ARG POSTGIS_VERSION=3.6.1
# Source checksum also recorded by Buildroot, commit ae81440dd0114a39bfb768ce6ff32349934f16e3.
ARG POSTGIS_SHA256=ec0cfaab475630106211d180d71df46782e41e10b6dffe91d79ca818ecd2cbb4
RUN command -v apt-get \
    && test -f "$(/opt/bitnami/postgresql/bin/pg_config --includedir-server)/postgres.h" \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       build-essential ca-certificates curl pkg-config libgeos-dev libproj-dev \
       libjson-c-dev libxml2-dev libprotobuf-c-dev protobuf-c-compiler libpcre2-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
RUN curl --fail --location --retry 3 \
      "https://download.osgeo.org/postgis/source/postgis-${POSTGIS_VERSION}.tar.gz" -o postgis.tar.gz \
    && echo "${POSTGIS_SHA256}  postgis.tar.gz" | sha256sum --check --strict \
    && tar xzf postgis.tar.gz --strip-components=1 \
    && ./configure --with-pgconfig=/opt/bitnami/postgresql/bin/pg_config \
         --without-raster --without-sfcgal \
    && make -j2 with_llvm=no \
    && make install with_llvm=no DESTDIR=/postgis-root

FROM registry-1.docker.io/bitnami/postgresql@sha256:4237ea262ad7aa0fdbb5f04015581cc6372aecb6741cce97ddaca3fe51ebeceb
USER 0
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       libgeos-c1v5 libproj25 libjson-c5 libxml2 libprotobuf-c1 libpcre2-8-0 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /postgis-root/ /
USER 1001
