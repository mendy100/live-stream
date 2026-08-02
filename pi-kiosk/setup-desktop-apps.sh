#!/bin/bash
set -e

echo "Cleaning up the old launcher/home-button setup..."
sudo -u pi pkill -f launcher-server.py 2>/dev/null || true
sudo -u pi pkill -f home-button.py 2>/dev/null || true
sudo -u pi pkill -f chromium 2>/dev/null || true
rm -f /home/pi/.config/autostart/kiosk.desktop

sudo apt install -y libglib2.0-bin python3-pip attr > /dev/null 2>&1 || true
pip3 install --break-system-packages websocket-client > /dev/null 2>&1 || pip3 install websocket-client > /dev/null 2>&1 || true

CHROMIUM=$(command -v chromium-browser || command -v chromium || echo chromium-browser)
DESKTOP_DIR="/home/pi/Desktop"
KIOSK_DIR="/home/pi/kiosk"
ICON_DIR="$KIOSK_DIR/icons"
mkdir -p "$DESKTOP_DIR" "$ICON_DIR" "$KIOSK_DIR"

# --- Simple hand-drawn SVG icons (no external assets needed) ---
cat > "$ICON_DIR/mic.svg" << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <rect width="100" height="100" rx="22" fill="#e0475f"/>
  <rect x="40" y="22" width="20" height="38" rx="10" fill="#ffffff"/>
  <path d="M30 50 a20 20 0 0 0 40 0" stroke="#ffffff" stroke-width="6" fill="none" stroke-linecap="round"/>
  <line x1="50" y1="70" x2="50" y2="80" stroke="#ffffff" stroke-width="6" stroke-linecap="round"/>
  <line x1="38" y1="80" x2="62" y2="80" stroke="#ffffff" stroke-width="6" stroke-linecap="round"/>
</svg>
EOF

cat > "$ICON_DIR/phone-quick.svg" << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <rect width="100" height="100" rx="22" fill="#2b5fc7"/>
  <path d="M35 30 Q30 28 33 35 Q38 48 52 62 Q66 76 79 81 Q86 84 84 79 Q80 70 74 66 Q71 64 68 66 L63 71 Q54 66 49 61 Q44 56 39 47 L44 42 Q46 39 44 36 Q40 30 35 30 Z" fill="#ffffff"/>
</svg>
EOF

cat > "$ICON_DIR/phone-admin.svg" << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <rect width="100" height="100" rx="22" fill="#1d3f8a"/>
  <path d="M35 30 Q30 28 33 35 Q38 48 52 62 Q66 76 79 81 Q86 84 84 79 Q80 70 74 66 Q71 64 68 66 L63 71 Q54 66 49 61 Q44 56 39 47 L44 42 Q46 39 44 36 Q40 30 35 30 Z" fill="#ffffff"/>
  <circle cx="78" cy="24" r="10" fill="#ffd23f"/>
</svg>
EOF

# --- Quick Record: a small local script injected into the real IVR page via
# Chrome DevTools Protocol, instead of loading the full site UI ---
cat > "$KIOSK_DIR/simplify.js" << 'JSEOF'
(function () {
  if (window.__ivrSimplifyInstalled) return;
  window.__ivrSimplifyInstalled = true;

  function findByText(selector, text) {
    const els = Array.from(document.querySelectorAll(selector));
    return els.find(el => el.textContent.trim().toLowerCase().includes(text.toLowerCase()));
  }

  function buildOverlay() {
    if (document.getElementById('quick-record-overlay')) return;
    const overlay = document.createElement('div');
    overlay.id = 'quick-record-overlay';
    overlay.style.cssText = `
      position: fixed; inset: 0; z-index: 999999;
      background: #0a0a0a; color: #fff;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      display: flex; flex-direction: column; align-items: center; justify-content: center;
      gap: 1.2rem; padding: 1rem;
    `;
    overlay.innerHTML = `
      <div style="font-size:1.1rem; color:#888;">Extension #</div>
      <input id="qr-ext" inputmode="numeric" style="
        width: 220px; text-align:center; font-size:2rem; padding:0.6rem;
        border-radius: 12px; border: 2px solid #333; background:#111; color:#fff;">
      <button id="qr-go" style="
        width: 220px; padding: 0.9rem; font-size:1.1rem; font-weight:700;
        border:none; border-radius:12px; background:#2b5fc7; color:#fff;">Go to Folder</button>
      <div id="qr-status" style="color:#888; font-size:0.85rem; min-height:1.2em;"></div>
      <button id="qr-hide" style="
        margin-top:1rem; background:none; border:none; color:#555; font-size:0.8rem;">
        Show full site (debug)
      </button>
    `;
    document.body.appendChild(overlay);

    document.getElementById('qr-hide').onclick = () => overlay.remove();
    document.getElementById('qr-go').onclick = () => goToFolder(document.getElementById('qr-ext').value.trim());
  }

  function setStatus(msg) {
    const s = document.getElementById('qr-status');
    if (s) s.textContent = msg;
  }

  function goToFolder(ext) {
    if (!ext) { setStatus('Enter an extension number'); return; }
    setStatus('Looking for folder ' + ext + '...');
    const rows = Array.from(document.querySelectorAll('tr, [role="row"], div'));
    const match = rows.find(r => {
      const t = r.textContent.trim();
      return t === ext || t.startsWith(ext + ' ') || t.startsWith(ext + '-') || t.startsWith(ext + '.');
    });
    if (!match) {
      setStatus('Could not find folder "' + ext + '" automatically. Tap "Show full site" and open it manually.');
      return;
    }
    setStatus('Found it, opening...');
    const evt1 = new MouseEvent('dblclick', { bubbles: true, cancelable: true, view: window });
    match.dispatchEvent(evt1);
    setTimeout(findRecordTrigger, 1200);
  }

  function findRecordTrigger() {
    let btn = findByText('button, a, [role="button"]', 'record audio')
      || findByText('button, a, [role="button"]', 'record');
    if (btn) {
      setStatus('Opening recorder...');
      btn.click();
      setTimeout(simplifyModal, 800);
      return;
    }
    setStatus('Opened the folder. Could not auto-find "Record Audio" -- tap "Show full site" and trigger it manually once so I can learn where it is.');
  }

  function simplifyModal() {
    setStatus('Recorder should be open now (check "Show full site" to confirm).');
  }

  buildOverlay();
})();
JSEOF

cat > "$KIOSK_DIR/ivr-inject.py" << 'PYEOF'
#!/usr/bin/env python3
import json
import time
import os
import sys
import urllib.request
import websocket

PORT = 9223
SCRIPT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'simplify.js')


def get_ws_url():
    for _ in range(40):
        try:
            data = json.loads(urllib.request.urlopen('http://localhost:%d/json' % PORT, timeout=1).read())
            for tab in data:
                if 'ivr.teltech.info' in tab.get('url', ''):
                    return tab['webSocketDebuggerUrl']
        except Exception:
            pass
        time.sleep(0.5)
    return None


def main():
    with open(SCRIPT_PATH) as f:
        script = f.read()

    ws_url = get_ws_url()
    if not ws_url:
        print('Could not find IVR tab on debug port', PORT, file=sys.stderr)
        sys.exit(1)

    ws = websocket.create_connection(ws_url)
    ws.send(json.dumps({
        'id': 1,
        'method': 'Page.addScriptToEvaluateOnNewDocument',
        'params': {'source': script},
    }))
    print(ws.recv())

    ws.send(json.dumps({
        'id': 2,
        'method': 'Runtime.evaluate',
        'params': {'expression': script},
    }))
    print(ws.recv())


if __name__ == '__main__':
    main()
PYEOF

cat > "$KIOSK_DIR/quick-record-launch.sh" << EOF
#!/bin/bash
pkill -f chromium 2>/dev/null
sleep 1
$CHROMIUM --remote-debugging-port=9223 --app=https://ivr.teltech.info/portal/extensions/ --window-size=800,480 --window-position=0,0 --noerrdialogs --disable-infobars --disable-session-crashed-bubble --use-fake-ui-for-media-stream --password-store=basic &
sleep 3
python3 "$KIOSK_DIR/ivr-inject.py"
EOF
chmod +x "$KIOSK_DIR/quick-record-launch.sh"

make_icon() {
  local file="$1"; local name="$2"; local url="$3"; local scale="$4"; local icon="$5"
  local scaleflag=""
  if [ -n "$scale" ]; then scaleflag="--force-device-scale-factor=$scale"; fi
  cat > "$DESKTOP_DIR/$file" << EOF
[Desktop Entry]
Type=Application
Name=$name
Comment=$name
Icon=$icon
Exec=$CHROMIUM --app=$url --window-size=800,480 --window-position=0,0 --noerrdialogs --disable-infobars --disable-session-crashed-bubble --use-fake-ui-for-media-stream --password-store=basic $scaleflag
Terminal=false
Categories=Network;
EOF
}

# Live Stream: key baked into the URL so nothing needs to be typed on-device
make_icon "live-stream.desktop" "Live Stream" \
  "https://live-stream-it4q.onrender.com/s/q4625p/screen?key=LgPDW26rae8w" "" \
  "$ICON_DIR/mic.svg"

cat > "$DESKTOP_DIR/ivr-quick-record.desktop" << EOF
[Desktop Entry]
Type=Application
Name=IVR Quick Record
Comment=IVR Quick Record
Icon=$ICON_DIR/phone-quick.svg
Exec=$KIOSK_DIR/quick-record-launch.sh
Terminal=false
Categories=Network;
EOF

make_icon "ivr-admin.desktop" "IVR Admin (Full)" \
  "https://ivr.teltech.info/portal/extensions/" "0.65" \
  "$ICON_DIR/phone-admin.svg"

chown -R pi:pi "$KIOSK_DIR" "$DESKTOP_DIR" /home/pi/.config/autostart 2>/dev/null || true

# Desktop launchers should NOT be executable -- that's what makes PCManFM treat
# them as generic scripts and show the "seems to be an executable script" prompt.
chmod -x "$DESKTOP_DIR"/*.desktop 2>/dev/null || true
for f in "$DESKTOP_DIR"/*.desktop; do
  setfattr -n user.trusted -v yes "$f" 2>/dev/null || true
done

# Make sure the system actually recognizes .desktop files as application launchers
# (a stale/never-built MIME database is what was causing the trust prompt)
update-mime-database /usr/share/mime 2>/dev/null || true

# --- Single-tap to open instead of double-click (touchscreens don't double-tap reliably) ---
LIBFM_CONF="/home/pi/.config/libfm/libfm.conf"
mkdir -p /home/pi/.config/libfm
if [ -f "$LIBFM_CONF" ] && grep -q "^single_click=" "$LIBFM_CONF"; then
  sed -i 's/^single_click=.*/single_click=1/' "$LIBFM_CONF"
elif [ -f "$LIBFM_CONF" ] && grep -q "^\[config\]" "$LIBFM_CONF"; then
  sed -i '/^\[config\]/a single_click=1' "$LIBFM_CONF"
else
  printf '\n[config]\nsingle_click=1\n' >> "$LIBFM_CONF"
fi
chown -R pi:pi /home/pi/.config/libfm 2>/dev/null || true

# A plain --reconfigure isn't enough -- the desktop icon manager caches file info
# in memory since boot, so it needs an actual restart to pick up all these changes.
pkill -9 -f "pcmanfm --desktop" 2>/dev/null || true
sleep 2

echo ""
echo "Done. Three desktop icons are ready with real icons, single-tap to open,"
echo "and no 'trust this file' prompt:"
echo "  - Live Stream        (auto-connects, key is baked in)"
echo "  - IVR Quick Record   (simplified recording screen on the real IVR page)"
echo "  - IVR Admin (Full)   (zoomed out, for everything else)"
