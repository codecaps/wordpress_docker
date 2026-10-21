#!/usr/bin/env bash
exec "$(dirname "$0")/../docker_build.sh" 6.9 "$@"
