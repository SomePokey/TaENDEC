# TaENDEC (Totally An ENDEC) 📻

**Version:** 6.3.4 (Discord Webhook Hotfix)  
**Platform:** Debian / Ubuntu Linux  

TaENDEC is a Python-based Master Telemetry & Streaming Daemon designed to monitor, decode, generate, and route Emergency Alert System (EAS) messages. It acts as a fully functional software ENDEC, capable of monitoring audio streams via `multimon-ng`, generating compliant SAME headers and AFSK audio bursts, compiling TTS audio, and routing alert data to downstream systems like Discord, multicast TV stations, and local audio interfaces.

---

## 🚀 Features

* **Live Stream & ALSA Monitoring:** Dynamically monitor Icecast/HTTP audio streams or local ALSA hardware for SAME headers using `ffmpeg` and `multimon-ng`.
* **Automated Audio Generation:** Assembles complete EAS audio packages including front panel SAME tones (AFSK), the 853Hz/960Hz Attention Signal, custom/TTS voice messages (via `espeak-ng`), and End of Message (EOM) tones.
* **Discord Webhook Integration:** Pushes real-time alerts to Discord complete with color-coded severity embeds, expiration timestamps, translated SAME text, and compiled `.wav` audio files.
* **Details Channel Generation:** Uses `mpv` and DRM (Direct Rendering Manager) to output an idle status screen or dynamic emergency alert cards to a local display without needing an X11/Wayland desktop environment.
* **REST API:** Features a built-in HTTP server (Port `8085`) to trigger alerts, schedule future tests, update configurations, and check system status.
* **Automated Testing Scheduler:** Configure exact days and times for automatic Required Weekly Tests (RWT) and Required Monthly Tests (RMT).
* **FIPS Filtering:** Restrict alert processing and relaying to specific state prefixes or exact county FIPS codes.

---

## 🛠️ Prerequisites

TaENDEC is designed exclusively for Debian and Ubuntu-based environments. The installation script handles most dependencies, but your system must have:
* `apt` package manager
* `sudo` privileges for your user account
* A working sound card (ALSA) and video output (for the Details Channel)

---

## 📁 Required Data Files

* **`FIPS Codes.csv`**: You must provide this file in the application directory. TaENDEC references `FIPS Codes.csv` to translate standard FIPS location codes into human-readable county and state names. If this file is missing or not formatted correctly, your incoming alerts, webhook payloads, and logs will just show raw county codes for all counties instead of the geographic names.

---

## 📥 Installation

TaENDEC includes an automated installation script that sets up dependencies, configures directories, and creates a dedicated systemd service.

1. Clone or download the repository to your Debian/Ubuntu machine.
2. Ensure `FIPS Codes.csv` is included in the directory.
3. Make the installer executable:
   `chmod +x install.sh`

1. Clone or download the repository to your Debian/Ubuntu machine.
2. Make the installer executable:
   `chmod +x install.sh`

Run the installer:
`./install.sh`

Follow the prompt: The script will ask you for a username to install under (defaults to endec). It will automatically create this user, assign the correct audio/video groups, and dynamically configure the daemon for that user.

## ⚙️ Configuration

The main configuration file is stored in the home directory of the user you selected during installation (e.g., `/home/endec/taendec_config.json`).

If the file does not exist, the installer generates a default one. You can edit this file directly or use the TaENDEC API to push updates.

Key Configuration Sections:

`outputs`: Enable/disable HTTP POSTs, Discord webhooks, and set your multicast addresses.

`monitors`: Define the audio streams you want to monitor (e.g., `"Local_Radio": "http://stream.url/audio"` or `"Scanner": "ALSA"`).

`details_channel`: Configure the mpv output mode (`static_screen`, `media_stream`, `youtube`, or `off`).

Note: Restart the service after making manual changes to the JSON file.

## 📡 API Endpoints

TaENDEC runs a local HTTP API on Port 8085. Basic Auth is supported if enabled in the config.

`GET /status` - Returns current ENDEC state, queue depth, and stream monitoring status.

`GET /api/history` - Returns a JSON array of past alerts.

`POST /api/transmit` - Immediately generates and transmits an alert based on JSON payload.

`POST /api/schedule` - Schedules an alert for a future time.

`GET /api/config` - Fetches the active configuration JSON.

`POST /api/config` - Updates the configuration JSON.

## 🔧 Service Management

TaENDEC runs as a systemd background service. You can manage it using standard systemctl commands:

Check Status:
`sudo systemctl status taendec`

Restart the Daemon:
`sudo systemctl restart taendec`

View Live Logs:
`sudo journalctl -u taendec -f`

## File Locations

Daemon Script: `/home/<user>/endec_system.py`

Configuration: `/home/<user>/taendec_config.json`

FIPS Reference: `/home/<user>/FIPS Codes.csv`

Logs: `/home/<user>/logs/alert_history.log`

Audio Archive: `/var/lib/eas_alerts/audio_archive/`
