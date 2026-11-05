#!/bin/sh
# Name: Stop SlateHub
# Author: Alessandro Grano
# DontUseFBInk
# Last-opened: 0

SLATEHUB_DIR="/mnt/us/documents/slatehub"
PIDFILE="$SLATEHUB_DIR/slatehub.pid"

# Stop watchdog process
if [ -f "$PIDFILE" ]; then
  PID=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  rm -f "$PIDFILE"
fi

# Restore normal sleep
lipc-set-prop -i com.lab126.powerd preventScreenSaver 0 2>/dev/null

# Close browser and return to Home
lipc-set-prop com.lab126.appmgrd stop com.lab126.browser 2>/dev/null

# Update timestamps on both scriptlets to keep them at the top of the Library
NOW=$(date +%s)
sed -i "s/^# Last-opened:.*/# Last-opened: $NOW/" "$SLATEHUB_DIR/slatehub.sh" 2>/dev/null
sed -i "s/^# Last-opened:.*/# Last-opened: $NOW/" "$SLATEHUB_DIR/slatehub_stop.sh" 2>/dev/null

exit 0
