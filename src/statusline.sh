#!/bin/bash
# ABOUTME: Custom Claude Code status line showing model, cost, context usage, git branch, and plan usage
# ABOUTME: Receives JSON on stdin from Claude Code's statusline feature
input=$(cat)

MODEL=$(echo "$input" | jq -r '.model.display_name')
DIR=$(echo "$input" | jq -r '.workspace.current_dir')
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
DURATION_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; DIM='\033[2m'; RESET='\033[0m'

# Pick bar color based on context usage
if [ "$PCT" -ge 90 ]; then BAR_COLOR="$RED"
elif [ "$PCT" -ge 70 ]; then BAR_COLOR="$YELLOW"
else BAR_COLOR="$GREEN"; fi

FILLED=$((PCT / 10)); EMPTY=$((10 - FILLED))
printf -v FILL "%${FILLED}s"; printf -v PAD "%${EMPTY}s"
BAR="${FILL// /█}${PAD// /░}"

MINS=$((DURATION_MS / 60000)); SECS=$(((DURATION_MS % 60000) / 1000))

BRANCH=""
git rev-parse --git-dir > /dev/null 2>&1 && BRANCH=" | 🌿 $(git branch --show-current 2>/dev/null)"

# ── Plan usage (cached, refreshed every 60s) ──────────────────────
USAGE_CACHE="/tmp/.claude-usage-cache.json"
USAGE_TTL=60
USAGE_LINE=""

refresh_usage() {
    local creds_file="$HOME/.claude/.credentials.json"
    [ -f "$creds_file" ] || return
    local token
    token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
    [ -z "$token" ] && return
    local result
    result=$(curl -sf --max-time 5 \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
    # Only cache valid JSON responses (not error pages)
    if [ -n "$result" ] && echo "$result" | jq -e '.five_hour' >/dev/null 2>&1; then
        echo "$result" > "$USAGE_CACHE"
    fi
}

# Refresh cache if stale or missing
if [ ! -f "$USAGE_CACHE" ] || [ $(($(date +%s) - $(stat -c %Y "$USAGE_CACHE" 2>/dev/null || echo 0))) -ge $USAGE_TTL ]; then
    refresh_usage
fi

# Parse cached usage data
if [ -f "$USAGE_CACHE" ]; then
    FIVE_H_PCT=$(jq -r '.five_hour.utilization // empty' "$USAGE_CACHE" 2>/dev/null | cut -d. -f1)
    FIVE_H_RESET=$(jq -r '.five_hour.resets_at // empty' "$USAGE_CACHE" 2>/dev/null)
    SEVEN_D_PCT=$(jq -r '.seven_day.utilization // empty' "$USAGE_CACHE" 2>/dev/null | cut -d. -f1)
    SEVEN_D_RESET=$(jq -r '.seven_day.resets_at // empty' "$USAGE_CACHE" 2>/dev/null)

    if [ -n "$FIVE_H_PCT" ]; then
        # Calculate 5h reset countdown
        RESET_5H_STR=""
        if [ -n "$FIVE_H_RESET" ]; then
            RESET_EPOCH=$(date -d "$FIVE_H_RESET" +%s 2>/dev/null || echo 0)
            NOW_EPOCH=$(date +%s)
            DIFF=$(( RESET_EPOCH - NOW_EPOCH ))
            if [ "$DIFF" -gt 0 ]; then
                RESET_H=$(( DIFF / 3600 ))
                RESET_M=$(( (DIFF % 3600) / 60 ))
                RESET_5H_STR=" ↻ ${RESET_H}h${RESET_M}m"
            fi
        fi

        # Calculate 7d reset countdown
        RESET_7D_STR=""
        if [ -n "$SEVEN_D_RESET" ]; then
            RESET_EPOCH=$(date -d "$SEVEN_D_RESET" +%s 2>/dev/null || echo 0)
            NOW_EPOCH=$(date +%s)
            DIFF=$(( RESET_EPOCH - NOW_EPOCH ))
            if [ "$DIFF" -gt 0 ]; then
                DAYS=$(( DIFF / 86400 ))
                HOURS=$(( (DIFF % 86400) / 3600 ))
                RESET_7D_STR=" ↻ ${DAYS}d${HOURS}h"
            fi
        fi

        # Color based on usage
        if [ "$FIVE_H_PCT" -ge 80 ]; then U5_COLOR="$RED"
        elif [ "$FIVE_H_PCT" -ge 50 ]; then U5_COLOR="$YELLOW"
        else U5_COLOR="$GREEN"; fi

        if [ -n "$SEVEN_D_PCT" ]; then
            if [ "$SEVEN_D_PCT" -ge 80 ]; then U7_COLOR="$RED"
            elif [ "$SEVEN_D_PCT" -ge 50 ]; then U7_COLOR="$YELLOW"
            else U7_COLOR="$GREEN"; fi
            USAGE_LINE=" | 5h: ${U5_COLOR}${FIVE_H_PCT}%${RESET}${DIM}${RESET_5H_STR}${RESET} | 7d: ${U7_COLOR}${SEVEN_D_PCT}%${RESET}${DIM}${RESET_7D_STR}${RESET}"
        else
            USAGE_LINE=" | 5h: ${U5_COLOR}${FIVE_H_PCT}%${RESET}${DIM}${RESET_5H_STR}${RESET}"
        fi
    fi
fi

# ── Plan detection ────────────────────────────────────────────────
MAGENTA='\033[35m'
PLAN_STR=""
CREDS_FILE="$HOME/.claude/.credentials.json"
if [ -f "$CREDS_FILE" ]; then
    SUB_TYPE=$(jq -r '.claudeAiOauth.subscriptionType // empty' "$CREDS_FILE" 2>/dev/null)
    RATE_TIER=$(jq -r '.claudeAiOauth.rateLimitTier // empty' "$CREDS_FILE" 2>/dev/null)
    if [ -n "$SUB_TYPE" ]; then
        PLAN_NAME="$(echo "$SUB_TYPE" | sed 's/^./\U&/')"
        # Extract multiplier from rateLimitTier (e.g. "default_claude_max_20x" -> "20x")
        if [[ "$RATE_TIER" =~ ([0-9]+x)$ ]]; then
            PLAN_NAME="${PLAN_NAME} ${BASH_REMATCH[1]}"
        fi
        PLAN_STR=" ${MAGENTA}${PLAN_NAME}${RESET}"
    fi
else
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        PLAN_STR=" ${MAGENTA}API${RESET}"
    fi
fi

echo -e "${CYAN}[$MODEL]${RESET}${PLAN_STR} 📁 ${DIR##*/}$BRANCH"
COST_FMT=$(printf '$%.2f' "$COST")
echo -e "${BAR_COLOR}${BAR}${RESET} ${PCT}% | ${YELLOW}${COST_FMT}${RESET} | ⏱️ ${MINS}m ${SECS}s${USAGE_LINE}"
