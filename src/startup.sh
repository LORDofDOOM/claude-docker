#!/usr/bin/env bash
set -euo pipefail
trap 'echo "$0: line $LINENO: $BASH_COMMAND: exitcode $?"' ERR

# ABOUTME: Startup script for claude-docker container with MCP servers
# ABOUTME: Loads telegram env vars, checks for .credentials.json, copies CLAUDE.md template if no claude.md in claude-docker/claude-home.
# ABOUTME: Starts claude code with permissions bypass and continues from last session.
# NOTE: Need to call claude-docker --rebuild to integrate changes.

# Load environment variables from .env if it exists
# Use the .env file baked into the image at build time
if [ -f /app/.env ]; then
    echo "Loading environment from baked-in .env file"
    set -a
    source /app/.env 2>/dev/null || true
    set +a
    
    # Export Telegram variables for runtime use
    export TELEGRAM_BOT_TOKEN
    export TELEGRAM_CHAT_ID
else
    echo "WARNING: No .env file found in image."
fi

# Check for existing authentication
if [ -f "$HOME/.claude/.credentials.json" ]; then
    echo "Found existing Claude authentication"
else
    echo "No existing authentication found - you will need to log in"
    echo "Your login will be saved for future sessions"
fi

# Handle CLAUDE.md template
if [ ! -f "$HOME/.claude/CLAUDE.md" ]; then
    echo "✓ No CLAUDE.md found at $HOME/.claude/CLAUDE.md - copying template"
    # Copy from the template that was baked into the image
    if [ -f "/app/.claude/CLAUDE.md" ]; then
        cp "/app/.claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
    elif [ -f "/home/claude-user/.claude.template/CLAUDE.md" ]; then
        # Fallback for existing images
        cp "/home/claude-user/.claude.template/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
    fi
    echo "  Template copied to: $HOME/.claude/CLAUDE.md"
else
    echo "✓ Using existing CLAUDE.md from $HOME/.claude/CLAUDE.md"
    echo "  This maps to your host persistent claude-home/CLAUDE.md"
    echo "  Default host path: ~/.claude-docker/claude-home/CLAUDE.md"
    echo "  To reset to template, delete this file and restart"
fi

# Verify Telegram MCP configuration
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    echo "✓ Telegram MCP configured - notifications enabled"
else
    echo "No Telegram credentials found - notifications disabled"
fi

# # Export environment variables from settings.json
# # This is a workaround for Docker container not properly exposing these to Claude
# if [ -f "$HOME/.claude/settings.json" ] && command -v jq >/dev/null 2>&1; then
#     echo "Loading environment variables from settings.json..."
#     # First remove comments from JSON, then extract env vars
#     # Using sed to remove // comments before parsing with jq
#     while IFS='=' read -r key value; do
#         if [ -n "$key" ] && [ -n "$value" ]; then
#             export "$key=$value"
#             echo "  Exported: $key=$value"
#         fi
#     done < <(sed 's://.*$::g' "$HOME/.claude/settings.json" | jq -r '.env // {} | to_entries | .[] | "\(.key)=\(.value)"' 2>/dev/null)
# fi

# Link Docker project path to host project path for shared session history
# This allows --continue to work across native claude and claude-docker
if [ -n "${HOST_PROJECT_KEY:-}" ]; then
    DOCKER_PROJECT_KEY=$(pwd | sed 's|/|-|g; s|\.|-|g')
    PROJECTS_DIR="$HOME/.claude/projects"
    mkdir -p "$PROJECTS_DIR"
    # Skip if they're the same key or already linked
    if [ "$HOST_PROJECT_KEY" != "$DOCKER_PROJECT_KEY" ]; then
        if [ -L "$PROJECTS_DIR/$DOCKER_PROJECT_KEY" ]; then
            echo "✓ Session history already linked: $DOCKER_PROJECT_KEY"
        elif [ -d "$PROJECTS_DIR/$HOST_PROJECT_KEY" ]; then
            # Host project exists — merge docker sessions into it, then symlink
            if [ -d "$PROJECTS_DIR/$DOCKER_PROJECT_KEY" ]; then
                # Move any docker session files into the host project dir
                cp -rn "$PROJECTS_DIR/$DOCKER_PROJECT_KEY/"* "$PROJECTS_DIR/$HOST_PROJECT_KEY/" 2>/dev/null || true
                rm -rf "$PROJECTS_DIR/$DOCKER_PROJECT_KEY"
            fi
            ln -s "$PROJECTS_DIR/$HOST_PROJECT_KEY" "$PROJECTS_DIR/$DOCKER_PROJECT_KEY"
            echo "✓ Linked session history: $DOCKER_PROJECT_KEY → $HOST_PROJECT_KEY"
        elif [ -d "$PROJECTS_DIR/$DOCKER_PROJECT_KEY" ]; then
            # Only docker project exists — link host to it
            ln -s "$PROJECTS_DIR/$DOCKER_PROJECT_KEY" "$PROJECTS_DIR/$HOST_PROJECT_KEY"
            echo "✓ Linked session history: $HOST_PROJECT_KEY → $DOCKER_PROJECT_KEY"
        else
            # Neither exists — create host dir and symlink docker to it
            mkdir -p "$PROJECTS_DIR/$HOST_PROJECT_KEY"
            ln -s "$PROJECTS_DIR/$HOST_PROJECT_KEY" "$PROJECTS_DIR/$DOCKER_PROJECT_KEY"
            echo "✓ Linked session history: $DOCKER_PROJECT_KEY → $HOST_PROJECT_KEY"
        fi
    fi
fi

# Mark workspace as safe for git (ownership differs due to Docker volume mount)
git config --global --add safe.directory "$(pwd)"

# Fix ownership of mounted workspace so claude-user can access all files
# (safe: on Docker Desktop this doesn't affect host; on Linux UIDs already match)
# Runs in background to avoid delaying startup on large workspaces
sudo chown -R claude-user "$(pwd)" &

# Configure git credential helper if host credentials were passed in
if [ -n "${GIT_CREDENTIAL_TOKEN:-}" ]; then
    # Create a simple credential helper script that returns the host's credentials
    cat > /home/claude-user/.git-credential-helper.sh << 'HELPER'
#!/bin/bash
echo "username=${GIT_CREDENTIAL_USER:-git}"
echo "password=${GIT_CREDENTIAL_TOKEN}"
HELPER
    chmod +x /home/claude-user/.git-credential-helper.sh
    git config --global credential.helper "/home/claude-user/.git-credential-helper.sh"
    echo "✓ Git credentials configured from host"
fi

# Match Windows host git line-ending config so Claude's commits don't show
# every file as changed due to CRLF/LF mismatch on the mounted volume
git config --global core.autocrlf true

# Apply optional settings to ~/.claude/settings.json
python3 -c "
import json, os

f = os.path.expanduser('~/.claude/settings.json')
try:
    with open(f) as fh: d = json.load(fh)
except: d = {}

# Disable AI attribution unless opted out
if os.environ.get('DISABLE_AI_ATTRIBUTION', 'true') != 'false':
    d['includeCoAuthoredBy'] = False
    d['attribution'] = {'commit': '', 'pr': ''}

# Enable enhanced status line unless opted out
if os.environ.get('ENABLE_STATUSLINE', 'true') != 'false':
    d['statusLine'] = {'type': 'command', 'command': '/app/statusline.sh'}

with open(f, 'w') as fh: json.dump(d, fh, indent=2)
" 2>/dev/null || true

if [ "${DISABLE_AI_ATTRIBUTION:-true}" != "false" ]; then
    echo "✓ AI attribution disabled in commits"
fi
if [ "${ENABLE_STATUSLINE:-true}" != "false" ]; then
    echo "✓ Enhanced status line enabled"
fi

# Auto-trust the current workspace so Claude doesn't prompt on first run
WORK_DIR="$(pwd)"
python3 -c "
import json, os, sys
f = os.path.expanduser('~/.claude.json')
try:
    with open(f) as fh: d = json.load(fh)
except: d = {}
p = d.setdefault('projects', {})
w = p.setdefault(sys.argv[1], {})
w['hasTrustDialogAccepted'] = True
with open(f, 'w') as fh: json.dump(d, fh)
" "$WORK_DIR" 2>/dev/null || true

# Start Claude Code with permissions bypass
echo "Starting Claude Code..."
exec claude $CLAUDE_CONTINUE_FLAG --dangerously-skip-permissions "$@"
