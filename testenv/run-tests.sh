#!/bin/sh
# Runs the whole test suite against a throwaway MariaDB in Docker.
#   testenv/run-tests.sh                  all tests
#   testenv/run-tests.sh --filter Backup  extra arguments go to `swift test`
# The server is left running for the next run; stop it with
#   docker compose -f testenv/docker-compose.yml down
set -eu
cd "$(dirname "$0")/.."
docker compose -f testenv/docker-compose.yml up -d --wait
# The native build system: SwiftPM 6.4's default one fails on the String
# Catalog (it makes Swift symbols of its keys, and some keys collide).
MYSQL_TEST_HOST=127.0.0.1 MYSQL_TEST_PORT=43306 MYSQL_TEST_USER=root MYSQL_TEST_PASSWORD= swift test --build-system native "$@"
