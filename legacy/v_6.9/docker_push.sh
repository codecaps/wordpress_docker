#!/usr/bin/env bash
exec "$(dirname "$0")/../docker_push.sh" 6.9 "$@"
