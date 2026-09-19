#!/bin/bash
# TaENDEC v6.3.4 Automated Installer

# 1. Check for Debian/Ubuntu (apt)
if ! command -v apt >/dev/null 2>&1; then
    echo "TaENDEC is meant for Debian/Ubuntu only. Other distros are not supported at this time."
    exit 1
fi

# 2. Check if sudo is installed
if ! command -v sudo >/dev/null 2>&1; then
    echo "This script runs commands as root to install the necessary dependencies. Please log in as root and run apt install sudo. Then run usermod sudo -aG (your user) and log out completely"
    exit 1
fi

# 3. Check if the current user has sudo privileges
if ! sudo_out=$(sudo -v 2>&1); then
    if echo "$sudo_out" | grep -qi "is not in the sudoers file"; then
        echo "Please make sure sudo permissions are correct. Run su -, enter the root password, then run usermod sudo -aG (your user) and log out completely."
        exit 1
    else
        echo "Sudo authentication failed. Please try running the script again."
        exit 1
    fi
fi

echo "--- Setup Configuration ---"
read -p "Enter the username to install TaENDEC under [default: endec]: " TARGET_USER
TARGET_USER=${TARGET_USER:-endec}
echo "TaENDEC will be installed for user: $TARGET_USER"

echo "--- [1/6] Installing System Dependencies ---"
sudo apt update
sudo apt install -y python3 python3-requests python3-tzlocal ffmpeg espeak-ng alsa-utils multimon-ng mpv curl

echo "--- [2/6] Configuring User and Directories ---"
# Create the target user if it doesn't exist
id -u $TARGET_USER &>/dev/null || sudo useradd -m -s /bin/bash $TARGET_USER

# Add the user to audio and video groups for ALSA and DRM/mpv access
sudo usermod -aG audio,video,render $TARGET_USER 2>/dev/null || sudo usermod -aG audio,video $TARGET_USER

sudo mkdir -p /home/$TARGET_USER/logs
sudo mkdir -p /var/lib/eas_alerts/audio_archive
sudo mkdir -p /var/lib/eas_alerts/uploads

echo "--- [3/6] Writing TaENDEC v6.3.4 Daemon ---"
# Write to temp file first, then dynamically patch paths, then move with sudo
cat << 'EOF' > /tmp/endec_system.py
#!/usr/bin/env python3
"""
TaENDEC Master Telemetry & Streaming Daemon (v6.3.4 - Discord Webhook Hotfix)
"""

import os, sys, time, json, wave, math, struct, base64, textwrap, logging
import threading, subprocess, queue, re, csv, tzlocal
import urllib.request, urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler
from datetime import datetime, timezone, timedelta

try:
    import requests
except ImportError:
    requests = None

LOG_DIR = "/home/endec/logs"
PERSISTENT_AUDIO_DIR = "/var/lib/eas_alerts/audio_archive"
UPLOAD_DIR = "/var/lib/eas_alerts/uploads"
CONFIG_FILE = "/home/endec/taendec_config.json"
CSV_FILE = "/home/endec/FIPS Codes.csv"

os.makedirs(LOG_DIR, exist_ok=True)
os.makedirs(PERSISTENT_AUDIO_DIR, exist_ok=True)
os.makedirs(UPLOAD_DIR, exist_ok=True)

ALERT_LOG_FILE = os.path.join(LOG_DIR, "alert_history.log")
ALERT_WAV_FILE = os.path.join(PERSISTENT_AUDIO_DIR, "tts_temp.wav")
COMPILED_ALERT_WAV = os.path.join(PERSISTENT_AUDIO_DIR, "compiled_alert.wav")

STATUS_SERVER_PORT = 8085
LOCAL_HW_OUTPUT = "plughw:0,0"
BARESIP_TAP_DEVICE = "plughw:1,1,0"

MAX_RECORDING_TIMEOUT = 210
TRIM_FRONT_SEC = 4.5
TRIM_BACK_SEC = 1.8

SCHEDULED_ALERTS = []
ALERT_HISTORY = []
ALERT_QUEUE = queue.Queue()
ACTIVE_RECORDINGS = {}
MONITOR_FLAGS = {}
BG_AUDIO_PROC = None

logger = logging.getLogger("ENDEC")
logger.setLevel(logging.INFO)
formatter = logging.Formatter("%(asctime)s.%(msecs)03d [TaENDEC] %(levelname)s: %(message)s", datefmt="%Y-%m-%d %H:%M:%S")
ch = logging.StreamHandler(sys.stdout)
ch.setFormatter(formatter)
logger.addHandler(ch)
fh = logging.FileHandler(ALERT_LOG_FILE)
fh.setFormatter(formatter)
logger.addHandler(fh)

STREAM_STATUS = {}
ENDEC_STATE = {"current_state": "IDLE / MONITORING", "active_alert": None, "last_event": None, "updated_at": datetime.now(timezone.utc).isoformat()}
STATE_LOCK = threading.Lock()
RECORDING_LOCK = threading.Lock()
MPV_PROCESS = None

EAS_EVENT_NAMES = {
    "ADR": "Administrative Message", "AVA": "Avalanche Watch", "AVW": "Avalanche Warning", "BLU": "Blue Alert", "BZW": "Blizzard Warning", "CAE": "Child Abduction Emergency", "CDA": "Civil Danger Watch", "CDW": "Civil Danger Warning", "CEM": "Civil Emergency Message", "CFA": "Coastal Flood Watch", "CFW": "Coastal Flood Warning", "DMO": "Demonstration Message", "DSW": "Dust Storm Warning", "EAN": "National Emergency Message", "EAT": "Emergency Action Termination", "EQW": "Earthquake Warning", "EVI": "Notice of Immediate Evacuation", "EWW": "Extreme Wind Warning", "FFA": "Flash Flood Watch", "FFS": "Flash Flood Statement", "FFW": "Flash Flood Warning", "FLA": "Flood Watch", "FLS": "Flood Statement", "FLW": "Flood Warning", "FRW": "Fire Warning", "FSW": "Flash Freeze Warning", "FZW": "Freeze Warning", "HLS": "Hurricane Local Statement", "HMW": "Hazardous Materials Warning", "HUA": "Hurricane Watch", "HUW": "Hurricane Warning", "HWA": "High Wind Watch", "HWW": "High Wind Warning", "LAE": "Local Area Emergency", "LEW": "Law Enforcement Warning", "MEP": "Notice of a Missing/Endangered Person", "NAT": "National Audible Test", "NIC": "National Information Center", "NMN": "Network Notification Message", "NPM": "Nuclear Power Plant Test", "NPT": "National Test of the Emergency Alert System", "NST": "National Silent Test", "NUW": "Nuclear Power Plant Warning", "RHW": "Radiological Hazard Warning", "RFW": "Red Flag Warning", "RMT": "Required Monthly Test", "RWT": "Required Weekly Test", "SCS": "School Closure Statement", "SMW": "Special Marine Warning", "SPS": "Special Weather Statement", "SPW": "Shelter In Place Warning", "SQW": "Snow Squall Warning", "SSA": "Storm Surge Watch", "SSW": "Storm Surge Warning", "SVA": "Severe Thunderstorm Watch", "SVR": "Severe Thunderstorm Warning", "SVS": "Severe Weather Statement", "TOA": "Tornado Watch", "TOE": "911 Telephone Outage Emergency", "TOR": "Tornado Warning", "TRA": "Tropical Storm Watch", "TRW": "Tropical Storm Warning", "TSA": "Tsunami Watch", "TSW": "Tsunami Warning", "VOW": "Volcano Warning", "WSA": "Winter Storm Watch", "WSW": "Winter Storm Warning", "BHW": "Biological Hazard Warning", "BWW": "Boil Water Warning", "CHW": "Chemical Hazard Warning", "CWW": "Contaminated Water Warning", "DBA": "Dam Watch", "DBW": "Dam Break Warning", "DEW": "Contagious Disease Warning", "EVA": "Evacuation Watch", "FCW": "Food Contamination Warning", "IBW": "Iceberg Warning", "IFW": "Industrial Fire Warning", "LSW": "Landslide Warning", "POS": "Power Outage Statement", "WFA": "Wildfire Watch", "WFW": "Wildfire Warning"
}
EAS_ORIGINATORS = {"EAS": "An EAS Participant", "CIV": "The Civil Authorities", "WXR": "The National Weather Service", "PEP": "The Primary Entry Point System"}

WX_WARN = ["TOR", "SVR", "BZW", "CFW", "DSW", "HWW", "EWW", "FFW", "FLW", "HUW", "SQW", "SMW", "SSW", "TRW", "WSW", "RFW"]
CIV_EMERG = ["MEP", "ADR", "TOE", "AVW", "AVA", "CAE", "EQW", "VOW", "TSW", "BWW", "BHW", "CHW", "CWW", "DBA", "DBW", "DEW", "FCW", "IBW", "IFW", "POS", "WFW", "WFA", "BLU", "CDA", "SCS", "LAE", "LEW", "CEM", "CDW", "SPW", "RHW", "NUW", "HMW", "EVI"]
TEST_ALERTS = ["RWT", "RMT", "DMO", "NPT", "NAT", "NST", "NPM"]
WATCH_ALERTS = ["CFA", "FFA", "FLA", "HWA", "HUA", "SVA", "SSA", "TOA", "TRA", "WSA"]
ADVISORY_ALERTS = ["FFS", "FLS", "HLS", "NMN", "SPS", "SVS"]

def set_endec_state(state_name, alert_details=None):
    with STATE_LOCK:
        ENDEC_STATE["current_state"] = state_name
        ENDEC_STATE["updated_at"] = datetime.now(timezone.utc).isoformat()
        if alert_details:
            ENDEC_STATE["active_alert"] = alert_details
            if state_name == "IDLE / MONITORING": ENDEC_STATE["last_event"] = alert_details

def load_taendec_config():
    try:
        with open(CONFIG_FILE, "r") as f: return json.load(f)
    except: return {}

def load_fips_database(csv_path=CSV_FILE):
    fips_dict = {}
    try:
        if not os.path.exists(csv_path): return fips_dict
        with open(csv_path, mode="r", encoding="utf-8-sig") as f:
            reader = csv.DictReader(f)
            for row in reader:
                row_clean = {k.strip(): v for k, v in row.items() if k}
                fips_val = row_clean.get("FIPS", "").strip().zfill(5)
                name = row_clean.get("Name", "").strip()
                state = row_clean.get("State", "").strip()
                if fips_val and name: fips_dict[fips_val] = f"{name}, {state}"
    except: pass
    return fips_dict

GLOBAL_FIPS_MAP = load_fips_database()

def get_county_name(fips_code):
    f_clean = fips_code.strip()
    if f_clean == "627053": return "City of Minneapolis, MN"
    if len(f_clean) == 6: pca_prefix, base_fips = f_clean[0], f_clean[1:]
    else: pca_prefix, base_fips = "0", f_clean
    base_name = GLOBAL_FIPS_MAP.get(base_fips, f"County code {base_fips}")
    prefix_map = {"1": "Northwestern", "2": "Northern", "3": "Northeastern", "4": "Western", "5": "Central", "6": "Eastern", "7": "Southwestern", "8": "Southern", "9": "Southeastern"}
    if pca_prefix in prefix_map and pca_prefix != "0" and "," in base_name:
        county, state = base_name.split(",", 1)
        return f"{prefix_map[pca_prefix]} {county.strip()}, {state.strip()}"
    return base_name

def is_in_alerting_area(raw_header):
    config = load_taendec_config()
    filters = config.get("filters", {})
    if not filters.get("enforce_fips_filtering", False): return True
    allowed_states = filters.get("allowed_state_prefixes", ["27", "91"])
    allowed_fips = filters.get("allowed_fips_codes", [])
    try:
        fips_match = re.search(r"-([0-9\-]+)\+", raw_header)
        if fips_match:
            for fips in [f.strip() for f in fips_match.group(1).split("-") if len(f.strip()) == 6]:
                if fips[1:3] in allowed_states or fips in allowed_fips: return True
        return False
    except: return True

def get_utc_header_timestamp():
    return datetime.now(timezone.utc).strftime("%j%H%M")

def translate_same_to_speech(header_str, start_time_dt=None):
    try: local_tz = tzlocal.get_localzone()
    except: local_tz = datetime.now().astimezone().tzinfo
    parts = header_str.replace("EAS:", "").strip("-").split("-")
    if len(parts) < 5: return "An Emergency Alert has been issued."
    org_code, evt_code = parts[1], parts[2]
    
    fips_codes = []
    fips_match = re.search(r"-([0-9\-]+)\+", header_str)
    if fips_match: fips_codes = [f.strip() for f in fips_match.group(1).split("-") if f.strip()]
    
    dur_hh, dur_mm = 0, 30
    dur_match = re.search(r"\+([0-9]{4})", header_str)
    if dur_match: dur_hh, dur_mm = int(dur_match.group(1)[:2]), int(dur_match.group(1)[2:])
        
    sender_clean = parts[-1].strip() if len(parts) > 5 else load_taendec_config().get("general", {}).get("sender_id", "TaENDEC").strip()
    org_name = EAS_ORIGINATORS.get(org_code, "An EAS Participant")
    evt_name = EAS_EVENT_NAMES.get(evt_code, f"{evt_code} Alert")
    loc_string = "; ".join([get_county_name(f) for f in fips_codes]) if fips_codes else "the affected areas"
    
    if not start_time_dt: start_time_dt = datetime.now(local_tz)
    else: start_time_dt = start_time_dt.astimezone(local_tz)
    end_time_dt = start_time_dt + timedelta(hours=dur_hh, minutes=dur_mm)
    
    start_str = start_time_dt.strftime("%I:%M %p on %B %d").replace(" 0", " ")
    end_str = end_time_dt.strftime("%I:%M %p").replace(" 0", " ")
    prefix = f"{org_name} have issued a {evt_name}" if org_code == "CIV" else f"{org_name} has issued a {evt_name}"
    return f"{prefix} for the following areas: {loc_string}; starting at {start_str}, effective until {end_str}. This message is from {sender_clean}."

def dispatch_discord_webhook(raw_header, additional_text="", wav_path=None):
    if not requests: return
    config = load_taendec_config()
    outputs = config.get("outputs", {})
    if not outputs.get("enable_discord_webhook", False): return

    webhook_urls = outputs.get("discord_webhook_urls", outputs.get("discord_webhook_url", []))
    if not webhook_urls: return
    if isinstance(webhook_urls, str): webhook_urls = [u.strip() for u in webhook_urls.split(",") if u.strip()]

    header_clean = raw_header.replace("EAS:", "").strip("-")
    parts = header_clean.split("-")
    if len(parts) < 5: return
    org_code, evt_code = parts[1], parts[2]
    
    fips_match = re.search(r"-([0-9\-]+)\+", raw_header)
    fips_codes = [f.strip() for f in fips_match.group(1).split("-") if fips_match else []]
    
    dur_hh, dur_mm = 0, 30
    dur_match = re.search(r"\+([0-9]{4})", raw_header)
    if dur_match: dur_hh, dur_mm = int(dur_match.group(1)[:2]), int(dur_match.group(1)[2:])
        
    sender = parts[-1].strip() if len(parts) > 5 else "TaENDEC"
    evt_name = EAS_EVENT_NAMES.get(evt_code, f"{evt_code} Alert")
    org_name = EAS_ORIGINATORS.get(org_code, "An EAS Participant")
    
    if evt_code in WX_WARN or evt_code in CIV_EMERG: color = 16711680; sev_str = "🔴 Extreme / Immediate"; icon = "🚨"
    elif evt_code in WATCH_ALERTS: color = 16766464; sev_str = "🟡 Severe / Expected"; icon = "⚠️"
    elif evt_code in TEST_ALERTS: color = 255; sev_str = "🔵 Routine Test"; icon = "ℹ️"
    else: color = 65280; sev_str = "🟢 Moderate / Advisory"; icon = "📢"
        
    try: local_tz = tzlocal.get_localzone()
    except: local_tz = datetime.now().astimezone().tzinfo
    
    now = datetime.now(local_tz)
    end_time = now + timedelta(hours=dur_hh, minutes=dur_mm)
    end_unix = int(end_time.timestamp())
    
    area_list = "\n".join([f"• {get_county_name(f)} ({f})" for f in fips_codes]) if fips_codes else "Unknown Area"
    if len(area_list) > 1024: area_list = area_list[:1020] + "..."

    desc = translate_same_to_speech(raw_header, now)
    if additional_text: desc += f"\n\n**Additional Details:**\n{additional_text}"

    embed_fields = [
        {"name": "📡 Originator", "value": org_name, "inline": True},
        {"name": "⚠️ Severity", "value": sev_str, "inline": True},
        {"name": "📅 Expiration Time", "value": f"<t:{end_unix}:F>\n(<t:{end_unix}:R>)", "inline": False},
        {"name": "📍 Affected Areas (SAME)", "value": area_list, "inline": False},
        {"name": "📟 Raw SAME Header", "value": f"```\n{raw_header}\n```", "inline": False}
    ]
    
    has_audio = wav_path and os.path.exists(wav_path)
    if has_audio: embed_fields.insert(2, {"name": "📻 Audio Capture", "value": "Listen to the broadcast audio attached below.", "inline": True})

    payload = {
        "username": outputs.get("discord_username") or "TaENDEC System",
        "embeds": [{
            "title": f"{icon} {evt_name.upper()} [{evt_code}]",
            "description": desc,
            "color": color,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "fields": embed_fields,
            "footer": {"text": f"Sender: {sender} • TaENDEC Master v6.3.4"}
        }]
    }

    discord_avatar = outputs.get("discord_avatar_url")
    if discord_avatar: payload["avatar_url"] = discord_avatar

    for url in webhook_urls:
        try:
            logger.info(f"[DISCORD] Dispatching webhook to {url[:30]}...")
            if has_audio:
                with open(wav_path, "rb") as audio_file:
                    form_data = {
                        "payload_json": (None, json.dumps(payload), "application/json"),
                        "files[0]": (os.path.basename(wav_path), audio_file, "audio/wav")
                    }
                    res = requests.post(url, files=form_data, timeout=15)
            else: res = requests.post(url, json=payload, timeout=10)
            
            if res.status_code not in (200, 204): logger.error(f"[DISCORD] Failed (HTTP {res.status_code}): {res.text}")
            else: logger.info(f"[DISCORD] Successfully transmitted to {url[:30]}...")
        except Exception as e: logger.error(f"[DISCORD] Webhook dispatch failed for URL {url[:30]}... : {e}")

def dispatch_alert_json(raw_header, additional_text="", has_audio=True):
    config = load_taendec_config()
    outputs = config.get("outputs", {})
    if not outputs.get("enable_http_post", True): return
    tv_ip = outputs.get("tv_station_ip", "192.168.12.199")
    tv_url = f"http://{tv_ip}/api/alert"
    mc_addr = outputs.get("tv_multicast_address", "224.0.0.1:36332")
    try: urllib.request.urlopen(urllib.request.Request(tv_url, data=json.dumps({"raw_header": raw_header, "additional_text": additional_text, "stream_type": "EAS Alert", "multicast_target": mc_addr, "has_audio": has_audio, "timestamp": datetime.now(timezone.utc).isoformat()}).encode("utf-8"), headers={"Content-Type": "application/json"}, method="POST"), timeout=10)
    except: pass

def notify_tv_alert_done(raw_header):
    config = load_taendec_config()
    outputs = config.get("outputs", {})
    if not outputs.get("enable_http_post", True): return
    tv_ip = outputs.get("tv_station_ip", "192.168.12.199")
    tv_url = f"http://{tv_ip}/api/alert/done"
    try: urllib.request.urlopen(urllib.request.Request(tv_url, data=json.dumps({"status": "COMPLETED", "raw_header": raw_header}).encode("utf-8"), headers={"Content-Type": "application/json"}, method="POST"), timeout=10)
    except: pass

def generate_afsk_burst_samples(text_str, repeat_count=3, sample_rate=22050):
    samples_per_bit = sample_rate / 520.833333
    MARK_FREQ, SPACE_FREQ = 2083.3333, 1562.5
    full_data = (b"\xAB" * 16) + text_str.encode("ascii")
    audio_samples = []
    for _ in range(repeat_count):
        phase = 0.0
        for byte_val in full_data:
            for bit_idx in range(8):
                freq = MARK_FREQ if ((byte_val >> bit_idx) & 1) == 1 else SPACE_FREQ
                phase_incr = 2.0 * math.pi * freq / sample_rate
                for _ in range(int(round(samples_per_bit))):
                    audio_samples.append(int(32767.0 * 0.75 * math.sin(phase)))
                    phase = (phase + phase_incr) % (2.0 * math.pi)
        audio_samples.extend([0] * int(sample_rate * 1.0))
    return audio_samples

def generate_attention_signal_samples(duration_sec=8.0, sample_rate=22050):
    audio_samples = []
    p1, p2 = 0.0, 0.0
    i1 = 2.0 * math.pi * 853.0 / sample_rate
    i2 = 2.0 * math.pi * 960.0 / sample_rate
    for _ in range(int(sample_rate * duration_sec)):
        audio_samples.append(int(32767.0 * 0.40 * (math.sin(p1) + math.sin(p2))))
        p1 = (p1 + i1) % (2.0 * math.pi)
        p2 = (p2 + i2) % (2.0 * math.pi)
    return audio_samples

def get_audio_clip_samples(file_path, sample_rate=22050):
    if not file_path or not os.path.exists(file_path): return []
    try:
        norm_path = "/tmp/clip_norm.wav"
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", file_path, "-ar", str(sample_rate), "-ac", "1", norm_path], check=True)
        with wave.open(norm_path, "rb") as wf:
            num_frames = wf.getnframes()
            return list(struct.unpack(f"<{num_frames}h", wf.readframes(num_frames)))
    except: return []

def compile_full_eas_audio(raw_header, recorded_wav_path=None, tts_text="", voice_engine="espeak", output_wav_path=COMPILED_ALERT_WAV):
    sample_rate = 22050
    header_clean = raw_header.replace("EAS:", "").strip()
    parts = header_clean.split("-")
    evt_code = parts[2] if len(parts) > 2 else "ADR"
    
    config = load_taendec_config()
    ap_config = config.get("audio_processing", {})
    
    cat_prefix, cat_suffix = "", ""
    if evt_code in TEST_ALERTS:
        cat_prefix = ap_config.get("prefixes", {}).get("TEST", "")
        cat_suffix = ap_config.get("suffixes", {}).get("TEST", "")
    elif evt_code in WX_WARN:
        cat_prefix = ap_config.get("prefixes", {}).get("WEATHER_WARNING", "")
        cat_suffix = ap_config.get("suffixes", {}).get("WEATHER_WARNING", "")
    elif evt_code in CIV_EMERG:
        cat_prefix = ap_config.get("prefixes", {}).get("CIVIL_EMERGENCY", "")
        cat_suffix = ap_config.get("suffixes", {}).get("CIVIL_EMERGENCY", "")
    elif evt_code in WATCH_ALERTS:
        cat_prefix = ap_config.get("prefixes", {}).get("WATCH", "")
        cat_suffix = ap_config.get("suffixes", {}).get("WATCH", "")
    elif evt_code in ADVISORY_ALERTS:
        cat_prefix = ap_config.get("prefixes", {}).get("ADVISORY", "")
        cat_suffix = ap_config.get("suffixes", {}).get("ADVISORY", "")

    prefix_path = cat_prefix if cat_prefix else ap_config.get("prefixes", {}).get("ALL_ALERTS", "")
    suffix_path = cat_suffix if cat_suffix else ap_config.get("suffixes", {}).get("ALL_ALERTS", "")

    master_samples = []
    voice_samples = []
    has_audio_payload = False

    if recorded_wav_path and os.path.exists(recorded_wav_path) and os.path.getsize(recorded_wav_path) > 1000:
        has_audio_payload = True
        try:
            if "raw_capture" in recorded_wav_path:
                with wave.open(recorded_wav_path, "rb") as wf:
                    num_frames = wf.getnframes()
                    all_voice_samples = list(struct.unpack(f"<{num_frames}h", wf.readframes(num_frames)))
                trim_start = int(sample_rate * TRIM_FRONT_SEC)
                trim_end = len(all_voice_samples) - int(sample_rate * TRIM_BACK_SEC)
                voice_samples = all_voice_samples[trim_start:trim_end] if trim_end > trim_start else all_voice_samples
            else: voice_samples = get_audio_clip_samples(recorded_wav_path, sample_rate)
        except: pass
    elif tts_text:
        has_audio_payload = True
        try:
            tts_text_phonetic = tts_text.replace("SpeX", "Specs")
            subprocess.run(["espeak-ng", "-v", "en-us", "-s", "150", "-p", "40", tts_text_phonetic, "-w", ALERT_WAV_FILE], check=True)
            norm_wav = "/tmp/tts_norm.wav"
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", ALERT_WAV_FILE, "-ar", "22050", "-ac", "1", norm_wav], check=True)
            with wave.open(norm_wav, "rb") as wf:
                num_frames = wf.getnframes()
                voice_samples = list(struct.unpack(f"<{num_frames}h", wf.readframes(num_frames)))
        except: pass

    prefix_samples = get_audio_clip_samples(prefix_path, sample_rate)
    if prefix_samples:
        master_samples.extend(prefix_samples)
        master_samples.extend([0] * int(sample_rate * 0.5))

    master_samples.extend(generate_afsk_burst_samples(header_clean, 3, sample_rate))

    if has_audio_payload:
        master_samples.extend(generate_attention_signal_samples(8.0, sample_rate))
        master_samples.extend([0] * int(sample_rate * 0.5))
        if voice_samples:
            master_samples.extend(voice_samples)
            master_samples.extend([0] * int(sample_rate * 0.5))

    master_samples.extend(generate_afsk_burst_samples("NNNN", 3, sample_rate))

    suffix_samples = get_audio_clip_samples(suffix_path, sample_rate)
    if suffix_samples:
        master_samples.extend([0] * int(sample_rate * 0.5))
        master_samples.extend(suffix_samples)

    time_str = datetime.now().strftime("%Y%m%d_%H%M%S")
    file_name = f"alert_{time_str}.wav"
    persistent_wav_path = os.path.join(PERSISTENT_AUDIO_DIR, file_name)
    with wave.open(persistent_wav_path, "wb") as master_wf:
        master_wf.setnchannels(1)
        master_wf.setsampwidth(2)
        master_wf.setframerate(sample_rate)
        packed_data = bytearray()
        for s in master_samples: packed_data.extend(struct.pack("<h", max(-32768, min(32767, s))))
        master_wf.writeframes(packed_data)
    if os.path.exists(output_wav_path): os.remove(output_wav_path)
    os.link(persistent_wav_path, output_wav_path)
    return persistent_wav_path, file_name

def start_software_recording(stream_name, raw_header):
    safe_name = "".join([c if c.isalnum() else "_" for c in stream_name])
    file_path = os.path.join(PERSISTENT_AUDIO_DIR, f"raw_capture_{safe_name}.wav")
    wav_handle = wave.open(file_path, "wb")
    wav_handle.setnchannels(1)
    wav_handle.setsampwidth(2)
    wav_handle.setframerate(22050)
    with RECORDING_LOCK: ACTIVE_RECORDINGS[stream_name] = {"wav_handle": wav_handle, "start_time": time.time(), "raw_header": raw_header, "file_path": file_path}

def write_software_audio_chunk(stream_name, data_bytes):
    if stream_name in ACTIVE_RECORDINGS:
        try: ACTIVE_RECORDINGS[stream_name]["wav_handle"].writeframes(data_bytes)
        except: pass

def stop_software_recording(stream_name):
    with RECORDING_LOCK:
        if stream_name in ACTIVE_RECORDINGS:
            rec = ACTIVE_RECORDINGS.pop(stream_name)
            try: rec["wav_handle"].close()
            except: pass
            return rec
        return None

def finalize_and_enqueue_alert(stream_name):
    rec = stop_software_recording(stream_name)
    if rec: ALERT_QUEUE.put({"type": "STREAM", "stream_name": stream_name, "raw_header": rec["raw_header"], "raw_wav_path": rec["file_path"]})

def recording_timeout_worker():
    while True:
        time.sleep(5)
        timed_out_streams = []
        with RECORDING_LOCK:
            now = time.time()
            for stream_name, rec in ACTIVE_RECORDINGS.items():
                if now - rec["start_time"] > MAX_RECORDING_TIMEOUT:
                    timed_out_streams.append(stream_name)
        for stream_name in timed_out_streams:
            finalize_and_enqueue_alert(stream_name)

def launch_idle_screen():
    global MPV_PROCESS
    if MPV_PROCESS and MPV_PROCESS.poll() is None:
        MPV_PROCESS.terminate()
        try: MPV_PROCESS.wait(timeout=2)
        except: MPV_PROCESS.kill()
    config = load_taendec_config()
    mode = config.get("details_channel", {}).get("mode", "static_screen")
    if mode == "off": return
    cmd = []
    if mode == "static_screen":
        raw_txt = config.get("details_channel", {}).get("fallback_text", "Emergency Alert System Details Channel")
        pages = raw_txt.split("${newpage}")
        generated_images = []
        for idx, page_text in enumerate(pages):
            wrapped_lines = []
            for line in page_text.strip().split("\n"):
                if line.strip(): wrapped_lines.extend(textwrap.wrap(line, width=50))
                else: wrapped_lines.append("")
            txt_path = f"/tmp/idle_txt_{idx}.txt"
            img_path = f"/tmp/idle_card_{idx}.png"
            with open(txt_path, "w") as f: f.write("\n".join(wrapped_lines))
            filtergraph = (
                "drawbox=x=0:y=0:w=1920:h=1080:color=0x000033@1.0:t=fill,"
                "drawtext=font='Sans':text='EAS DETAILS CHANNEL':x=(w-text_w)/2:y=100:fontsize=72:fontcolor=white,"
                f"drawtext=font='Sans':textfile='{txt_path}':x=120:y=250:fontsize=48:fontcolor=yellow:line_spacing=24"
            )
            if len(pages) > 1: filtergraph += f",drawtext=font='Sans':text='Page {idx+1} of {len(pages)}':x=w-text_w-50:y=h-text_h-50:fontsize=36:fontcolor=0x888888"
            subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i", "color=c=black:s=1920x1080", "-vf", filtergraph, "-vframes", "1", img_path])
            generated_images.append(img_path)
        if len(generated_images) == 1: cmd = ["mpv", "--vo=gpu", "--gpu-context=drm", "--drm-device=/dev/dri/card0", "--loop-file=inf", generated_images[0]]
        else: cmd = ["mpv", "--vo=gpu", "--gpu-context=drm", "--drm-device=/dev/dri/card0", "--image-display-duration=10", "--loop-playlist=inf"] + generated_images
    elif mode in ["media_stream", "youtube"]:
        url = config.get("details_channel", {}).get("media_url", "")
        if url: cmd = ["mpv", "--vo=gpu", "--gpu-context=drm", "--drm-device=/dev/dri/card0", "--loop-file=inf", url]
    if cmd:
        try: MPV_PROCESS = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        except: pass

def generate_alert_card(translated_text, additional_text=""):
    config = load_taendec_config()
    if config.get("details_channel", {}).get("mode", "static_screen") == "off": return []
    safe_trans = translated_text.replace("%", "\\%")
    safe_add = additional_text.replace("%", "\\%")
    body_lines = []
    if safe_trans.strip(): body_lines.extend(textwrap.wrap(safe_trans.strip(), width=48))
    if safe_add.strip():
        if body_lines: body_lines.append("")
        body_lines.extend(textwrap.wrap(safe_add.strip(), width=48))
    pages = [body_lines[i:i + 11] for i in range(0, len(body_lines), 11)] or [["AN EMERGENCY ALERT HAS BEEN ISSUED"]]
    generated_images = []
    for idx, page_lines in enumerate(pages):
        txt_path = f"/tmp/card_text_{idx}.txt"
        img_path = f"/tmp/alert_card_{idx}.png"
        with open(txt_path, "w") as f: f.write("\n".join(page_lines))
        filtergraph = (
            "drawbox=x=0:y=0:w=1920:h=180:color=0x8b0000@1.0:t=fill,"
            "drawtext=font='Sans':text='EMERGENCY ALERT SYSTEM':x=(w-text_w)/2:y=55:fontsize=72:fontcolor=white,"
            "drawbox=x=0:y=180:w=1920:h=6:color=0xff0000@1.0:t=fill,"
            f"drawtext=font='Sans':textfile='{txt_path}':x=120:y=280:fontsize=48:fontcolor=yellow:line_spacing=24"
        )
        if len(pages) > 1: filtergraph += f",drawtext=font='Sans':text='Page {idx+1} of {len(pages)}':x=w-text_w-50:y=h-text_h-50:fontsize=36:fontcolor=0x888888"
        try:
            subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i", "color=c=0x0a0a0a:s=1920x1080:rate=1", "-vf", filtergraph, "-vframes", "1", img_path], check=True)
            generated_images.append(img_path)
        except: pass
    return generated_images

def launch_mpv_display(media_sources):
    global MPV_PROCESS
    if load_taendec_config().get("details_channel", {}).get("mode", "static_screen") == "off": return
    if MPV_PROCESS and MPV_PROCESS.poll() is None:
        MPV_PROCESS.terminate()
        try: MPV_PROCESS.wait(timeout=2)
        except: MPV_PROCESS.kill()
    if not media_sources: return
    if len(media_sources) == 1: cmd = ["mpv", "--vo=gpu", "--gpu-context=drm", "--drm-device=/dev/dri/card0", "--image-display-duration=inf", media_sources[0]]
    else: cmd = ["mpv", "--vo=gpu", "--gpu-context=drm", "--drm-device=/dev/dri/card0", "--image-display-duration=5", "--loop-playlist=inf"] + media_sources
    try: MPV_PROCESS = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    except: pass

def stop_mpv_display():
    launch_idle_screen()

def stream_and_play_alert_wav(wav_path):
    proc_alsa = subprocess.Popen(["aplay", "-D", LOCAL_HW_OUTPUT, wav_path], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    proc_alsa.wait()

def background_audio_worker():
    global BG_AUDIO_PROC
    while True:
        config = load_taendec_config()
        details_conf = config.get("details_channel", {})
        always_play = details_conf.get("always_play_multicast_audio", False)
        mc_url = details_conf.get("multicast_monitor_url", "")
        with STATE_LOCK: is_idle = (ENDEC_STATE["current_state"] == "IDLE / MONITORING")
        if is_idle and always_play and mc_url:
            if BG_AUDIO_PROC is None or BG_AUDIO_PROC.poll() is not None:
                BG_AUDIO_PROC = subprocess.Popen(["ffplay", "-nodisp", "-fflags", "nobuffer", "-loglevel", "quiet", mc_url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            if BG_AUDIO_PROC is not None:
                BG_AUDIO_PROC.terminate()
                try: BG_AUDIO_PROC.wait(timeout=1)
                except subprocess.TimeoutExpired: BG_AUDIO_PROC.kill()
                BG_AUDIO_PROC = None
        time.sleep(1)

def alert_playback_worker():
    while True:
        payload = ALERT_QUEUE.get()
        try:
            config = load_taendec_config()
            try: pause_ms = max(0, min(int(config.get("audio_processing", {}).get("pre_alert_pause_ms", 1000)), 7000))
            except: pause_ms = 1000

            if payload["type"] == "STREAM":
                raw_header = payload["raw_header"]
                raw_wav_path = payload["raw_wav_path"]
                stream_name = payload["stream_name"]
                set_endec_state("COMPILING & DISPATCHING", {"raw_header": raw_header})
                compiled_wav, file_name = compile_full_eas_audio(raw_header, recorded_wav_path=raw_wav_path)
                full_translation = translate_same_to_speech(raw_header)
                ALERT_HISTORY.append({"timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"), "header": raw_header, "mode": f"Stream ({stream_name})", "file": file_name})
                
                card_paths = generate_alert_card(translated_text=full_translation, additional_text="")
                if card_paths: launch_mpv_display(card_paths)
                
                threading.Thread(target=dispatch_alert_json, args=(raw_header, full_translation, True)).start()
                threading.Thread(target=dispatch_discord_webhook, args=(raw_header, "", compiled_wav)).start()
                
                time.sleep(pause_ms / 1000.0)
                if os.path.exists(compiled_wav): stream_and_play_alert_wav(compiled_wav)
                stop_mpv_display()
                notify_tv_alert_done(raw_header)

            elif payload["type"] == "WEB":
                evt = payload.get("eventCode", "ADR")
                fips = payload.get("fipsCodes", "027145")
                dur = payload.get("duration", "0030")
                org = payload.get("originator", "EAS")
                sender = config.get("general", {}).get("sender_id", "TaENDEC ").ljust(8, " ")[:8]
                header_str = f"ZCZC-{org}-{evt}-{fips}+{dur}-{get_utc_header_timestamp()}-{sender}-"
                set_endec_state("PROCESSING WEB ALERT", {"event_code": evt, "fips_code": fips})
                add_text = urllib.parse.unquote_plus(payload.get("additionalText", "").strip())
                has_custom_audio = payload.get("hasAudio", False)
                voice_wav_path = payload.get("voice_wav_path", None)
                skip_trans = payload.get("skip_translation_in_tts", False)
                voice_engine = payload.get("voiceEngine", "espeak")
                if config.get("rwt_rmt_scheduler", {}).get("disable_voice", False) and evt in ["RWT", "RMT"]:
                    add_text = ""; skip_trans = True; has_custom_audio = False; voice_wav_path = ""
                
                full_translation = translate_same_to_speech(header_str)
                if skip_trans: tts_script = add_text
                elif has_custom_audio: tts_script = ""
                else: tts_script = full_translation + "\n\n" + add_text if add_text else full_translation
                
                compiled_wav, file_name = compile_full_eas_audio(header_str, recorded_wav_path=voice_wav_path, tts_text=tts_script, voice_engine=voice_engine)
                ALERT_HISTORY.append({"timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"), "header": header_str, "mode": f"WEB TTS ({voice_engine})", "file": file_name})
                
                card_paths = generate_alert_card(translated_text=full_translation, additional_text=add_text)
                if card_paths: launch_mpv_display(card_paths)
                
                threading.Thread(target=dispatch_alert_json, args=(header_str, add_text, True)).start()
                threading.Thread(target=dispatch_discord_webhook, args=(header_str, add_text, compiled_wav)).start()

                time.sleep(pause_ms / 1000.0)
                if os.path.exists(compiled_wav): stream_and_play_alert_wav(compiled_wav)
                stop_mpv_display()
                notify_tv_alert_done(header_str)

        except Exception as e: logger.error(f"[QUEUE WORKER ERROR] Alert playback crashed: {e}")
        finally:
            set_endec_state("IDLE / MONITORING", None)
            ALERT_QUEUE.task_done()

def handle_incoming_eas_line(stream_name, line):
    line_clean = line.strip()
    if "ZCZC-" in line_clean:
        if not is_in_alerting_area(line_clean): return
        if stream_name not in ACTIVE_RECORDINGS:
            set_endec_state("RECEIVING & RECORDING ALERT", {"source_stream": stream_name, "raw_header": line_clean})
            start_software_recording(stream_name, line_clean)
    elif "NNNN" in line_clean and stream_name in ACTIVE_RECORDINGS:
        finalize_and_enqueue_alert(stream_name)

def monitor_stream_worker(stream_name):
    last_url = ""
    p_proc = None
    p_multi = None
    while MONITOR_FLAGS.get(stream_name, False):
        config = load_taendec_config()
        current_url = config.get("monitors", {}).get(stream_name, "")
        if not current_url:
            if p_proc: p_proc.terminate(); p_proc = None
            if p_multi: p_multi.terminate(); p_multi = None
            STREAM_STATUS[stream_name] = {"status": "DISABLED", "last_active": "N/A", "url": ""}
            time.sleep(5)
            continue
        if current_url != last_url or p_multi is None or p_multi.poll() is not None:
            last_url = current_url
            if p_proc: p_proc.terminate()
            if p_multi: p_multi.terminate()
            STREAM_STATUS[stream_name] = {"status": "CONNECTING", "last_active": "Never", "url": current_url}
            if current_url == "ALSA": p_proc = subprocess.Popen(["arecord", "-D", BARESIP_TAP_DEVICE, "-f", "S16_LE", "-r", "22050", "-c", "1", "-t", "raw"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            else: p_proc = subprocess.Popen(["ffmpeg", "-hide_banner", "-loglevel", "error", "-rw_timeout", "15000000", "-i", current_url, "-af", "aresample=resampler=soxr", "-c:a", "pcm_s16le", "-f", "s16le", "-ar", "22050", "-ac", "1", "-"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            p_multi = subprocess.Popen(["stdbuf", "-oL", "multimon-ng", "-a", "EAS", "-t", "raw", "-"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
            STREAM_STATUS[stream_name]["status"] = "LISTENING"
            def read_multimon(p, name):
                while True:
                    try:
                        line = p.stdout.readline()
                        if not line: break
                        STREAM_STATUS[name]["last_active"] = datetime.now().strftime("%H:%M:%S")
                        if any(x in line for x in ["EAS:", "ZCZC", "NNNN"]): handle_incoming_eas_line(name, line)
                    except: break
            threading.Thread(target=read_multimon, args=(p_multi, stream_name), daemon=True).start()
        while True:
            if p_proc.poll() is not None: break
            chunk = p_proc.stdout.read(4096)
            if not chunk: break
            try: p_multi.stdin.buffer.write(chunk); p_multi.stdin.buffer.flush()
            except: pass
            write_software_audio_chunk(stream_name, chunk)
        logger.warning(f"[MONITOR] Stream {stream_name} connection dropped. Reconnecting...")
        last_url = ""
        time.sleep(3)

def dynamic_monitor_manager():
    while True:
        config = load_taendec_config()
        monitors = config.get("monitors", {})
        for name in monitors:
            if name not in MONITOR_FLAGS:
                MONITOR_FLAGS[name] = True
                threading.Thread(target=monitor_stream_worker, args=(name,), daemon=True).start()
        time.sleep(5)

def schedule_worker():
    while True:
        now_ts = time.time()
        with STATE_LOCK:
            for i in range(len(SCHEDULED_ALERTS) - 1, -1, -1):
                alert = SCHEDULED_ALERTS[i]
                if now_ts >= alert["time"]:
                    ALERT_QUEUE.put(alert["payload"])
                    SCHEDULED_ALERTS.pop(i)
        time.sleep(5)

def automated_test_worker():
    last_rwt_run = 0
    last_rmt_run = 0
    while True:
        time.sleep(30)
        now = datetime.now()
        config = load_taendec_config()
        sched_cfg = config.get("rwt_rmt_scheduler", {})
        t_day = int(sched_cfg.get("rwt_exact_day", "-1"))
        t_time = sched_cfg.get("rwt_exact_time", "")
        rwt_fips = sched_cfg.get("rwt_fips", "027145")
        if now.weekday() == t_day and now.strftime("%H:%M") == t_time and time.time() - last_rwt_run > 3600:
            last_rwt_run = time.time()
            ALERT_QUEUE.put({"type": "WEB", "originator": "EAS", "eventCode": "RWT", "duration": "0030", "fipsCodes": rwt_fips, "additionalText": sched_cfg.get("rwt_text", ""), "voice_wav_path": sched_cfg.get("rwt_voice", ""), "skip_translation_in_tts": False, "hasAudio": bool(sched_cfg.get("rwt_voice", ""))})
        rmt_week = int(sched_cfg.get("rmt_week", "-1"))
        rmt_day = int(sched_cfg.get("rmt_day", "-1"))
        rmt_time = sched_cfg.get("rmt_time", "")
        rmt_fips = sched_cfg.get("rmt_fips", "027145")
        if ((now.day - 1) // 7 + 1) == rmt_week and now.weekday() == rmt_day and now.strftime("%H:%M") == rmt_time and time.time() - last_rmt_run > 3600:
            last_rmt_run = time.time()
            ALERT_QUEUE.put({"type": "WEB", "originator": "EAS", "eventCode": "RMT", "duration": "0030", "fipsCodes": rmt_fips, "additionalText": sched_cfg.get("rmt_text", ""), "voice_wav_path": sched_cfg.get("rmt_voice", ""), "skip_translation_in_tts": False, "hasAudio": bool(sched_cfg.get("rmt_voice", ""))})

class APIHandler(BaseHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(200, "OK")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.end_headers()

    def verify_auth(self):
        config = load_taendec_config()
        sec = config.get("security", {})
        if not sec.get("require_auth", False): return True
        req_user, req_pass = sec.get("username", "admin"), sec.get("password", "taendec")
        auth_header = self.headers.get("Authorization")
        if not auth_header or not auth_header.startswith("Basic "): return self.send_auth_fail()
        try:
            u, p = base64.b64decode(auth_header.split(" ")[1]).decode("utf-8").split(":", 1)
            if u == req_user and p == req_pass: return True
        except: pass
        return self.send_auth_fail()

    def send_auth_fail(self):
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'x-Basic realm="TaENDEC"')
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"status": "Unauthorized"}).encode("utf-8"))
        return False

    def do_GET(self):
        if self.path.startswith("/archive/"):
            file_path = os.path.join(PERSISTENT_AUDIO_DIR, self.path.split("/")[-1])
            if os.path.exists(file_path):
                self.send_response(200)
                self.send_header("Content-Type", "audio/wav")
                self.end_headers()
                with open(file_path, "rb") as f: self.wfile.write(f.read())
            else: self.send_error(404, "File Not Found")
            return
        if not self.verify_auth(): return
        if self.path in ("/", "/status", "/api/status"):
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
            with STATE_LOCK: self.wfile.write(json.dumps({"endec_state": ENDEC_STATE, "monitored_streams": STREAM_STATUS, "queue_depth": ALERT_QUEUE.qsize(), "scheduled_count": len(SCHEDULED_ALERTS)}, indent=2).encode("utf-8"))
        elif self.path == "/api/history":
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
            self.wfile.write(json.dumps(ALERT_HISTORY).encode("utf-8"))
        elif self.path == "/api/config":
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
            self.wfile.write(json.dumps(load_taendec_config()).encode("utf-8"))
        elif self.path == "/api/fips":
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
            self.wfile.write(json.dumps(GLOBAL_FIPS_MAP).encode("utf-8"))
        else: self.send_response(404)

    def do_POST(self):
        if not self.verify_auth(): return
        try:
            payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])).decode("utf-8"))
            if self.path == "/api/config":
                with open(CONFIG_FILE, "w") as f: json.dump(payload, f, indent=2)
                self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
                self.wfile.write(json.dumps({"status": "Configuration Saved Successfully."}).encode("utf-8"))
                return
            if self.path == "/api/upload":
                file_path = os.path.join(UPLOAD_DIR, payload.get("filename"))
                b64data = payload.get("data")
                with open(file_path, "wb") as f: f.write(base64.b64decode(b64data.split(",")[1] if "," in b64data else b64data))
                self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
                self.wfile.write(json.dumps({"status": "Uploaded Successfully", "path": file_path}).encode("utf-8"))
                return
            if self.path in ("/api/transmit", "/api/schedule"):
                fips_list = payload.get("fipsCodes", "").split("-")
                filters = load_taendec_config().get("filters", {})
                if filters.get("enforce_fips_filtering", False):
                    allowed_states, allowed_fips = filters.get("allowed_state_prefixes", []), filters.get("allowed_fips_codes", [])
                    if not any(len(f) == 6 and (f[1:3] in allowed_states or f in allowed_fips) for f in fips_list):
                        self.send_response(400); self.send_header("Content-Type", "application/json"); self.end_headers()
                        self.wfile.write(json.dumps({"status": "TRANSMISSION REJECTED: Location blocked."}).encode("utf-8"))
                        return
                if self.path == "/api/transmit":
                    payload["type"] = "WEB"
                    ALERT_QUEUE.put(payload)
                    self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
                    self.wfile.write(json.dumps({"status": "Transmitting Live"}).encode("utf-8"))
                    return
                if self.path == "/api/schedule":
                    start_str = payload.get("startTime", "")
                    if "T" in start_str:
                        local_tz = tzlocal.get_localzone()
                        dt = datetime.strptime(start_str, "%Y-%m-%dT%H:%M").replace(tzinfo=local_tz) if len(start_str) == 16 else datetime.fromisoformat(start_str.replace("Z", "+00:00"))
                        payload["type"] = "WEB"
                        with STATE_LOCK: SCHEDULED_ALERTS.append({"time": dt.timestamp(), "payload": payload})
                        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
                        self.wfile.write(json.dumps({"status": f"Alert Scheduled for {dt.strftime('%Y-%m-%d %H:%M')}"}).encode("utf-8"))
                    return
        except Exception as e:
            logger.error(f"[API POST Error]: {e}"); self.send_response(500); self.end_headers()

if __name__ == "__main__":
    logger.info("TaENDEC Master Daemon Active (Engine v6.3.4 - Discord Webhook Hotfix)")
    launch_idle_screen()
    threading.Thread(target=dynamic_monitor_manager, daemon=True).start()
    threading.Thread(target=recording_timeout_worker, daemon=True).start()
    threading.Thread(target=background_audio_worker, daemon=True).start()
    threading.Thread(target=schedule_worker, daemon=True).start()
    threading.Thread(target=automated_test_worker, daemon=True).start()
    threading.Thread(target=alert_playback_worker, daemon=True).start()
    HTTPServer(("0.0.0.0", STATUS_SERVER_PORT), APIHandler).serve_forever()
EOF

# Update hardcoded paths in the generated Python script
sed -i "s|/home/endec|/home/$TARGET_USER|g" /tmp/endec_system.py

sudo mv /tmp/endec_system.py /home/$TARGET_USER/endec_system.py
sudo chmod +x /home/$TARGET_USER/endec_system.py

echo "--- [4/6] Creating Default Configuration (if missing) ---"
if [ ! -f /home/$TARGET_USER/taendec_config.json ]; then
cat << 'EOF' > /tmp/taendec_config.json
{
  "general": {
    "sender_id": "TaENDEC"
  },
  "outputs": {
    "enable_discord_webhook": false,
    "discord_webhook_url": "",
    "discord_username": "TaENDEC System",
    "discord_avatar_url": "",
    "enable_http_post": true,
    "tv_station_ip": "192.168.12.199",
    "tv_multicast_address": "224.0.0.1:36332"
  },
  "monitors": {},
  "details_channel": {
    "mode": "static_screen",
    "fallback_text": "Emergency Alert System\nDetails Channel\nMonitoring active."
  }
}
EOF
sudo mv /tmp/taendec_config.json /home/$TARGET_USER/taendec_config.json
fi

echo "--- [5/6] Setting Permissions ---"
sudo chown -R $TARGET_USER:$TARGET_USER /home/$TARGET_USER
sudo chown -R $TARGET_USER:$TARGET_USER /var/lib/eas_alerts
sudo chmod -R 755 /var/lib/eas_alerts

echo "--- [6/6] Configuring and Starting Systemd Service ---"
cat << EOF > /tmp/taendec.service
[Unit]
Description=TaENDEC Master Telemetry & Streaming Daemon
After=network.target sound.target

[Service]
Type=simple
User=$TARGET_USER
Group=$TARGET_USER
WorkingDirectory=/home/$TARGET_USER
ExecStart=/usr/bin/python3 /home/$TARGET_USER/endec_system.py
Restart=always
RestartSec=5
# Allow access to ALSA, DRM/KMS, and audio
SupplementaryGroups=audio video render

[Install]
WantedBy=multi-user.target
EOF

sudo mv /tmp/taendec.service /etc/systemd/system/taendec.service

sudo systemctl daemon-reload
sudo systemctl enable taendec.service
sudo systemctl restart taendec.service

echo ""
echo "========================================================="
echo " Installation Complete! "
echo " The TaENDEC daemon is now running under user: $TARGET_USER"
echo " Check status with: sudo systemctl status taendec"
echo " View live logs with: sudo journalctl -u taendec -f"
echo "========================================================="
