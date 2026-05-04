#!/usr/bin/env bash
# ABOUTME: Sister wrapper to run OpenCode in Docker via the shared claude-docker stack.
# ABOUTME: Forwards all args to claude-docker.sh with --tool opencode prepended.
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
exec "$SCRIPT_DIR/claude-docker.sh" --tool opencode "$@"
