#!/bin/bash
set -e

KIOSK_DIR="/home/pi/kiosk"
mkdir -p "$KIOSK_DIR"

echo "Installing dependencies..."
sudo apt update
sudo apt install -y python3-flask python3-tk unclutter || sudo pip3 install --break-system-packages flask

CHROMIUM=$(command -v chromium-browser || command -v chromium || echo chromium-browser)

# --- launcher.html: the Android-style home screen ---
cat > "$KIOSK_DIR/launcher.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=800, initial-scale=1.0, user-scalable=no">
<title>Home</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; -webkit-user-select: none; user-select: none; -webkit-tap-highlight-color: transparent; }
  html, body { width: 800px; height: 480px; overflow: hidden; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    background: linear-gradient(160deg, #1a1c2e 0%, #0d0e1a 100%);
    color: #fff;
    height: 480px;
    display: flex;
    flex-direction: column;
  }
  .statusbar {
    height: 28px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 14px;
    font-size: 0.78rem;
    color: #dcdcf0;
    flex-shrink: 0;
  }
  .grid {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 48px;
  }
  .app { display: flex; flex-direction: column; align-items: center; gap: 10px; cursor: pointer; }
  .icon {
    width: 96px; height: 96px; border-radius: 26px;
    display: flex; align-items: center; justify-content: center;
    font-size: 2.4rem;
    transition: transform 0.12s ease;
    box-shadow: 0 6px 16px rgba(0,0,0,0.35);
  }
  .app:active .icon { transform: scale(0.9); }
  .icon.stream { background: linear-gradient(145deg, #ff5f6d, #b2265f); }
  .icon.ivr { background: linear-gradient(145deg, #4facfe, #2b5fc7); }
  .label { font-size: 0.85rem; color: #e6e6f5; letter-spacing: 0.01em; }
  .hint { text-align: center; color: #55597a; font-size: 0.7rem; padding-bottom: 10px; }
</style>
</head>
<body>
<div class="statusbar">
  <div id="clock">--:--</div>
  <div>raspberrypi</div>
</div>
<div class="grid">
  <div class="app" onclick="openApp('stream')">
    <div class="icon stream">🎙️</div>
    <div class="label">Live Stream</div>
  </div>
  <div class="app" onclick="openApp('ivr')">
    <div class="icon ivr">📞</div>
    <div class="label">IVR Hotline</div>
  </div>
</div>
<div class="hint">Tap an app to open &middot; tap the home button to come back</div>
<script>
  function updateClock() {
    const d = new Date();
    document.getElementById('clock').textContent =
      String(d.getHours()).padStart(2,'0') + ':' + String(d.getMinutes()).padStart(2,'0');
  }
  updateClock();
  setInterval(updateClock, 15000);
  function openApp(key) { fetch('/open?app=' + key).catch(() => {}); }
</script>
</body>
</html>
EOF

# --- launcher-server.py: tiny local Flask app that (re)launches Chromium per "app" ---
cat > "$KIOSK_DIR/launcher-server.py" << EOF
from flask import Flask, request, send_from_directory
import subprocess, os, time

app = Flask(__name__)
KIOSK_DIR = os.path.dirname(os.path.abspath(__file__))
CHROMIUM = "$CHROMIUM"

APPS = {
    'home':   {'url': 'http://127.0.0.1:5050/launcher.html', 'scale': None},
    'stream': {'url': 'https://live-stream-it4q.onrender.com/s/q4625p/screen', 'scale': None},
    'ivr':    {'url': 'https://ivr.teltech.info/portal/extensions/', 'scale': '0.65'},
}

def launch(key):
    cfg = APPS[key]
    subprocess.run(['pkill', '-f', 'chromium'], check=False)
    time.sleep(1)
    args = [CHROMIUM, '--app=' + cfg['url'], '--window-size=800,480',
            '--window-position=0,0', '--noerrdialogs', '--disable-infobars',
            '--disable-session-crashed-bubble']
    if cfg['scale']:
        args.append('--force-device-scale-factor=' + cfg['scale'])
    subprocess.Popen(args)

@app.route('/launcher.html')
def launcher():
    return send_from_directory(KIOSK_DIR, 'launcher.html')

@app.route('/open')
def open_app():
    key = request.args.get('app', 'home')
    if key in APPS:
        launch(key)
        return 'ok'
    return 'unknown app', 400

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=5050)
EOF

# --- home-button.py: small always-on-top circular "home" button ---
cat > "$KIOSK_DIR/home-button.py" << 'EOF'
import tkinter as tk
import urllib.request

def go_home():
    try:
        urllib.request.urlopen('http://127.0.0.1:5050/open?app=home', timeout=2)
    except Exception:
        pass

root = tk.Tk()
root.overrideredirect(True)
root.attributes('-topmost', True)
w, h = 70, 70
root.geometry(f'{w}x{h}+{(800-w)//2}+{480-h-4}')
try:
    root.attributes('-alpha', 0.55)
except Exception:
    pass
canvas = tk.Canvas(root, width=w, height=h, bg='black', highlightthickness=0)
canvas.pack()
canvas.create_oval(4, 4, w-4, h-4, fill='#333333', outline='#888888', width=2)
canvas.bind('<Button-1>', lambda e: go_home())
root.mainloop()
EOF

# --- start-kiosk.sh: orchestrates startup order ---
# Always runs the GUI pieces as the 'pi' user against the real display :0,
# regardless of whether this script itself is invoked as root or via SSH.
# (Quoted 'EOF' below so nothing is expanded now -- it's expanded when
# start-kiosk.sh itself runs, on the Pi's real desktop session.)
cat > "$KIOSK_DIR/start-kiosk.sh" << 'EOF'
#!/bin/bash
KIOSK_DIR="/home/pi/kiosk"
CHROMIUM=$(command -v chromium-browser || command -v chromium || echo chromium-browser)
cd "$KIOSK_DIR"
runasp() { sudo -u pi env DISPLAY=:0 XAUTHORITY=/home/pi/.Xauthority "$@"; }
runasp pkill -f launcher-server.py 2>/dev/null
runasp pkill -f home-button.py 2>/dev/null
runasp pkill -f chromium 2>/dev/null
sleep 1
runasp unclutter -idle 0.5 -root &
runasp python3 launcher-server.py &
sleep 2
runasp python3 home-button.py &
sleep 1
runasp "$CHROMIUM" --no-sandbox --app=http://127.0.0.1:5050/launcher.html --window-size=800,480 --window-position=0,0 --noerrdialogs --disable-infobars --disable-session-crashed-bubble &
EOF
chmod +x "$KIOSK_DIR/start-kiosk.sh"

# --- autostart entry ---
mkdir -p /home/pi/.config/autostart
cat > /home/pi/.config/autostart/kiosk.desktop << EOF
[Desktop Entry]
Type=Application
Name=Kiosk
Exec=$KIOSK_DIR/start-kiosk.sh
EOF

chown -R pi:pi "$KIOSK_DIR" /home/pi/.config/autostart 2>/dev/null || true

echo ""
echo "Setup complete. Starting the kiosk now..."
"$KIOSK_DIR/start-kiosk.sh"
echo "Done. It will also auto-start on every boot from now on."
