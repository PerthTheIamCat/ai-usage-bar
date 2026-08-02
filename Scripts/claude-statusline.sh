#!/bin/zsh
# Claude Code statusLine bridge for AI Usage Bar.
# Claude Code sends JSON on stdin; the app stores only rate_limits locally and
# prints a compact status line back to Claude Code.
set -u

APP_BIN="${AI_USAGE_BAR_BIN:-/Applications/AIUsageBar.app/Contents/MacOS/AIUsageBar}"
if [[ ! -x "$APP_BIN" ]]; then
    print -u2 "AIUsageBar statusline bridge: app not found at $APP_BIN"
    exit 0
fi

exec "$APP_BIN" --claude-statusline
