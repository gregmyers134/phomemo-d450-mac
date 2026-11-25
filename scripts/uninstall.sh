#!/bin/bash
# Removes what scripts/install.sh installed: the launch agent, the app and
# the two print queues. Logs and settings in your Library folder are kept.
#
#   scripts/uninstall.sh               an install for one user
#   scripts/uninstall.sh --all-users   an install for all users (asks for an administrator password)

set -euo pipefail

BUNDLE_ID="io.github.gregmyers134.d450mac"

ALL_USERS=0
case "${1:-}" in
    "") ;;
    --all-users) ALL_USERS=1 ;;
    *) echo "usage: scripts/uninstall.sh [--all-users]" >&2; exit 2 ;;
esac

if [ "$ALL_USERS" = 1 ]; then
    APP="/Applications/D450 Print Service.app"
    AGENT="/Library/LaunchAgents/$BUNDLE_ID.plist"
    AS_ADMIN="sudo"
else
    APP="$HOME/Applications/D450 Print Service.app"
    AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
    AS_ADMIN=""
fi

launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
pkill -x d450d 2>/dev/null || true
$AS_ADMIN rm -f "$AGENT"
$AS_ADMIN rm -rf "$APP"
for queue in D450 D450_all; do
    if lpstat -p "$queue" >/dev/null 2>&1; then lpadmin -x "$queue"; fi
done
echo "Removed. Other users who are logged in keep their running copy until they log out."
