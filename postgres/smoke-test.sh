#!/usr/bin/env bash
# Runs inside a DISPOSABLE custom image container, never a production Pod.
set -euo pipefail
test "$(id -u)" != 0
test_dir="$(mktemp -d)"
cleanup() {
  pg_ctl -D "$test_dir/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$test_dir"
}
trap cleanup EXIT
initdb -D "$test_dir/data" -U image_test --auth=trust >/dev/null
pg_ctl -D "$test_dir/data" -l "$test_dir/server.log" \
  -o "-k $test_dir -c listen_addresses=''" -w start
export PGHOST="$test_dir" PGUSER=image_test PGDATABASE=postgres
psql -X -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION postgis VERSION '3.6.1';
CREATE EXTENSION fuzzystrmatch;
CREATE EXTENSION postgis_topology VERSION '3.6.1';
CREATE EXTENSION postgis_tiger_geocoder VERSION '3.6.1';
SELECT postgis_full_version();
SELECT ST_AsText(ST_Transform(ST_SetSRID(ST_MakePoint(23.32,42.7),4326),3857));
SELECT length(ST_AsMVT(q)) FROM (SELECT 1 AS id, ST_MakePoint(1,2) AS geom) q;
SQL
# Validate the extensions after a real server restart too.
pg_ctl -D "$test_dir/data" -m fast -w restart -o "-k $test_dir -c listen_addresses=''"
test "$(psql -X -Atc "SELECT postgis_lib_version()")" = 3.6.1
