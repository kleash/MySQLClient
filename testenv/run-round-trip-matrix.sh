#!/bin/sh
# Runs the backup round-trip and TLS tests on every server version in the `matrix`
# profile of testenv/docker-compose.yml (MariaDB 11.4, MySQL 8.0, MySQL 8.4)
# and reports each one. Stop the servers with
#   docker compose -f testenv/docker-compose.yml --profile matrix down
set -u
cd "$(dirname "$0")/.."
docker compose -f testenv/docker-compose.yml --profile matrix up -d --wait || exit 1
status=0
for server in mariadb-11.4:43307: mysql-8.0:43308:mysqlmacclient mysql-8.4:43309:mysqlmacclient; do
    name=${server%%:*} rest=${server#*:}
    port=${rest%%:*} password=${rest#*:}
    echo "== $name"
    output=$(MYSQL_TEST_HOST=127.0.0.1 MYSQL_TEST_PORT="$port" MYSQL_TEST_USER=root MYSQL_TEST_PASSWORD="$password" \
        swift test --build-system native --filter 'BackupRoundTripTests|TLSConnectionTests' 2>&1) || status=1
    printf '%s\n' "$output" | grep -E "error:|Executed .* tests" | sort -u
done
exit $status
