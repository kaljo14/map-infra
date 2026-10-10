# ARM64 base is the exact PostgreSQL 18.1 image currently running in production.
# Build separately from backup tools; never replace this with an unpinned latest.
FROM registry-1.docker.io/bitnami/postgresql@sha256:4237ea262ad7aa0fdbb5f04015581cc6372aecb6741cce97ddaca3fe51ebeceb AS build
USER 0
ARG POSTGIS_VERSION=3.6.1
# Source checksum also recorded by Buildroot, commit ae81440dd0114a39bfb768ce6ff32349934f16e3.
ARG POSTGIS_SHA256=ec0cfaab475630106211d180d71df46782e41e10b6dffe91d79ca818ecd2cbb4
# https://github.com/OSGeo/PROJ/releases/tag/9.6.2
ARG PROJ_VERSION=9.6.2
ARG PROJ_SHA256=53d0cafaee3bb2390264a38668ed31d90787de05e71378ad7a8f35bb34c575d1
RUN command -v tdnf \
    && test -f "$(/opt/bitnami/postgresql/bin/pg_config --includedir-server)/postgres.h" \
    && tdnf install -y \
       gcc libstdc++-devel make binutils glibc-devel ca-certificates curl pkg-config \
       tar gzip perl diffutils findutils geos-devel json-c-devel \
       libxml2-devel protobuf-c-devel pcre2-devel cmake sqlite-devel sqlite \
       libtiff-devel curl-devel \
    && tdnf clean all
# Photon 5 provides GEOS but no PROJ package. Build PROJ on the same base so
# its shared library ABI matches the server; include proj.db in the final image.
WORKDIR /build/proj
RUN curl --fail --location --retry 3 \
      "https://github.com/OSGeo/PROJ/releases/download/${PROJ_VERSION}/proj-${PROJ_VERSION}.tar.gz" -o proj.tar.gz \
    && echo "${PROJ_SHA256}  proj.tar.gz" | sha256sum --check --strict \
    && tar xzf proj.tar.gz --strip-components=1 \
    && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
         -DCMAKE_INSTALL_PREFIX=/opt/postgis-proj -DCMAKE_INSTALL_LIBDIR=lib \
         -DBUILD_TESTING=OFF \
    && cmake --build build --parallel 2 \
    && cmake --install build \
    && echo /opt/postgis-proj/lib > /etc/ld.so.conf.d/postgis-proj.conf \
    && ldconfig
ENV PKG_CONFIG_PATH=/opt/postgis-proj/lib/pkgconfig
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
# The pinned Bitnami image uses Photon OS, not Debian.
RUN tdnf install -y geos json-c libxml2 protobuf-c pcre2 sqlite libtiff curl \
    && tdnf clean all
COPY --from=build /opt/postgis-proj/ /opt/postgis-proj/
COPY --from=build /postgis-root/ /
RUN echo /opt/postgis-proj/lib > /etc/ld.so.conf.d/postgis-proj.conf && ldconfig
USER 1001
