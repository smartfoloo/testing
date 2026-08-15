#!/usr/bin/env bash
# Applies every migration plus the seed fixture to a throwaway
# supabase/postgres container and runs supabase/tests/backend_tests.sql.
set -euo pipefail

CONTAINER="${CONTAINER:-aikanji-pg-test}"
IMAGE="${IMAGE:-supabase/postgres:15.8.1.060}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPABASE_DIR="$(dirname "$HERE")"

psql_file() { docker exec -i "$CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 -q < "$1"; }

echo "==> starting $CONTAINER"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" -e POSTGRES_PASSWORD=postgres "$IMAGE" >/dev/null
for _ in $(seq 1 60); do
  docker exec "$CONTAINER" pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done
# pg_isready reports the bootstrap postmaster (socket only) too, so wait until
# the final postmaster answers over TCP.
until docker exec "$CONTAINER" psql -h 127.0.0.1 -U postgres -c 'select 1' >/dev/null 2>&1
do sleep 1; done

echo "==> realtime stubs"
# The realtime schema is owned by supabase_admin in the base image.
# (loopback is trusted in the image's pg_hba, so no password is needed)
docker exec -i "$CONTAINER" psql -h 127.0.0.1 -U supabase_admin -d postgres \
  -v ON_ERROR_STOP=1 -q < "$HERE/harness.sql"

for f in "$SUPABASE_DIR"/migrations/*.sql; do
  echo "==> $(basename "$f")"
  psql_file "$f"
done

echo "==> seed.sql"
psql_file "$SUPABASE_DIR/seed.sql"

echo "==> backend_tests.sql"
docker exec -i "$CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 < "$HERE/backend_tests.sql"
