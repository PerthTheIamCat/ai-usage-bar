#!/bin/zsh
# Install the AI Usage Bar bridge without reading or overwriting Claude Code
# settings. The statusLine entry is printed for the user to merge manually.
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
USER_HOME="${HOME:?HOME is not set}"
CLAUDE_DIR="$USER_HOME/.claude"
BRIDGE="$CLAUDE_DIR/ai-usage-bar-statusline.sh"
APP_BIN="${AI_USAGE_BAR_BIN:-/Applications/AIUsageBar.app/Contents/MacOS/AIUsageBar}"

if [[ ! -x "$APP_BIN" ]]; then
    print -u2 "AIUsageBar.app was not found at $APP_BIN"
    print -u2 "Set AI_USAGE_BAR_BIN to the app executable and run this script again."
    exit 1
fi

mkdir -p "$CLAUDE_DIR"
install -m 755 "$PROJECT_DIR/Scripts/claude-statusline.sh" "$BRIDGE"

print "Installed Claude Code statusLine bridge: $BRIDGE"
print "The installer does not modify ~/.claude/settings.json."
print "Add this top-level entry, or merge the command into your existing statusLine:"
print "  \"statusLine\": {\"type\": \"command\", \"command\": \"$BRIDGE\"}"
print "Restart Claude Code, then AI Usage Bar will read local rate-limit snapshots."
