#!/bin/sh
# Runs the whole test suite against throwaway servers in Docker: MariaDB
# 10.4 for most tests, and for SSHTunnelTests a database that only an SSH
# server can reach, directly or through an HTTP proxy with a login.
#   testenv/run-tests.sh                  all tests
#   testenv/run-tests.sh --filter Backup  extra arguments go to `swift test`
# The servers are left running for the next run; stop them with
#   docker compose -f testenv/docker-compose.yml --profile ssh down
set -eu
cd "$(dirname "$0")/.."
# The SSH server's image trusts this key; it's made once and never committed.
mkdir -p testenv/.keys
[ -f testenv/.keys/id_test ] || ssh-keygen -q -t ed25519 -N "" -C mysqlmacclient-test -f testenv/.keys/id_test
docker compose -f testenv/docker-compose.yml --profile ssh up -d --build --wait
# The native build system: SwiftPM 6.4's default one fails on the String
# Catalog (it makes Swift symbols of its keys, and some keys collide).
MYSQL_TEST_HOST=127.0.0.1 MYSQL_TEST_PORT=43306 MYSQL_TEST_USER=root MYSQL_TEST_PASSWORD= \
MYSQL_TEST_SSH_PORT=43322 MYSQL_TEST_SSH_KEY="$PWD/testenv/.keys/id_test" MYSQL_TEST_PROXY_PORT=43380 \
    swift test --build-system native "$@"
