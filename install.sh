#!/bin/bash

# Prevent execution as root
if [ "$EUID" -eq 0 ]; then
    echo "Error: The script should not be run as sudo. Run as your standard user."
    exit 1
fi

# Check for apt package manager
if ! command -v apt >/dev/null 2>&1; then
    echo "TaENDEC is meant for Debian/Ubuntu only. Other distros are not supported at this time."
    exit 1
fi

# Check for valid sudoers permissions
if ! sudo -v >/dev/null 2>&1; then
    echo "Please make sure sudo permissions are correct. Run su -, enter the root password, then run usermod sudo -aG (your user) and log out completely."
    exit 1
fi

# Dynamically set user, home directory, and cloned repo directory (e.g., /home/endec/TaENDEC)
APP_USER="$USER"
APP_DIR="/home/$APP_USER"
REPO_DIR="$APP_DIR/TaENDEC"

if [ ! -d "$REPO_DIR" ]; then
    echo "Error: Repository directory $REPO_DIR not found. Make sure you cloned TaENDEC into $APP_DIR/TaENDEC."
    exit 1
fi

echo "Installing system dependencies..."
sudo apt update
sudo apt install -y python3-requests python3-tzlocal ffmpeg espeak-ng unzip alsa-utils multimon-ng mpv fonts-freefont-ttf fonts-liberation fonts-dejavu sox libsox-fmt-all yt-dlp

# Add user to audio group immediately
sudo usermod -aG audio "$APP_USER"

echo "Preparing target directories..."
sudo mkdir -p "$APP_DIR/logs"
sudo mkdir -p /var/www/html
sudo mkdir -p /var/lib/eas_alerts/audio_archive
sudo mkdir -p /var/lib/eas_alerts/uploads
sudo mkdir -p /opt/taendec_tts

# --- Download Offline Broadcast TTS Engines ---
echo "Downloading offline broadcast TTS engines (vtpaul, cep6, dectalk, loqdave, spfy)..."
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    SUFFIX="amd64"
else
    SUFFIX="x86"
fi

sudo wget -qO /opt/taendec_tts/cep6 "https://github.com/wagwan-piffting-blud/cep6-rs/releases/download/2026.10.10/cep6-linux-${SUFFIX}"
sudo wget -qO /opt/taendec_tts/vtpaul "https://github.com/wagwan-piffting-blud/vtns-rs/releases/download/2026.10.27/vtpaul-linux-${SUFFIX}"
sudo wget -qO /opt/taendec_tts/dectalk "https://github.com/wagwan-piffting-blud/dectalk-rs/releases/download/2026.10.09/dectalk-linux-${SUFFIX}"
sudo wget -qO /opt/taendec_tts/loqdave "https://github.com/wagwan-piffting-blud/ENDEC_Dave/releases/download/2026.10.06/loqdave-linux-${SUFFIX}"
sudo wget -qO /opt/taendec_tts/spfy "https://github.com/wagwan-piffting-blud/spfy-rs/releases/latest/download/spfy-linux-${SUFFIX}"

sudo chmod +x /opt/taendec_tts/cep6 /opt/taendec_tts/vtpaul /opt/taendec_tts/dectalk /opt/taendec_tts/loqdave /opt/taendec_tts/spfy

echo "Downloading and extracting VoiceText voice data..."
sudo wget -qO /tmp/VoiceText.zip "https://uploads.wagspuzzle.space/VoiceText.zip"
sudo unzip -q -o /tmp/VoiceText.zip -d /opt/taendec_tts/
sudo rm -f /tmp/VoiceText.zip
sudo chown -R "$APP_USER:$APP_USER" /opt/taendec_tts

# --- Interactive ALSA Prompt ---
echo ""
echo "=================================================================="
echo "Available Audio Devices:"
sudo aplay -l
echo "=================================================================="
echo "Please enter the ALSA device string you want to use for alert audio output."
echo "Look at the 'card' and 'device' numbers above."
echo "Example: If Card 0, Device 3 is your preferred output, type: plughw:0,3"
echo "Press ENTER to default to: plughw:0,0"
read -p "ALSA Device [plughw:0,0]: " ALSA_DEVICE
ALSA_DEVICE=${ALSA_DEVICE:-plughw:0,0}
echo "Using ALSA Device: $ALSA_DEVICE"
echo ""

# --- 1. Generate Configuration File ---
echo "Writing Configuration..."
cat << 'EOF' | sudo tee "$APP_DIR/taendec_config.json" > /dev/null
{
  "security": {
    "require_auth": false,
    "username": "admin",
    "password": "password"
  },
  "general": {
    "sender_id": "TaENDEC ",
    "timezone": "America/Chicago",
    "default_voice_engine": "vtpaul"
  },
  "audio_processing": {
    "pre_alert_pause_ms": 1000,
    "prefixes": {
      "CIVIL_EMERGENCY": "",
      "WEATHER_WARNING": "",
      "WATCH": "",
      "ADVISORY": "",
      "TEST": "",
      "ALL_ALERTS": ""
    },
    "suffixes": {
      "CIVIL_EMERGENCY": "",
      "WEATHER_WARNING": "",
      "WATCH": "",
      "ADVISORY": "",
      "TEST": "",
      "ALL_ALERTS": ""
    }
  },
  "filters": {
    "enforce_fips_filtering": false,
    "allowed_state_prefixes": [
      "27",
      "91"
    ],
    "allowed_fips_codes": []
  },
  "monitors": {},
  "outputs": {
    "enable_http_post": true,
    "tv_station_ip": "192.168.12.199",
    "tv_multicast_address": "224.0.0.1:36332",
    "enable_discord_webhook": false,
    "discord_webhook_urls": [],
    "discord_username": "TaENDEC System",
    "discord_avatar_url": "",
    "gotify": {
      "enabled": false,
      "url": "",
      "token": ""
    }
  },
  "wea_logger": {
    "enabled": false,
    "discord_webhook": "",
    "discord_role_id": ""
  },
  "capcp": {
    "enabled": false,
    "lang": "en-CA",
    "tone": "pelmorex",
    "prefix": "",
    "suffix": ""
  },
  "icecast": {
    "enabled": false,
    "server_url": "",
    "bg_music_url": "",
    "bg_music_codec": "auto",
    "http_override_enabled": false,
    "http_override_url": "",
    "emerg_mcast_enabled": false,
    "emerg_mcast_url": "",
    "emerg_mcast_codec": "pcm_s16le_48k_stereo",
    "tech_diff_file": ""
  },
  "details_channel": {
    "mode": "static_screen",
    "media_url": "",
    "fallback_text": "Emergency Alert System Details Channel"
  },
  "rwt_rmt_scheduler": {
    "rwt_fips": "027145",
    "rmt_fips": "027145",
    "rwt_exact_day": 2,
    "rwt_exact_time": "11:15",
    "rwt_text": "",
    "rwt_voice": "",
    "rmt_week": 1,
    "rmt_day": 2,
    "rmt_time": "11:15",
    "rmt_text": "",
    "rmt_voice": "",
    "disable_voice": false
  }
}
EOF

# --- 2. Move Repository Files from $REPO_DIR to Target Directories ---
echo "Moving files from $REPO_DIR..."

if [ -f "$REPO_DIR/endec_system.py" ]; then
    mv "$REPO_DIR/endec_system.py" "$APP_DIR/endec_system.py"
else
    echo "Error: $REPO_DIR/endec_system.py not found!"
    exit 1
fi

if [ -f "$REPO_DIR/index.html" ]; then
    sudo mv "$REPO_DIR/index.html" /var/www/html/index.html
else
    echo "Error: $REPO_DIR/index.html not found!"
    exit 1
fi

if [ -f "$REPO_DIR/FIPS Codes.csv" ]; then
    mv "$REPO_DIR/FIPS Codes.csv" "$APP_DIR/FIPS Codes.csv"
else
    echo "Error: $REPO_DIR/FIPS Codes.csv not found!"
    exit 1
fi

# Inject dynamic username and ALSA device into endec_system.py
echo "Applying user permissions to $APP_USER and binding ALSA device..."
sed -i "s|APP_USER_PLACEHOLDER|$APP_USER|g" "$APP_DIR/endec_system.py"
sed -i "s|ALSA_DEVICE_PLACEHOLDER|$ALSA_DEVICE|g" "$APP_DIR/endec_system.py"

# Enforce strict correct ownership for the files and directories
sudo chown -R "$APP_USER:$APP_USER" "$APP_DIR/logs"
sudo chown "$APP_USER:$APP_USER" "$APP_DIR/taendec_config.json"
sudo chown "$APP_USER:$APP_USER" "$APP_DIR/endec_system.py"
sudo chown "$APP_USER:$APP_USER" "$APP_DIR/FIPS Codes.csv"
sudo chmod +x "$APP_DIR/endec_system.py"
sudo chown www-data:www-data /var/www/html/index.html
sudo chmod 644 /var/www/html/index.html
sudo chown -R "$APP_USER:$APP_USER" /var/lib/eas_alerts

# --- 3. Generate and Enable systemd Service ---
echo "Generating and enabling systemd service..."
SERVICE_NAME="taendec.service"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"

cat << EOF | sudo tee "$SERVICE_PATH" > /dev/null
[Unit]
Description=TaENDEC System - SAME Header Emergency Alert Decoder
After=network.target sound.target

[Service]
Type=simple
User=$APP_USER
SupplementaryGroups=audio
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/python3 $APP_DIR/endec_system.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

sudo chmod 644 "$SERVICE_PATH"
sudo systemctl daemon-reload
sudo systemctl enable --now "$SERVICE_NAME"

echo "Installation complete! The TaENDEC daemon is configured to output audio to $ALSA_DEVICE and run as user: $APP_USER."
