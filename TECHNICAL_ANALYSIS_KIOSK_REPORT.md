# Technical Analysis & Device Investigation Report: Kindle Paperwhite 11th Gen (5.19.2) Kiosk Implementation

- **Device**: Kindle Paperwhite 11th Generation (PW5, Malbec / Bellatrix hardware)
- **Kernel**: `Linux kindle 4.9.77-lab126 #1 SMP PREEMPT armv7l`
- **Firmware Version**: `5.19.2` (Build: `040-juno_1902_malbec_bellatrix-467076`, `com.lab126.eink.malbec.os`)
- **Objective**: Fullscreen, standalone kiosk dashboard running SlateHub (`https://slatehub.agnovaindustries.com/dashboard?...`)
- **Date of Investigation**: November 4, 2026
- **Author**: Alessandro Grano / DeepMind Pair Programming Session

### SSH Connection Details
- **Host / IP**: `192.168.1.64`
- **Port**: `22`
- **User**: `root`
- **Authentication**: Key-based (stored locally at `~/.ssh/id_ed25519` / `C:\Users\grano\.ssh\id_ed25519`, no password required)
- **Direct Connect Command**: `ssh root@192.168.1.64`

---

## 1. Executive Summary

Attempts to deploy standalone browser kiosks on modern Kindle firmwares (5.16+ to 5.19.x) using legacy scriptlets like `kindle-shortcut-browser` consistently fail or leave the device with a blank/frozen display. 

Through direct root investigation, system tracing, and Hermes bytecode inspection on this Kindle Paperwhite 11th Gen running **5.19.2**, we isolated the exact failure mechanisms and developed a production-ready native implementation. Rather than terminating the Kindle display subsystem, the new solution leverages Lab126 Inter-Process Communication (**LIPC**) services (`appmgrd`, `chromebar`, and `powerd`) to launch the native Chromium instance within its Amazon chroot sandbox, strip all chrome controls, keep the screen permanently awake, and provide an instant one-tap exit mechanism.

---

## 2. Failure Analysis of Legacy Implementations (`kindle-shortcut-browser`)

Analyzing `/mnt/us/kiosk.log` and the system internals revealed several reasons why legacy approaches fail on firmware 5.19.2:

### A. The GLIBC 2.25 Chroot Isolation
The legacy `shortcut_browser.sh` script attempts to stop the system GUI and execute Chromium directly in the root filesystem:
```sh
nohup /usr/bin/chromium/bin/kindle_browser ...
```
When executed on 5.19.2, the process immediately aborted with:
```text
/usr/bin/chromium/bin/kindle_browser: /lib/libc.so.6: version `GLIBC_2.25' not found (required by /usr/bin/chromium/bin/libchromium.so)
```
**Root Cause**: In firmware 5.19.x, Amazon updated Chromium to require modern glibc symbols (`GLIBC_2.25`). The main root filesystem (`/lib`) retains older system libraries. Amazon isolated the modern toolchain and Chromium dependencies inside a dedicated jail located at `/chroot`. 

Inspect `/usr/bin/browser` on the device:
```sh
exec chroot /chroot /usr/bin/chromium/bin/kindle_browser \
     --no-zygote --no-sandbox --single-process --skia-resource-cache-limit-mb=64 \
     --disable-gpu --in-process-gpu --disable-gpu-sandbox --disable-gpu-compositing \
     --content-shell-hide-toolbar --content-shell-host-window-cord=0,215 \
     ...
```
Any attempt to invoke `kindle_browser` outside `/chroot` fails at the dynamic linker stage.

### B. Display Compositor Disruption (`lab126_gui` vs Mutter/Decanter)
Legacy scripts stop the GUI via:
```sh
stop lab126_gui
```
On modern Kindle OS versions, the Kindle user interface (`KPPMainApp`, React Native/Hermes, Mutter window compositor) manages the frame-buffer surface, input dispatch, and power states. Stopping `lab126_gui` shuts down the display server, preventing even a properly compiled browser from presenting surfaces to the e-ink screen without manual fbink/X11 initialization.

### C. Self-Modifying Script Race Condition (`sed -i "$0"`)
The library scriptlets included:
```sh
timestamp=$(date +%s)
sed -i "s/^# Last-opened:.*/# Last-opened: $timestamp/" "$0"
```
Under BusyBox `ash` (the default shell at `/bin/sh`), running `sed -i` on `$0` modifies the running script file on flash while the shell's execution buffer is open. This alters the file inode/offset and triggers:
```text
syntax error: unexpected end of file (expecting "done")
```
This was resolved by decoupling the library timestamp update into an asynchronous deferred background task.

---

## 3. The Modern Native Architecture (LIPC)

Modern Kindle firmware features a robust message bus: **LIPC (Lab126 Inter-Process Communication)**. Working *with* Amazon's system daemons rather than fighting them provides complete stability.

```
+-----------------------------------------------------------------------+
|                             Kindle OS 5.19.2                          |
|                                                                       |
|  +--------------------+   LIPC "start"    +------------------------+  |
|  | com.lab126.appmgrd | ----------------> |  /chroot (Chromium)    |  |
|  +--------------------+                   |  User: framework:9000  |  |
|           |                               +------------------------+  |
|           | activeApp polling                          |              |
|           v                                            v              |
|  +--------------------+   configureChrome +------------------------+  |
|  | com.lab126.chromebar| ---------------> | Top Bar (Y: 0-215px)   |  |
|  |                    |                   | Content Shell (Y: 215+)|  |
|  +--------------------+                   +------------------------+  |
|                                                                       |
|  +--------------------+   preventScreenSaver                          |
|  | com.lab126.powerd  | ----------------> [ Display stays awake ]     |
|  +--------------------+                                               |
+-----------------------------------------------------------------------+
```

### 1. Browser Lifecycle via `com.lab126.appmgrd` & `com.lab126.browser`
The Application Manager daemon controls application lifecycles cleanly:
- **Launch with destination URL**:
  ```sh
  lipc-set-prop com.lab126.appmgrd start "app://com.lab126.browser#going?url=https://..."
  ```
- **Crucial Discovery on URLs & Google Consent Prevention**:
  1. Passing raw unencoded URLs prevents the browser from treating the input as a search query.
  2. In addition, when Chromium boots or switches, it can fall back to `getLastOpenPage` or default search (`consent.google.com`). We discovered the native LIPC property on the active browser service:
     ```sh
     lipc-set-prop -s com.lab126.browser loadURL "https://..."
     ```
     Sending `loadURL` immediately after the browser reaches the foreground forces Chromium to navigate directly to the dashboard, permanently bypassing any cached consent pages or search redirects.
- **Inspect current foreground app**:
  ```sh
  lipc-get-prop com.lab126.appmgrd activeApp
  # Returns: com.lab126.browser (when open) or com.lab126.KPPMainApp (Home/Library)
  ```
- **Stop browser instantly & restore Home cleanly**:
  ```sh
  lipc-set-prop com.lab126.appmgrd stop com.lab126.browser
  ```
  *No GUI restarts, no eips clearing hacks, zero flicker.*

### 2. Chrome Removal via `com.lab126.chromebar`
The top navigation bar is controlled by the `com.lab126.chromebar` service through the `configureChrome` property.

By inspecting `lastChromeConfig` and Amazon's Hermes bytecode in `/app/bin/KPPMainApp`, we decoded the full schema:
- Normal browser chrome renders:
  - `template`: `"searchBar"`
  - `buttonsConfig`: `[KPP_BACK_APP, KPP_FORWARD_APP, KPP_REFRESH, KPP_MORE, KPP_CLOSE_BROWSER]`
- **The Kiosk Discovery**:
  Passing:
  ```json
  {"appId":"com.lab126.browser","topNavBar":{"template":"blank","buttons":[]}}
  ```
  Completely removes:
  - The URL input bar
  - The search text field
  - Back/Forward navigation arrows
  - The Refresh icon
  - The More options menu
  - The Close button

#### Note on Top Bar Coordinates:
In `/usr/bin/browser`, Chromium is started with `--content-shell-host-window-cord=0,215`. The Kindle display manager reserves the first 215 vertical pixels for the system status bar (clock, battery, Wi-Fi) and the top bar area. The `template: "blank"` configuration renders this band completely white/empty, allowing the SlateHub dashboard to display directly underneath the system status icons.

### 3. Display Sleep Lock via `com.lab126.powerd`
By default, Kindle OS dims and puts the display to sleep after 10 minutes (`screenSaverTimeout: 600`).
- **Hold Screen Awake**:
  ```sh
  lipc-set-prop -i com.lab126.powerd preventScreenSaver 1
  ```
- **Restore Default Sleep Behavior**:
  ```sh
  lipc-set-prop -i com.lab126.powerd preventScreenSaver 0
  ```

---

## 4. Production Script Specifications

The production scripts reside on the Kindle user partition at `/mnt/us/documents/slatehub/` and are mirrored locally in the project repository under `slatehub/`.

### A. Launcher Script: `slatehub.sh` (`Open SlateHub`)
Key operational features:
1. **Library Launcher Detachment**: 
   When a scriptlet is opened from the Kindle Library (`KPPMainApp`), the library's document launcher awaits script completion. Exiting immediately without detaching causes `KPPMainApp` to steal focus back over the newly opened browser. `slatehub.sh` detaches via:
   ```sh
   nohup /bin/sh "$SCRIPT_PATH" --detached >/dev/null 2>&1 < /dev/null &
   exit 0
   ```
   The parent exits to satisfy the document runner, while the detached child sleeps for 2 seconds to let the Library finish its transition, then takes over the display.
2. **Direct URL Enforcement**: Calls `lipc-set-prop -s com.lab126.browser loadURL "$URL"` once the browser initializes, eliminating the Google consent fallback.
3. **Elimination of In-Flight Flash Writes (`sed -i`)**: Updating `# Last-opened:` inside the running script file while BusyBox `ash` executes it corrupts the shell's flash file read buffer. All `# Last-opened:` updates are deferred exclusively to `slatehub_stop.sh` when returning to the Library.
4. **Kiosk Watchdog Loop**: Monitors `lipc-get-prop com.lab126.appmgrd activeApp` every 2 seconds. Re-applies the blank chrome configuration (`template: "blank"`).
5. **Clean Multi-Check Exit**: Requires 2 consecutive checks outside `com.lab126.browser` before triggering `slatehub_stop.sh`, preventing false-positive exits during minor window transitions while cleanly detecting swipe-down to Settings or Home.

```sh
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

if [ "$1" != "--detached" ]; then
  if [ -f "$PIDFILE" ]; then
    OLD_PID=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$OLD_PID" ] && kill "$OLD_PID" 2>/dev/null
    rm -f "$PIDFILE"
  fi
  nohup /bin/sh "$SCRIPT_PATH" --detached >/dev/null 2>&1 < /dev/null &
  exit 0
fi

echo "$$" > "$PIDFILE"
sleep 2

lipc-set-prop -i com.lab126.powerd preventScreenSaver 1 2>/dev/null
lipc-set-prop com.lab126.appmgrd start "app://com.lab126.browser#going?url=$URL"

for i in 1 2 3 4 5 6 7 8; do
  ACTIVE=$(lipc-get-prop com.lab126.appmgrd activeApp 2>/dev/null)
  [ "$ACTIVE" = "com.lab126.browser" ] && break
  sleep 1
done

lipc-set-prop -s com.lab126.browser loadURL "$URL" 2>/dev/null
lipc-set-prop -s com.lab126.chromebar configureChrome "$CHROME_JSON" 2>/dev/null
sleep 2
lipc-set-prop -s com.lab126.chromebar configureChrome "$CHROME_JSON" 2>/dev/null

MISSED=0
while [ -f "$PIDFILE" ]; do
  ACTIVE=$(lipc-get-prop com.lab126.appmgrd activeApp 2>/dev/null)
  if [ "$ACTIVE" = "com.lab126.browser" ]; then
    MISSED=0
    lipc-set-prop -s com.lab126.chromebar configureChrome "$CHROME_JSON" 2>/dev/null
  else
    MISSED=$((MISSED + 1))
    if [ $MISSED -ge 2 ]; then
      /bin/sh "$SLATEHUB_DIR/slatehub_stop.sh"
      break
    fi
  fi
  sleep 2
done

exit 0
```

### B. Exit Script: `slatehub_stop.sh` (`Stop SlateHub`)
Key operational features:
1. Targets and terminates only the specific SlateHub watchdog process ID recorded in `slatehub.pid`.
2. Restores default power management sleep timeout (`preventScreenSaver=0`).
3. Closes browser via `lipc-set-prop com.lab126.appmgrd stop com.lab126.browser` and returns user cleanly to Home.
4. Safely updates `# Last-opened:` timestamps on both scriptlets to place them at the top of the Library when the user returns.

```sh
#!/bin/sh
# Name: Stop SlateHub
# Author: Alessandro Grano
# DontUseFBInk
# Last-opened: 0

SLATEHUB_DIR="/mnt/us/documents/slatehub"
PIDFILE="$SLATEHUB_DIR/slatehub.pid"

if [ -f "$PIDFILE" ]; then
  PID=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  rm -f "$PIDFILE"
fi

lipc-set-prop -i com.lab126.powerd preventScreenSaver 0 2>/dev/null
lipc-set-prop com.lab126.appmgrd stop com.lab126.browser 2>/dev/null

NOW=$(date +%s)
sed -i "s/^# Last-opened:.*/# Last-opened: $NOW/" "$SLATEHUB_DIR/slatehub.sh" 2>/dev/null
sed -i "s/^# Last-opened:.*/# Last-opened: $NOW/" "$SLATEHUB_DIR/slatehub_stop.sh" 2>/dev/null

exit 0
```

---

## 5. Verification & Health Check Commands

When connecting via SSH (`ssh root@192.168.1.64`):

```sh
# 1. Check if the browser is active
lipc-get-prop com.lab126.appmgrd activeApp

# 2. Check if the display sleep lock is active
lipc-get-prop com.lab126.powerd preventScreenSaver

# 3. Check the running watchdog process
ps -ef | grep slatehub

# 4. View live SlateHub activity logs
tail -f /mnt/us/documents/slatehub/slatehub.log

# 5. Capture a live framebuffer screenshot to /mnt/us/
/usr/sbin/screenshot -f /mnt/us/screen.png
```
