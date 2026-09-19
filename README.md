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

## 📥 Installation

TaENDEC includes an automated installation script that sets up dependencies, configures directories, and creates a dedicated systemd service.

1. Clone or download the repository to your Debian/Ubuntu machine.
2. Make the installer executable:
   ```bash
   chmod +x install.sh
