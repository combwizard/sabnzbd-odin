#!/usr/bin/env bash
# Build/start/stop the production sabnzbd-odin Docker container.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCKER_ROOT="${SAB_ODIN_DOCKER_ROOT:-/opt/_dockers/sabnzbd-odin}"
ACTION="${1:-up}"

case "${ACTION}" in
  up | start)
    exec "${DOCKER_ROOT}/start-fork.sh"
    ;;
  down | stop)
    exec "${DOCKER_ROOT}/stop-fork.sh"
    ;;
  restart)
    "${DOCKER_ROOT}/stop-fork.sh"
    exec "${DOCKER_ROOT}/start-fork.sh"
    ;;
  build)
    cd "${DOCKER_ROOT}"
    docker compose build sabnzbd-odin
    ;;
  logs)
    cd "${DOCKER_ROOT}"
    docker compose logs -f sabnzbd-odin
    ;;
  *)
    echo "usage: $0 {up|down|restart|build|logs}" >&2
    exit 1
    ;;
esac
