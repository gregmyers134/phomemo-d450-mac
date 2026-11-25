#!/bin/bash
# Builds the D450 print service from source and installs it on this Mac so
# that it starts at login. Nothing is downloaded.
#
#   scripts/install.sh               for the user running it
#   scripts/install.sh --all-users   for every user of this Mac (asks for an administrator password)
#
# It installs three things:
#   1. "D450 Print Service.app", holding the d450d program
#   2. a launch agent that starts it at login
#   3. two print queues, D450 and D450_all, if they are not there yet
# scripts/uninstall.sh removes them again.

set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="io.github.gregmyers134.d450mac"
PORT=8631

ALL_USERS=0
case "${1:-}" in
    "") ;;
    --all-users) ALL_USERS=1 ;;
    *) echo "usage: scripts/install.sh [--all-users]" >&2; exit 2 ;;
esac

if [ "$(uname)" != "Darwin" ]; then echo "This installer is for macOS." >&2; exit 1; fi
if ! command -v swift >/dev/null; then
    echo "Swift is not installed. Install the Xcode Command Line Tools first:  xcode-select --install" >&2
    exit 1
fi

if [ "$ALL_USERS" = 1 ]; then
    APP_DIR="/Applications"
    AGENT_DIR="/Library/LaunchAgents"
    AS_ADMIN="sudo"
    echo "Installing for all users. You may be asked for an administrator password."
else
    APP_DIR="$HOME/Applications"
    AGENT_DIR="$HOME/Library/LaunchAgents"
    AS_ADMIN=""
fi
APP="$APP_DIR/D450 Print Service.app"
AGENT="$AGENT_DIR/$BUNDLE_ID.plist"

# One install per Mac user: either their own, or the one shared by all users.
if [ "$ALL_USERS" = 0 ] && [ -e "/Library/LaunchAgents/$BUNDLE_ID.plist" ]; then
    echo "The service is already installed for all users of this Mac." >&2
    echo "To update it, run:  scripts/install.sh --all-users" >&2
    exit 1
fi

echo "Building..."
swift build -c release --product d450d
BINARY="$(swift build -c release --show-bin-path)/d450d"

echo "Stopping any running copy..."
launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
pkill -x d450d 2>/dev/null || true
if [ "$ALL_USERS" = 1 ]; then
    # Replace this user's own install, if there is one, with the shared one.
    rm -f "$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
    rm -rf "$HOME/Applications/D450 Print Service.app"
fi

# Put the app together in a temporary folder, then move it into place.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/app/Contents/MacOS"
cp "$BINARY" "$STAGE/app/Contents/MacOS/d450d"
sed "s|@BUNDLE_ID@|$BUNDLE_ID|g" packaging/Info.plist > "$STAGE/app/Contents/Info.plist"
sed -e "s|@BUNDLE_ID@|$BUNDLE_ID|g" -e "s|@APP@|$APP|g" packaging/launch-agent.plist > "$STAGE/agent.plist"
# A local ("ad hoc") signature. macOS ties the Bluetooth permission to it.
codesign --force --sign - "$STAGE/app"

echo "Installing $APP"
$AS_ADMIN mkdir -p "$APP_DIR" "$AGENT_DIR"
$AS_ADMIN rm -rf "$APP"
$AS_ADMIN cp -R "$STAGE/app" "$APP"
$AS_ADMIN cp "$STAGE/agent.plist" "$AGENT"
if [ "$ALL_USERS" = 1 ]; then
    sudo chown -R root:wheel "$APP" "$AGENT"
    sudo chmod 644 "$AGENT"
fi

echo "Starting the service..."
launchctl bootstrap "gui/$(id -u)" "$AGENT"

# The queues are set up from what the service reports, so wait until it answers.
for _ in $(seq 1 30); do
    if curl -s -o /dev/null "http://localhost:$PORT/"; then break; fi
    sleep 1
done
if ! curl -s -o /dev/null "http://localhost:$PORT/"; then
    echo "The service did not start. See ~/Library/Logs/D450Mac/d450d.log" >&2
    exit 1
fi

add_queue() {   # name, path
    if lpstat -p "$1" >/dev/null 2>&1; then
        echo "Print queue $1 is already there."
    else
        echo "Adding print queue $1"
        lpadmin -p "$1" -E -v "ipp://localhost:$PORT$2" -m everywhere
    fi
}
add_queue D450 /ipp/print
add_queue D450_all /ipp/all

cat <<DONE

Installed. The service starts by itself at login.

macOS asks whether "D450 Print Service" may use Bluetooth. Click Allow.
Each user of this Mac is asked once, the first time the service starts for them.

Printers:  Phomemo D450 label printer          the label only
           Phomemo D450 label + rest of page   the label, then the rest of that page
Log:       ~/Library/Logs/D450Mac/d450d.log
Settings:  ~/Library/Application Support/D450Mac/config.json   (optional)
DONE
