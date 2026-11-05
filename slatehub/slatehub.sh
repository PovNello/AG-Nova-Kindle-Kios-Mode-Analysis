#!/bin/sh
# Name: Open SlateHub
# Author: Alessandro Grano
# DontUseFBInk
# Last-opened: 0

SCRIPT_PATH="/mnt/us/documents/slatehub/slatehub.sh"
SLATEHUB_DIR="/mnt/us/documents/slatehub"
PIDFILE="$SLATEHUB_DIR/slatehub.pid"
URL="https://slatehub.agnovaindustries.com/dashboard?k=345c20e163427dd0023a860896306687"
CHROME_JSON='{"appId":"com.lab126.browser","topNavBar":{"template":"blank","buttons":[]}}'

mkdir -p "$SLATEHUB_DIR"

# Step 1: Detach from Library launcher so the launcher exit does not pull focus away
if [ "$1" != "--detached" ]; then
  # If a previous SlateHub instance is running, stop only its specific PID
  if [ -f "$PIDFILE" ]; then
    OLD_PID=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$OLD_PID" ] && kill "$OLD_PID" 2>/dev/null
    rm -f "$PIDFILE"
  fi

  # Spawn the detached background instance without modifying the file on flash
  nohup /bin/sh "$SCRIPT_PATH" --detached >/dev/null 2>&1 < /dev/null &
  exit 0
fi

# Step 2: Running in detached session
echo "$$" > "$PIDFILE"

# Allow the Library launcher 2 seconds to complete its return to Home screen
sleep 2

# Keep screen awake
lipc-set-prop -i com.lab126.powerd preventScreenSaver 1 2>/dev/null

# Launch browser with destination URL
lipc-set-prop com.lab126.appmgrd start "app://com.lab126.browser#going?url=$URL"

# Wait for browser to take foreground (up to 8 seconds)
for i in 1 2 3 4 5 6 7 8; do
  ACTIVE=$(lipc-get-prop com.lab126.appmgrd activeApp 2>/dev/null)
  if [ "$ACTIVE" = "com.lab126.browser" ]; then
    break
  fi
  sleep 1
done

# Explicitly command browser to load our URL (bypasses Google consent / cached last-page fallback)
lipc-set-prop -s com.lab126.browser loadURL "$URL" 2>/dev/null

# Apply blank chrome
lipc-set-prop -s com.lab126.chromebar configureChrome "$CHROME_JSON" 2>/dev/null

# Small pause then re-apply blank chrome in case browser finished rendering after initial configuration
sleep 2
lipc-set-prop -s com.lab126.chromebar configureChrome "$CHROME_JSON" 2>/dev/null

# Step 3: Watchdog loop to keep chrome clean and handle intentional exit
MISSED=0
while [ -f "$PIDFILE" ]; do
  ACTIVE=$(lipc-get-prop com.lab126.appmgrd activeApp 2>/dev/null)

  if [ "$ACTIVE" = "com.lab126.browser" ]; then
    MISSED=0
    lipc-set-prop -s com.lab126.chromebar configureChrome "$CHROME_JSON" 2>/dev/null
  else
    MISSED=$((MISSED + 1))
    # If the user navigated away (e.g. pulled down settings menu or pressed Home)
    # for 2 consecutive checks (4 seconds), trigger a clean exit
    if [ $MISSED -ge 2 ]; then
      /bin/sh "$SLATEHUB_DIR/slatehub_stop.sh"
      break
    fi
  fi
  sleep 2
done

exit 0
