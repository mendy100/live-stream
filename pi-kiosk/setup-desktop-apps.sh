#!/bin/bash
set -e

echo "Cleaning up the old launcher/home-button setup..."
sudo -u pi pkill -f launcher-server.py 2>/dev/null || true
sudo -u pi pkill -f home-button.py 2>/dev/null || true
sudo -u pi pkill -f chromium 2>/dev/null || true
rm -f /home/pi/.config/autostart/kiosk.desktop

sudo apt install -y libglib2.0-bin > /dev/null 2>&1 || true

CHROMIUM=$(command -v chromium-browser || command -v chromium || echo chromium-browser)
DESKTOP_DIR="/home/pi/Desktop"
ICON_DIR="/home/pi/kiosk/icons"
mkdir -p "$DESKTOP_DIR" "$ICON_DIR"

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
  chmod +x "$DESKTOP_DIR/$file"
}

# Live Stream: key baked into the URL so nothing needs to be typed on-device
make_icon "live-stream.desktop" "Live Stream" \
  "https://live-stream-it4q.onrender.com/s/q4625p/screen?key=LgPDW26rae8w" "" \
  "$ICON_DIR/mic.svg"

make_icon "ivr-quick-record.desktop" "IVR Quick Record" \
  "https://ivr.teltech.info/portal/extensions/" "0.85" \
  "$ICON_DIR/phone-quick.svg"

make_icon "ivr-admin.desktop" "IVR Admin (Full)" \
  "https://ivr.teltech.info/portal/extensions/" "0.65" \
  "$ICON_DIR/phone-admin.svg"

chown -R pi:pi "$ICON_DIR" "$DESKTOP_DIR" /home/pi/.config/autostart 2>/dev/null || true

# --- Mark the launchers as trusted (must run as pi, after chown, or it's a no-op) ---
for f in "$DESKTOP_DIR"/*.desktop; do
  sudo -u pi env DISPLAY=:0 XAUTHORITY=/home/pi/.Xauthority gio set "$f" metadata::trusted true 2>/dev/null || true
done

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

# Apply the single-click setting and icon refresh immediately, without a reboot
sudo -u pi env DISPLAY=:0 XAUTHORITY=/home/pi/.Xauthority pcmanfm --reconfigure 2>/dev/null || true

echo ""
echo "Done. Three desktop icons are ready with real icons, single-tap to open,"
echo "and no more 'trust this file' prompt:"
echo "  - Live Stream        (auto-connects, key is baked in)"
echo "  - IVR Quick Record   (bigger, for adding/recording to a folder)"
echo "  - IVR Admin (Full)   (zoomed out, for everything else)"
