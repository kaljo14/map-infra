#!/usr/bin/env bash
# Container entrypoint: logical PostgreSQL backup + encrypted restic repository.
set -Eeuo pipefail
umask 077
work="${BACKUP_WORK_DIR:-/work}"
backup_host="${RESTIC_HOST:-lonctus-production}"
backup_tag="${RESTIC_TAG:-postgres}"
die() { echo "$*" >&2; exit 1; }
sql() { PGDATABASE="${2:-postgres}" psql -X -w -At -v ON_ERROR_STOP=1 -c "$1"; }
restic_cmd() { restic --retry-lock 5m -o s3.connections=2 "$@"; }
server() {
  sql "SELECT json_build_object('version_num', current_setting('server_version_num')::int,
    'version', current_setting('server_version'), 'system_identifier',system_identifier::text)
    FROM pg_control_system()"
}
client_major() { pg_dump --version | sed -E 's/.*PostgreSQL\) ([0-9]+).*/\1/'; }
fresh() { test ! -e "$1" || die "Scratch directory already exists: $1"; mkdir -p "$1"; }

backup() {
  local source databases after root manifest db oid filename extensions checksum
  source="$(server)"
  test "$(jq -r '.version_num / 10000 | floor' <<< "$source")" = "$(client_major)" \
    || die 'Backup client major must match the source server major'
  test "$(sql 'SELECT rolsuper FROM pg_roles WHERE rolname=current_user')" = t \
    || die 'Full cluster backup requires a superuser'
  restic_cmd snapshots --json --host "$backup_host" --tag "$backup_tag" >/dev/null
  databases="$(sql "SELECT coalesce(json_agg(d ORDER BY name),'[]'::json) FROM
    (SELECT oid,datname AS name,datallowconn AS connect FROM pg_database WHERE NOT datistemplate) d")"
  jq -e 'length > 0 and all(.[]; .connect and (.name | explode | all(.[]; . >= 32)))' \
    <<< "$databases" >/dev/null || die 'Database is inaccessible or has a control character in its name'
  root="$work/export"
  fresh "$root"
  trap 'rm -rf -- "$work/export"' EXIT
  manifest="$root/manifest.json"
  jq -n --argjson source "$source" --argjson client "$(client_major)" \
    --arg started "$(date -u +%FT%TZ)" \
    --argjson roles "$(sql "SELECT json_agg(rolname ORDER BY rolname) FROM pg_roles WHERE rolname !~ '^pg_'")" \
    '{format:1,source:$source,client_major:$client,started_at:$started,roles:$roles,databases:[],files:{}}' > "$manifest"
  pg_dumpall -w --roles-only --file="$root/roles.sql"
  while read -r oid; do
    db="$(jq -r --argjson oid "$oid" '.[] | select(.oid==$oid) | .name' <<< "$databases")"
    filename="database-$oid.dump"
    extensions="$(sql "SELECT json_agg(e ORDER BY name) FROM
      (SELECT extname AS name,extversion AS version FROM pg_extension) e" "$db")"
    PGDATABASE="$db" pg_dump -w --format=custom --compress=0 --create --no-tablespaces \
      --file="$root/$filename"
    pg_restore --list "$root/$filename" >/dev/null
    jq --arg name "$db" --arg file "$filename" --argjson extensions "$extensions" \
      '.databases += [{name:$name,file:$file,extensions:$extensions}]' "$manifest" > "$manifest.tmp"
    mv "$manifest.tmp" "$manifest"
  done < <(jq -r '.[].oid' <<< "$databases")
  after="$(sql "SELECT json_agg(datname) FROM pg_database WHERE NOT datistemplate")"
  jq -en --argjson before "$databases" --argjson after "$after" \
    '($before | map(.name) | sort) == ($after | sort)' >/dev/null \
    || die 'Database list changed during backup; retry during a quiet period'
  for filename in "$root/roles.sql" "$root"/database-*.dump; do
    checksum="$(sha256sum "$filename" | cut -d ' ' -f1)"
    jq --arg name "${filename##*/}" --arg checksum "$checksum" '.files[$name]=$checksum' \
      "$manifest" > "$manifest.tmp"
    mv "$manifest.tmp" "$manifest"
  done
  jq --arg finished "$(date -u +%FT%TZ)" '.finished_at=$finished' "$manifest" > "$manifest.tmp"
  mv "$manifest.tmp" "$manifest"
  restic_cmd backup "$root" --host "$backup_host" --tag "$backup_tag"
  restic_cmd check
  local last="${KEEP_LAST:-7}" daily="${KEEP_DAILY:-7}" weekly="${KEEP_WEEKLY:-4}" monthly="${KEEP_MONTHLY:-3}"
  [[ "$last" =~ ^[1-9][0-9]*$ && "$daily" =~ ^[0-9]+$ && "$weekly" =~ ^[0-9]+$ && "$monthly" =~ ^[0-9]+$ ]] \
    || die 'Invalid retention counts'
  # No snapshot upload or retention is reached if ANY database dump fails.
  restic_cmd forget --host "$backup_host" --tag "$backup_tag" --group-by host,tags \
    --keep-last "$last" --keep-daily "$daily" --keep-weekly "$weekly" --keep-monthly "$monthly" \
    --prune --max-repack-size 256M
  echo 'Backup uploaded, repository metadata checked, retention applied.'
}

restore() {
  local snapshot='' confirm='' target snapshots selected root manifest name checksum current available needed filename db count
  while test "$#" -gt 0; do
    case "$1" in
      --snapshot) snapshot="${2:?Missing snapshot ID}"; shift 2 ;;
      --confirm-target) confirm="${2:?Missing target host}"; shift 2 ;;
      *) die "Unknown restore argument: $1" ;;
    esac
  done
  if test -z "${PGHOST:-}" || test "$confirm" != "$PGHOST"; then
    die '--confirm-target must equal the explicit destination PGHOST'
  fi
  [[ "$snapshot" =~ ^[a-f0-9]{8,64}$ ]] || die 'Use an explicit snapshot ID; latest is not accepted'
  target="$(server)"
  snapshots="$(restic_cmd snapshots --json --host "$backup_host" --tag "$backup_tag")"
  selected="$(jq --arg id "$snapshot" '[.[] | select(.id | startswith($id))]' <<< "$snapshots")"
  test "$(jq length <<< "$selected")" = 1 || die 'Snapshot missing, ambiguous, or wrong host/tag'
  fresh "$work/restore"
  restic_cmd restore "$(jq -r '.[0].id' <<< "$selected")" --target "$work/restore" --verify
  local manifests=()
  while IFS= read -r name; do manifests+=("$name"); done < <(find "$work/restore" -name manifest.json -type f)
  test "${#manifests[@]}" = 1 || die 'Expected one backup manifest'
  manifest="${manifests[0]}"; root="${manifest%/*}"
  test "$(jq -r '.format' "$manifest")" = 1 || die 'Unsupported backup format'
  test "$(jq -r '.system_identifier' <<< "$target")" != "$(jq -r '.source.system_identifier' "$manifest")" \
    || die 'Refusing to restore into the source cluster, including an alias'
  test "$(jq -r '.version_num / 10000 | floor' <<< "$target")" -ge "$(jq -r '.client_major' "$manifest")" \
    || die 'Destination PostgreSQL major is older than the backup client'
  test "$(client_major)" -ge "$(jq -r '.client_major' "$manifest")" || die 'pg_restore is too old'
  while read -r name; do
    [[ "$name" =~ ^(roles\.sql|database-[0-9]+\.dump)$ ]] || die 'Invalid archive filename'
    checksum="$(sha256sum "$root/$name" | cut -d ' ' -f1)"
    test "$checksum" = "$(jq -r --arg name "$name" '.files[$name]' "$manifest")" \
      || die "Checksum mismatch: $name"
  done < <(jq -r '.files | keys[]' "$manifest")
  jq -e '.files["roles.sql"] != null and (.databases | length > 0)' "$manifest" >/dev/null \
    || die 'Incomplete manifest'
  current="$(sql 'SELECT current_user')"
  test "$(sql 'SELECT rolsuper FROM pg_roles WHERE rolname=current_user')" = t \
    || die 'Restore requires a bootstrap superuser'
  jq -e --arg current "$current" '.roles | index($current) == null' "$manifest" >/dev/null \
    || die 'Bootstrap role exists in backup; initialize target as restore_admin'
  test "$(sql "SELECT count(*) FROM pg_roles WHERE rolname !~ '^pg_' AND rolname<>current_user")" = 0 \
    || die 'Target already has non-bootstrap roles; use a fresh cluster'
  test "$(sql "SELECT count(*) FROM pg_database WHERE NOT datistemplate AND datname<>'postgres'")" = 0 \
    || die 'Target has application databases; use a fresh cluster'
  for db in postgres template1; do
    count="$(sql "SELECT
      (SELECT count(*) FROM pg_namespace WHERE nspname NOT IN ('public','information_schema') AND nspname !~ '^pg_') +
      (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname<>'information_schema' AND n.nspname !~ '^pg_') +
      (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname<>'information_schema' AND n.nspname !~ '^pg_') +
      (SELECT count(*) FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace WHERE n.nspname<>'information_schema' AND n.nspname !~ '^pg_') +
      (SELECT count(*) FROM pg_extension WHERE extname<>'plpgsql') +
      (SELECT count(*) FROM pg_largeobject_metadata)" "$db")"
    test "$count" = 0 || die "Target $db contains user objects; use a fresh cluster"
  done
  available="$(sql 'SELECT json_agg(name) FROM pg_available_extensions')"
  needed="$(jq '[.databases[].extensions[].name] | unique' "$manifest")"
  jq -en --argjson available "$available" --argjson needed "$needed" '$needed - $available | length == 0' >/dev/null \
    || die 'Target lacks required extension libraries; install PostGIS, topology, Tiger and fuzzystrmatch'
  while read -r filename; do
    [[ "$filename" =~ ^database-[0-9]+\.dump$ ]] || die 'Invalid database archive path'
    jq -e --arg file "$filename" '.files[$file] != null' "$manifest" >/dev/null || die 'Missing archive checksum'
    pg_restore --list "$root/$filename" >/dev/null
  done < <(jq -r '.databases[].file' "$manifest")
  PGDATABASE=template1 psql -X -w -v ON_ERROR_STOP=1 -f "$root/roles.sql"
  while read -r filename; do
    pg_restore -w --exit-on-error --create --clean --if-exists --no-tablespaces \
      --dbname=template1 "$root/$filename"
    db="$(jq -er --arg file "$filename" \
      '[.databases[] | select(.file==$file) | .name] | if length == 1 and .[0] != "" then .[0] else error("Missing or ambiguous database for archive: \($file)") end' \
      "$manifest")"
    echo "Analyzing restored database: $db"
    vacuumdb -w --analyze-only "$db"
    echo "Restored database: $db"
  done < <(jq -r '.databases[].file' "$manifest")
  rm -rf -- "$work/restore"
  echo 'Restore complete. Validate application queries before changing endpoints.'
}

case "${1:-}" in
  backup) backup ;;
  init) restic_cmd init ;;
  snapshots) restic_cmd snapshots --host "$backup_host" --tag "$backup_tag" ;;
  check) restic_cmd check --read-data ;;
  stats) restic_cmd stats --mode raw-data ;;
  restore) shift; restore "$@" ;;
  *) die 'Usage: backup.sh {init|backup|snapshots|check|stats|restore --snapshot ID --confirm-target HOST}' ;;
esac
