#!/bin/bash
set -e

echo "Cleaning up the old launcher/home-button setup..."
sudo -u pi pkill -f launcher-server.py 2>/dev/null || true
sudo -u pi pkill -f home-button.py 2>/dev/null || true
sudo -u pi pkill -f chromium 2>/dev/null || true
rm -f /home/pi/.config/autostart/kiosk.desktop

CHROMIUM=$(command -v chromium-browser || command -v chromium || echo chromium-browser)
DESKTOP_DIR="/home/pi/Desktop"
mkdir -p "$DESKTOP_DIR"

make_icon() {
  local file="$1"; local name="$2"; local url="$3"; local scale="$4"
  local scaleflag=""
  if [ -n "$scale" ]; then scaleflag="--force-device-scale-factor=$scale"; fi
  cat > "$DESKTOP_DIR/$file" << EOF
[Desktop Entry]
Type=Application
Name=$name
Comment=$name
Exec=$CHROMIUM --app=$url --window-size=800,480 --window-position=0,0 --noerrdialogs --disable-infobars --disable-session-crashed-bubble --use-fake-ui-for-media-stream $scaleflag
Terminal=false
Categories=Network;
EOF
  chmod +x "$DESKTOP_DIR/$file"
  gio set "$DESKTOP_DIR/$file" metadata::trusted true 2>/dev/null || true
}

make_icon "live-stream.desktop" "Live Stream" "https://live-stream-it4q.onrender.com/s/q4625p/screen" ""
make_icon "ivr-quick-record.desktop" "IVR Quick Record" "https://ivr.teltech.info/portal/extensions/" "0.85"
make_icon "ivr-admin.desktop" "IVR Admin (Full)" "https://ivr.teltech.info/portal/extensions/" "0.65"

chown -R pi:pi "$DESKTOP_DIR" /home/pi/.config/autostart 2>/dev/null || true

echo ""
echo "Done. Three desktop icons are ready:"
echo "  - Live Stream"
echo "  - IVR Quick Record  (bigger, for adding/recording to a folder)"
echo "  - IVR Admin (Full)  (zoomed out, for everything else)"
echo "You may need to double-tap each icon once and confirm 'Execute' the first time Raspberry Pi OS asks about an untrusted launcher."
