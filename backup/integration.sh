#!/usr/bin/env bash
# Disposable Docker-only round trip. Never accesses Kubernetes or real credentials.
set -euo pipefail
suffix="$(date +%s)-$$"
network="pg-backup-test-$suffix"
source_name="source-$suffix"
target_name="target-$suffix"
repository="repository-$suffix"
backup_image="${BACKUP_TEST_IMAGE:-map-infra-backup:test}"
server_image="${RESTORE_TEST_IMAGE:-map-infra-restore:test}"
cleanup() {
  docker rm -fv "$source_name" "$target_name" >/dev/null 2>&1 || true
  docker volume rm "$repository" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker network create "$network" >/dev/null
docker volume create "$repository" >/dev/null
docker run --rm --user 0 --entrypoint sh -v "$repository:/repo" "$backup_image" \
  -c 'chown 10001:10001 /repo; chmod 700 /repo'
docker run -d --name "$source_name" --network "$network" \
  -e POSTGRES_PASSWORD=test-only "$server_image" >/dev/null
docker run -d --name "$target_name" --network "$network" \
  -e POSTGRES_USER=restore_admin -e POSTGRES_DB=postgres \
  -e POSTGRES_PASSWORD=test-only "$server_image" >/dev/null
for container in "$source_name" "$target_name"; do
  ready=false
  for attempt in $(seq 1 60); do
    if docker exec "$container" pg_isready -h 127.0.0.1 -d postgres >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 1
  done
  "$ready" || { docker logs "$container"; exit 1; }
done
docker exec -i "$source_name" psql -X -U postgres -v ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE app_owner LOGIN PASSWORD 'test-app-only';
CREATE ROLE app_reader;
CREATE DATABASE geopulse OWNER app_owner;
CREATE DATABASE "secondary db" OWNER app_owner;
\connect geopulse
CREATE EXTENSION postgis;
CREATE EXTENSION postgis_topology;
CREATE EXTENSION fuzzystrmatch;
CREATE EXTENSION postgis_tiger_geocoder;
CREATE TABLE places (id integer PRIMARY KEY, location geometry(Point,4326));
INSERT INTO places VALUES (1, ST_SetSRID(ST_MakePoint(23.32,42.70),4326));
ALTER TABLE places OWNER TO app_owner;
GRANT SELECT ON places TO app_reader;
\connect "secondary db"
CREATE TABLE sentinel (value text);
INSERT INTO sentinel VALUES ('backup round trip');
SQL
operation() {
  local dbhost="$1" dbuser="$2"
  shift 2
  docker run --rm --network "$network" --tmpfs /work:uid=10001,gid=10001 \
    -v "$repository:/repo" -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD=test-only \
    -e PGHOST="$dbhost" -e PGUSER="$dbuser" -e PGPASSWORD=test-only "$backup_image" "$@"
}
operation "$source_name" postgres init
operation "$source_name" postgres backup
snapshot="$(docker run --rm --entrypoint restic -v "$repository:/repo" \
  -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD=test-only "$backup_image" snapshots --json |
  jq -r '.[-1].id')"
if operation "$source_name" postgres restore --snapshot "$snapshot" --confirm-target "$source_name"; then
  echo 'ERROR: restore into source was accepted' >&2
  exit 1
fi
operation "$target_name" restore_admin restore --snapshot "$snapshot" --confirm-target "$target_name"
result="$(docker exec "$target_name" psql -X -U restore_admin -d geopulse -Atc \
  "SELECT ST_AsText(location) FROM places WHERE id=1")"
test "$result" = 'POINT(23.32 42.7)'
result="$(docker exec "$target_name" psql -X -U restore_admin -d geopulse -Atc \
  "SELECT has_table_privilege('app_reader','places','SELECT') AND pg_get_userbyid(relowner)='app_owner' FROM pg_class WHERE relname='places'")"
test "$result" = t
result="$(docker exec "$target_name" psql -X -U restore_admin -d 'secondary db' -Atc 'TABLE sentinel')"
test "$result" = 'backup round trip'
if operation "$target_name" restore_admin restore --snapshot "$snapshot" --confirm-target "$target_name"; then
  echo 'ERROR: restore into populated target was accepted' >&2
  exit 1
fi
operation "$source_name" postgres check
echo 'PostGIS, roles, ownership, permissions, multiple databases and restore guards passed.'
