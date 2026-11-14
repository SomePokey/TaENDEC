import urllib.parse
#!/usr/bin/env python3
"""
TaENDEC Master Telemetry, IPAWS, NWS, MPV, & Streaming Daemon
"""

import os
import sys
import time
import subprocess

def execute_local_tts(engine, voice, text, output_file):
    import subprocess
    tts_bin = "/home/endec/tts_engines"
    eng = engine.lower()
    v = voice.lower()
    
    try:
        if eng == "dectalk":
            subprocess.run([f"{tts_bin}/dectalk", "-o", output_file, text], check=True)
            return True
        elif eng == "voicetext":
            subprocess.run([f"{tts_bin}/vtpaul", "--voice", v, text, "-o", output_file], check=True)
            return True
        elif eng == "loquendo":
            subprocess.run([f"{tts_bin}/loqdave", text, "-o", output_file], check=True)
            return True
        elif eng == "cepstral":
            subprocess.run([f"{tts_bin}/cep6", f"/opt/swift/voices/{v.capitalize()}", "text", text, output_file], check=True)
            return True
    except Exception as e:
        logger.error(f"Local TTS Engine '{eng}' failed: {e}")
    return False


# STREAM OVERRIDE STATE
STREAM_STATE = {
    "override_active": False,
    "override_url": "",
    "intro_mode": "before", 
    "intro_clip": "",
    "last_failure_time": None
}

import json
import wave
import math
import struct
import base64
import textwrap
import logging
import threading
import subprocess

def execute_local_tts(engine, voice, text, output_file):
    import subprocess
    tts_bin = "/home/endec/tts_engines"
    eng = engine.lower()
    v = voice.lower()
    
    try:
        if eng == "dectalk":
            subprocess.run([f"{tts_bin}/dectalk", "-o", output_file, text], check=True)
            return True
        elif eng == "voicetext":
            subprocess.run([f"{tts_bin}/vtpaul", "--voice", v, text, "-o", output_file], check=True)
            return True
        elif eng == "loquendo":
            subprocess.run([f"{tts_bin}/loqdave", text, "-o", output_file], check=True)
            return True
        elif eng == "cepstral":
            subprocess.run([f"{tts_bin}/cep6", f"/opt/swift/voices/{v.capitalize()}", "text", text, output_file], check=True)
            return True
    except Exception as e:
        logger.error(f"Local TTS Engine '{eng}' failed: {e}")
    return False

import queue
import re
import csv
import tzlocal
import platform
import hashlib
import secrets
import urllib.request
import xml.etree.ElementTree as ET
from http.server import HTTPServer, BaseHTTPRequestHandler
from datetime import datetime, timezone, timedelta
from http.cookies import SimpleCookie

try:
    import requests
except ImportError:
    requests = None

APP_USER = "endec"
LOG_DIR = f"/home/{APP_USER}/logs"
PERSISTENT_AUDIO_DIR = "/var/lib/eas_alerts/audio_archive"
UPLOAD_DIR = "/var/lib/eas_alerts/uploads"
CONFIG_FILE = f"/home/{APP_USER}/taendec_config.json"
CSV_FILE = f"/home/{APP_USER}/FIPS Codes.csv"

arch_str = "x86_64" if platform.machine() in ["x86_64", "AMD64"] else "x86"
SPFY_BIN_DIR = f"/home/{APP_USER}/spfy-linux-{arch_str}-2026.09.29"
SPFY_SYNTH_EXEC = os.path.join(SPFY_BIN_DIR, "bin", "spfy_synth")

os.makedirs(LOG_DIR, exist_ok=True)
os.makedirs(PERSISTENT_AUDIO_DIR, exist_ok=True)
os.makedirs(UPLOAD_DIR, exist_ok=True)

ALERT_LOG_FILE = os.path.join(LOG_DIR, "alert_history.log")
ALERT_WAV_FILE = os.path.join(PERSISTENT_AUDIO_DIR, "tts_temp.wav")
COMPILED_ALERT_WAV = os.path.join(PERSISTENT_AUDIO_DIR, "compiled_alert.wav")

STATUS_SERVER_PORT = 8085
LOCAL_HW_OUTPUT = "plughw:0,0"

MAX_RECORDING_TIMEOUT = 210
TRIM_FRONT_SEC = 4.5
TRIM_BACK_SEC = 1.8

SCHEDULED_ALERTS = []
ALERT_HISTORY = []
ALERT_QUEUE = queue.Queue()
ACTIVE_RECORDINGS = {}
MONITOR_FLAGS = {}
DEDUPE_CACHE = []
ICECAST_ALERT_FILE = None

MPV_PROCESS = None
STREAM_STATUS = {}
ENDEC_STATE = {"current_state": "IDLE / MONITORING", "active_alert": None, "last_event": None, "updated_at": datetime.now(timezone.utc).isoformat()}
STATE_LOCK = threading.Lock()
RECORDING_LOCK = threading.Lock()

# --- SECURITY MANAGER ---
SESSION_TOKEN = secrets.token_hex(16)

def session_rotation_worker():
    global SESSION_TOKEN
    while True:
        time.sleep(10)
        now = datetime.now()
        if now.minute == 1 and now.second < 15:
            SESSION_TOKEN = secrets.token_hex(16)
            time.sleep(60)

def hash_password(password, salt=None):
    if not salt: salt = secrets.token_hex(8)
    hashed = hashlib.pbkdf2_hmac('sha256', password.encode(), salt.encode(), 100000).hex()
    return f"{salt}:{hashed}"
    
def verify_password(password, stored_string):
    if not stored_string: return False
    if ":" not in stored_string: return password == stored_string
    salt, hashed = stored_string.split(":", 1)
    return hash_password(password, salt) == stored_string

def secure_config_password():
    try:
        with open(CONFIG_FILE, "r") as f: cfg = json.load(f)
        sec = cfg.get("security", {})
        if "password" in sec and sec["password"] and ":" not in sec["password"]:
            sec["password"] = hash_password(sec["password"])
            with open(CONFIG_FILE, "w") as f: json.dump(cfg, f, indent=2)
    except: pass
secure_config_password()

logger = logging.getLogger("ENDEC")
logger.setLevel(logging.INFO)
formatter = logging.Formatter("%(asctime)s.%(msecs)03d [TaENDEC] %(levelname)s: %(message)s", datefmt="%Y-%m-%d %H:%M:%S")
ch = logging.StreamHandler(sys.stdout)
ch.setFormatter(formatter)
logger.addHandler(ch)
fh = logging.FileHandler(ALERT_LOG_FILE)
fh.setFormatter(formatter)
logger.addHandler(fh)

EAS_EVENT_NAMES = {"ADR": "Administrative Message", "AVA": "Avalanche Watch", "AVW": "Avalanche Warning", "BLU": "Blue Alert", "BZW": "Blizzard Warning", "CAE": "Child Abduction Emergency", "CDA": "Civil Danger Watch", "CDW": "Civil Danger Warning", "CEM": "Civil Emergency Message", "CFA": "Coastal Flood Watch", "CFW": "Coastal Flood Warning", "DMO": "Demonstration Message", "DSW": "Dust Storm Warning", "EAN": "National Emergency Message", "EAT": "Emergency Action Termination", "EQW": "Earthquake Warning", "EVI": "Notice of Immediate Evacuation", "EWW": "Extreme Wind Warning", "FFA": "Flash Flood Watch", "FFS": "Flash Flood Statement", "FFW": "Flash Flood Warning", "FLA": "Flood Watch", "FLS": "Flood Statement", "FLW": "Flood Warning", "FRW": "Fire Warning", "FSW": "Flash Freeze Warning", "FZW": "Freeze Warning", "HLS": "Hurricane Local Statement", "HMW": "Hazardous Materials Warning", "HUA": "Hurricane Watch", "HUW": "Hurricane Warning", "HWA": "High Wind Watch", "HWW": "High Wind Warning", "LAE": "Local Area Emergency", "LEW": "Law Enforcement Warning", "MEP": "Notice of a Missing/Endangered Person", "NAT": "National Audible Test", "NIC": "National Information Center", "NMN": "Network Notification Message", "NPM": "Nuclear Power Plant Test", "NPT": "National Test of the Emergency Alert System", "NST": "National Silent Test", "NUW": "Nuclear Power Plant Warning", "POS": "Power Outage Statement", "RFW": "Red Flag Warning", "RHW": "Radiological Hazard Warning", "RMT": "Required Monthly Test", "RWT": "Required Weekly Test", "SCS": "School Closure Statement", "SMW": "Special Marine Warning", "SPS": "Special Weather Statement", "SPW": "Shelter In Place Warning", "SQW": "Snow Squall Warning", "SSA": "Storm Surge Watch", "SSW": "Storm Surge Warning", "SVA": "Severe Thunderstorm Watch", "SVR": "Severe Thunderstorm Warning", "SVS": "Severe Weather Statement", "TOA": "Tornado Watch", "TOE": "911 Telephone Outage Emergency", "TOR": "Tornado Warning", "TRA": "Tropical Storm Watch", "TRW": "Tropical Storm Warning", "TSA": "Tsunami Watch", "TSW": "Tsunami Warning", "VOW": "Volcano Warning", "WSA": "Winter Storm Watch", "WSW": "Winter Storm Warning", "BHW": "Biological Hazard Warning", "BWW": "Boil Water Warning", "CHW": "Chemical Hazard Warning", "CWW": "Contaminated Water Warning", "DBA": "Dam Watch", "DBW": "Dam Break Warning", "DEW": "Contagious Disease Warning", "EVA": "Evacuation Watch", "FCW": "Food Contamination Warning", "IBW": "Iceberg Warning", "IFW": "Industrial Fire Warning", "LSW": "Landslide Warning", "WFA": "Wildfire Watch", "WFW": "Wildfire Warning"}
EAS_ORIGINATORS = {"EAS": "An EAS Participant", "CIV": "The Civil Authorities", "WXR": "The National Weather Service", "PEP": "The Primary Entry Point System"}

WX_WARN = ["TOR", "SVR", "BZW", "CFW", "DSW", "HWW", "EWW", "FFW", "FLW", "HUW", "SQW", "SMW", "SSW", "TRW", "WSW", "RFW"]
CIV_EMERG = ["FRW", "MEP", "ADR", "TOE", "AVW", "AVA", "CAE", "EQW", "VOW", "TSW", "BWW", "BHW", "CHW", "CWW", "DBA", "DBW", "DEW", "FCW", "IBW", "IFW", "POS", "WFW", "WFA", "BLU", "CDA", "SCS", "LAE", "LEW", "CEM", "CDW", "SPW", "RHW", "NUW", "HMW", "EVI"]
TEST_ALERTS = ["RWT", "RMT", "DMO", "NPT", "NAT", "NST", "NPM"]
WATCH_ALERTS = ["CFA", "FFA", "FLA", "HWA", "HUA", "SVA", "SSA", "TOA", "TRA", "WSA"]
ADVISORY_ALERTS = ["FFS", "FLS", "HLS", "NMN", "SPS", "SVS"]

def detect_available_speechify_voices():
    en_us_dir = os.path.join(SPFY_BIN_DIR, "en-US")
    voices = ["tom", "jill", "aicraig", "crstom", "crsmara"]
    if os.path.exists(en_us_dir) and os.path.isdir(en_us_dir):
        detected = [d for d in os.listdir(en_us_dir) if os.path.isdir(os.path.join(en_us_dir, d))]
        if detected: voices.extend(detected)
    return sorted(list(set(voices)))

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
    if f_clean == "000000" or f_clean.endswith("000000"): return "United States"
    if len(f_clean) == 6: pca_prefix, base_fips = f_clean[0], f_clean[1:]
    else: pca_prefix, base_fips = "0", f_clean
    base_name = GLOBAL_FIPS_MAP.get(base_fips, f"County code {base_fips}")
    prefix_map = {"1": "Northwestern", "2": "Northern", "3": "Northeastern", "4": "Western", "5": "Central", "6": "Eastern", "7": "Southwestern", "8": "Southern", "9": "Southeastern"}
    if pca_prefix in prefix_map and pca_prefix != "0" and "," in base_name:
        county, state = base_name.split(",", 1)
        return f"{prefix_map[pca_prefix]} {county.strip()}, {state.strip()}"
    return base_name

def is_duplicate(raw_header):
    config = load_taendec_config()
    dedupe_cfg = config.get("deduplication", {})
    if not dedupe_cfg.get("enabled", True): return False
    grace_period_min = max(1, min(7, int(dedupe_cfg.get("grace_period", 3))))
    grace_period_sec = grace_period_min * 60
    
    header_clean = raw_header.replace("EAS:", "").strip("-")
    parts = header_clean.split("-")
    
    try:
        plus_idx = next(i for i, p in enumerate(parts) if '+' in p)
        core_header = "-".join(parts[:plus_idx+1])
    except StopIteration:
        core_header = "-".join(parts[:4])
        
    now = time.time()
    for i, (past_hdr, first_ts) in enumerate(DEDUPE_CACHE):
        if past_hdr == core_header:
            if now - first_ts <= grace_period_sec:
                logger.info(f"Dropped Duplicate Alert via Deduplication: {core_header}")
                return True
            else:
                DEDUPE_CACHE[i] = (core_header, now)
                return False
                
    DEDUPE_CACHE.append((core_header, now))
    if len(DEDUPE_CACHE) > 50: DEDUPE_CACHE.pop(0)
    return False

def is_in_alerting_area(raw_header):
    config = load_taendec_config()
    filters = config.get("filters", {})
    if not filters.get("enforce_fips_filtering", False): return True
    
    allowed_states = filters.get("allowed_state_prefixes", ["27", "91"])
    allowed_fips = filters.get("allowed_fips_codes", [])
    adv_filters_text = filters.get("advanced_filters", "")
    
    adv_filters = {}
    for line in adv_filters_text.split("\n"):
        if ":" in line:
            f, evts = line.split(":", 1)
            adv_filters[f.strip()] = [e.strip().upper() for e in evts.split(",") if e.strip()]
            
    header_clean = raw_header.replace("EAS:", "").strip("-")
    parts = header_clean.split("-")
    evt_code = parts[2] if len(parts) > 2 else ""
    
    try:
        fips_match = re.search(r"-([0-9\-]+)\+", raw_header)
        if not fips_match: return True
        header_fips = [f.strip() for f in fips_match.group(1).split("-") if len(f.strip()) == 6]
        
        has_adv = bool(adv_filters)
        for fips in header_fips:
            if has_adv and fips in adv_filters:
                if evt_code in adv_filters[fips]: return True
            else:
                if (fips[1:3] in allowed_states) or (fips in allowed_fips): return True
        return False
    except: return True

def get_utc_header_timestamp():
    return datetime.now(timezone.utc).strftime("%j%H%M")

def parse_same_timestamp(jjjhhmm):
    if not jjjhhmm or len(jjjhhmm) != 7 or not jjjhhmm.isdigit(): return None
    try:
        jjj = int(jjjhhmm[:3])
        hh = int(jjjhhmm[3:5])
        mm = int(jjjhhmm[5:7])
        now_utc = datetime.now(timezone.utc)
        year = now_utc.year
        if now_utc.month == 1 and jjj > 350: year -= 1
        elif now_utc.month == 12 and jjj < 15: year += 1
        return datetime(year, 1, 1, tzinfo=timezone.utc) + timedelta(days=jjj-1, hours=hh, minutes=mm)
    except: return None

def translate_same_to_speech(header_str, start_time_dt=None, is_visual=False):
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

    timestamp_match = re.search(r"\+[0-9]{4}-([0-9]{7})-", header_str)
    if timestamp_match:
        parsed_dt = parse_same_timestamp(timestamp_match.group(1))
        if parsed_dt: start_time_dt = parsed_dt
        
    config = load_taendec_config()
    sender_clean = parts[-1].strip() if len(parts) > 5 else config.get("general", {}).get("sender_id", "TaENDEC").strip()
    org_name = EAS_ORIGINATORS.get(org_code, "An EAS Participant")
    evt_name = EAS_EVENT_NAMES.get(evt_code, f"{evt_code} Alert")
    loc_string = "; ".join([get_county_name(f) for f in fips_codes]) if fips_codes else "the affected areas"
    
    if not start_time_dt: start_time_dt = datetime.now(local_tz)
    else: start_time_dt = start_time_dt.astimezone(local_tz)
    end_time_dt = start_time_dt + timedelta(hours=dur_hh, minutes=dur_mm)
    
    start_str = start_time_dt.strftime("%I:%M %p on %B %d").replace(" 0", " ")
    end_str = end_time_dt.strftime("%I:%M %p on %B %d").replace(" 0", " ")
    prefix = f"{org_name} have issued a {evt_name}" if org_code == "CIV" else f"{org_name} has issued a {evt_name}"
    
    base_msg = f"{prefix} for the following areas: {loc_string}; starting at {start_str}, effective until {end_str}."
    if config.get("tts_settings", {}).get("skip_sender_id", False) and not is_visual: return base_msg
    return f"{base_msg} This message is from {sender_clean}."

def format_custom_template_vars(raw_header, additional_text="", compiled_wav_path=""):
    try: local_tz = tzlocal.get_localzone()
    except: local_tz = datetime.now().astimezone().tzinfo
    header_clean = raw_header.replace("EAS:", "").strip("-")
    parts = header_clean.split("-")
    
    org_code = parts[1] if len(parts) > 1 else "EAS"
    evt_code = parts[2] if len(parts) > 2 else "ADR"
    fips_codes = []
    fips_match = re.search(r"-([0-9\-]+)\+", raw_header)
    if fips_match: fips_codes = [f.strip() for f in fips_match.group(1).split("-") if f.strip()]
    
    etime = "0030"
    dur_match = re.search(r"\+([0-9]{4})", raw_header)
    if dur_match: etime = dur_match.group(1)
    
    jjjhhmm = parts[4] if len(parts) > 4 else "0000000"
    sender_id = parts[-1].strip() if len(parts) > 5 else "TaENDEC"
    lorigin = EAS_ORIGINATORS.get(org_code, "An EAS Participant")
    levent = EAS_EVENT_NAMES.get(evt_code, f"{evt_code} Alert")
    sameco = "-".join(fips_codes)
    
    c_names = [get_county_name(f) for f in fips_codes]
    nameco = "; ".join(c_names) + (";" if c_names else "")
    if len(c_names) > 1: dfnameco = ", ".join(c_names[:-1]) + " and " + c_names[-1]
    elif c_names: dfnameco = c_names[0]
    else: dfnameco = ""
        
    dur_hh, dur_mm = int(etime[:2]), int(etime[2:])
    
    parsed_dt = parse_same_timestamp(jjjhhmm)
    if parsed_dt: start_time_dt = parsed_dt.astimezone(local_tz)
    else: start_time_dt = datetime.now(local_tz)
        
    end_time_dt = start_time_dt + timedelta(hours=dur_hh, minutes=dur_mm)
    
    hissue = start_time_dt.strftime("starting at %I:%M %p on %B %d").replace(" 0", " ")
    hetime = end_time_dt.strftime("effective until %I:%M %p on %B %d").replace(" 0", " ")
    transtext = translate_same_to_speech(raw_header, start_time_dt, is_visual=True)
    config = load_taendec_config()
    base_url = config.get("outputs", {}).get("public_base_url", f"http://127.0.0.1:{STATUS_SERVER_PORT}").rstrip('/')
    audio_url = f"{base_url}/archive/{os.path.basename(compiled_wav_path)}" if compiled_wav_path else ""
    
    return {
        "${ORIGIN}": org_code, "${LORIGIN}": lorigin, "${EVENT}": evt_code, "${LEVENT}": levent,
        "${SAMECO}": sameco, "${NAMECO}": nameco, "${DFNAMECO}": dfnameco, "${ETIME}": etime,
        "${HETIME}": hetime, "${JJJHHMM}": jjjhhmm, "${HISSUE}": hissue, "${SENDERID}": sender_id,
        "${HEADER}": raw_header, "${TRANSTEXT}": transtext, "${ADDTEXT}": additional_text, "${AUDIO_URL}": audio_url
    }

def dispatch_http_endpoints(raw_header, additional_text="", compiled_wav_path=""):
    config = load_taendec_config()
    outputs = config.get("outputs", {})
    if not outputs.get("enable_http_post", True): return
    endpoints = outputs.get("http_endpoints", [])
    var_map = format_custom_template_vars(raw_header, additional_text, compiled_wav_path)
    for ep in endpoints:
        target_url = ep.get("url")
        if not target_url: continue
        final_body = ep.get("body", "")
        for k, v in var_map.items(): final_body = final_body.replace(k, str(v))
        try:
            req = urllib.request.Request(target_url, data=final_body.encode("utf-8"), headers={"Content-Type": "application/json"}, method="POST")
            urllib.request.urlopen(req, timeout=10)
        except Exception as e: logger.error(f"HTTP POST error to {target_url}: {e}")

def notify_tv_alert_done(raw_header):
    config = load_taendec_config()
    target_url = config.get("outputs", {}).get("tv_station_api_url", "")
    if not target_url: return
    done_url = target_url.rsplit("/", 1)[0] + "/done"
    try: urllib.request.urlopen(urllib.request.Request(done_url, data=json.dumps({"status": "COMPLETED", "raw_header": raw_header}).encode("utf-8"), headers={"Content-Type": "application/json"}, method="POST"), timeout=10)
    except: pass

def dispatch_discord_webhook(raw_header, additional_text="", wav_path=None):
    if not requests: return
    config = load_taendec_config()
    outputs = config.get("outputs", {})
    if not outputs.get("enable_discord_webhook", False): return
    webhook_urls = outputs.get("discord_webhook_urls", [])
    if not webhook_urls: return
    if isinstance(webhook_urls, str): webhook_urls = [u.strip() for u in webhook_urls.split(",") if u.strip()]

    parts = raw_header.replace("EAS:", "").strip("-").split("-")
    if len(parts) < 5: return
    org_code, evt_code = parts[1], parts[2]
    fips_match = re.search(r"-([0-9\-]+)\+", raw_header)
    fips_codes = [f.strip() for f in fips_match.group(1).split("-") if f.strip()] if fips_match else []
    dur_match = re.search(r"\+([0-9]{4})", raw_header)
    dur_hh, dur_mm = (int(dur_match.group(1)[:2]), int(dur_match.group(1)[2:])) if dur_match else (0, 30)
    sender = parts[-1].strip() if len(parts) > 5 else "TaENDEC"
    
    if evt_code in WX_WARN or evt_code in CIV_EMERG: color = 16711680; sev_str = "🔴 Extreme / Immediate"; icon = "🚨"
    elif evt_code in WATCH_ALERTS: color = 16766464; sev_str = "🟡 Severe / Expected"; icon = "⚠️"
    elif evt_code in TEST_ALERTS: color = 255; sev_str = "🔵 Routine Test"; icon = "ℹ️"
    else: color = 65280; sev_str = "🟢 Moderate / Advisory"; icon = "📢"
        
    try: local_tz = tzlocal.get_localzone()
    except: local_tz = datetime.now().astimezone().tzinfo
    now = datetime.now(local_tz)
    end_unix = int((now + timedelta(hours=dur_hh, minutes=dur_mm)).timestamp())
    
    area_list = "\n".join([f"• {get_county_name(f)}" for f in fips_codes]) if fips_codes else "Unknown Area"
    desc = translate_same_to_speech(raw_header, now, is_visual=True)
    if additional_text: desc += f"{chr(10)}{chr(10)}Additional Details:{chr(10)}{additional_text}"

    embed_fields = [
        {"name": "📡 Originator", "value": EAS_ORIGINATORS.get(org_code, "Unknown"), "inline": True},
        {"name": "⚠️ Severity", "value": sev_str, "inline": True},
        {"name": "📅 Expiration Time", "value": f"<t:{end_unix}:F>\n(<t:{end_unix}:R>)", "inline": False},
        {"name": "📍 Affected Areas", "value": area_list, "inline": False},
        {"name": "📟 Raw SAME Header", "value": f"```\n{raw_header}\n```", "inline": False}
    ]
    
    has_audio = wav_path and os.path.exists(wav_path)
    if has_audio: embed_fields.insert(2, {"name": "📻 Audio Capture", "value": "Listen to the broadcast audio attached below.", "inline": True})

    payload = {
        "username": outputs.get("discord_username") or "TaENDEC System",
        "embeds": [{
            "title": f"{icon} {EAS_EVENT_NAMES.get(evt_code, evt_code).upper()} [{evt_code}]",
            "description": desc, "color": color, "timestamp": datetime.now(timezone.utc).isoformat(),
            "fields": embed_fields, "footer": {"text": f"Sender: {sender} • TaENDEC Master"}
        }]
    }

    if outputs.get("discord_ping_content"): payload["content"] = outputs.get("discord_ping_content")
    if outputs.get("discord_avatar_url"): payload["avatar_url"] = outputs.get("discord_avatar_url")
    for url in webhook_urls:
        try:
            if has_audio:
                with open(wav_path, "rb") as audio_file:
                    requests.post(url, files={"payload_json": (None, json.dumps(payload), "application/json"), "files[0]": (os.path.basename(wav_path), audio_file, "audio/wav")}, timeout=15)
            else: requests.post(url, json=payload, timeout=10)
        except Exception as e: logger.error(f"Discord error: {e}")

def dispatch_gotify_notification(raw_header, additional_text=""):
    if not requests: return
    config = load_taendec_config()
    gotify = config.get("outputs", {}).get("gotify", {})
    if not gotify.get("enabled", False): return
    
    server_url = gotify.get("url", "").rstrip("/")
    token = gotify.get("token", "")
    if not server_url or not token: return
    
    parts = raw_header.replace("EAS:", "").strip("-").split("-")
    org_code = parts[1] if len(parts) > 1 else "CIV"
    evt_code = parts[2] if len(parts) > 2 else "ADR"
    
    try: local_tz = tzlocal.get_localzone()
    except: local_tz = datetime.now().astimezone().tzinfo
    now = datetime.now(local_tz)
    
    desc = translate_same_to_speech(raw_header, now, is_visual=True)
    if additional_text: desc += f"{chr(10)}{chr(10)}Additional Details:{chr(10)}{additional_text}"
    
    # Priority is hardcoded to 105 for Alertify-Android processing
    priority = 105
    
    # Custom Alertify Titles / Categories Routing
    etws_list = [x.strip().upper() for x in gotify.get("etws_events", "").split(",") if x.strip()]
    etws_test_list = [x.strip().upper() for x in gotify.get("etws_test_events", "").split(",") if x.strip()]
    literal_list = [x.strip().upper() for x in gotify.get("literal_title_events", "").split(",") if x.strip()]
    
    route_adr = gotify.get("route_adr", "Public")
    route_adv = gotify.get("route_advisory", "Severe")
    eas_adr_bcast = gotify.get("eas_adr_broadcast", False)
    
    alert_title = "Severe" # Fallback
    
    if evt_code in etws_list: alert_title = "ETWS"
    elif evt_code in etws_test_list: alert_title = "ETWSTest"
    elif evt_code in literal_list: alert_title = evt_name
    elif evt_code in ["EAN", "NPT", "EAT"]: alert_title = "President"
    elif evt_code == "EQW": alert_title = "Earthquake"
    elif evt_code in ["TSW", "TSA"]: alert_title = "Tsunami"
    elif evt_code == "CAE": alert_title = "Amber"
    elif evt_code == "RMT": alert_title = "RMT"
    elif evt_code in ["RWT", "DMO"]: alert_title = "StateTest"
    elif evt_code in ["TOR", "HWW", "EVI", "FRW", "NUW", "HMW"]: alert_title = "Extreme"
    elif evt_code == "NMN": alert_title = "Broadcast"
    elif evt_code == "ADR":
        if route_adr == "Broadcast": alert_title = "Broadcast"
        elif org_code == "EAS" and eas_adr_bcast: alert_title = "Broadcast"
        elif route_adr == "Severe": alert_title = "Severe"
        else: alert_title = "Public"
    elif evt_code in ADVISORY_ALERTS and evt_code != "NMN":
        alert_title = "Severe" if route_adv == "Severe" else "Public"
    elif evt_code in WX_WARN or evt_code in WATCH_ALERTS:
        alert_title = "Severe"
    elif evt_code in CIV_EMERG:
        alert_title = "Public"

    payload = {
        "title": alert_title,
        "message": desc,
        "priority": priority
    }
    
    try:
        requests.post(f"{server_url}/message?token={token}", json=payload, timeout=10)
    except Exception as e:
        logger.error(f"Gotify error: {e}")

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
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", file_path, "-ar", str(sample_rate), "-ac", "1", "/tmp/clip_norm.wav"], check=True)
        with wave.open("/tmp/clip_norm.wav", "rb") as wf: return list(struct.unpack(f"<{wf.getnframes()}h", wf.readframes(wf.getnframes())))
    except: return []

def compile_full_eas_audio(raw_header, recorded_wav_path=None, tts_text="", output_wav_path=COMPILED_ALERT_WAV):
    sample_rate = 22050
    header_clean = raw_header.replace("EAS:", "").strip()
    evt_code = header_clean.split("-")[2] if len(header_clean.split("-")) > 2 else "ADR"
    
    config = load_taendec_config()
    ap_config = config.get("audio_processing", {})
    gen_config = config.get("general", {})
    
    cat_prefix, cat_suffix = "", ""
    if evt_code == "EAN": cat_prefix, cat_suffix = ap_config.get("prefixes", {}).get("NATIONAL_EMERGENCY", ""), ap_config.get("suffixes", {}).get("NATIONAL_EMERGENCY", "")
    elif evt_code in TEST_ALERTS: cat_prefix, cat_suffix = ap_config.get("prefixes", {}).get("TEST", ""), ap_config.get("suffixes", {}).get("TEST", "")
    elif evt_code in WX_WARN: cat_prefix, cat_suffix = ap_config.get("prefixes", {}).get("WEATHER_WARNING", ""), ap_config.get("suffixes", {}).get("WEATHER_WARNING", "")
    elif evt_code in CIV_EMERG: cat_prefix, cat_suffix = ap_config.get("prefixes", {}).get("CIVIL_EMERGENCY", ""), ap_config.get("suffixes", {}).get("CIVIL_EMERGENCY", "")
    elif evt_code in WATCH_ALERTS: cat_prefix, cat_suffix = ap_config.get("prefixes", {}).get("WATCH", ""), ap_config.get("suffixes", {}).get("WATCH", "")
    elif evt_code in ADVISORY_ALERTS: cat_prefix, cat_suffix = ap_config.get("prefixes", {}).get("ADVISORY", ""), ap_config.get("suffixes", {}).get("ADVISORY", "")
    
    prefix_path = cat_prefix or ap_config.get("prefixes", {}).get("ALL_ALERTS", "")
    suffix_path = cat_suffix or ap_config.get("suffixes", {}).get("ALL_ALERTS", "")
    
    prefix_placement = ap_config.get("prefix_placement", "before_headers") if evt_code == "EAN" else "before_headers"
    suffix_placement = ap_config.get("suffix_placement", "after_eom") if evt_code == "EAN" else "after_eom"
    before_alert_path = ap_config.get("before_alert_clip", "") if evt_code == "EAN" else ""

    master_samples = []
    voice_samples = []
    has_audio_payload = False

    if recorded_wav_path and os.path.exists(recorded_wav_path) and os.path.getsize(recorded_wav_path) > 1000:
        has_audio_payload = True
        try:
            if "raw_capture" in recorded_wav_path:
                with wave.open(recorded_wav_path, "rb") as wf: all_voice_samples = list(struct.unpack(f"<{wf.getnframes()}h", wf.readframes(wf.getnframes())))
                trim_start, trim_end = int(sample_rate * TRIM_FRONT_SEC), len(all_voice_samples) - int(sample_rate * TRIM_BACK_SEC)
                voice_samples = all_voice_samples[trim_start:trim_end] if trim_end > trim_start else all_voice_samples
            else: voice_samples = get_audio_clip_samples(recorded_wav_path, sample_rate)
        except Exception as e: logger.error(f"Failed recorded audio: {e}")
    elif tts_text:
        has_audio_payload = True
        try:
            tts_text_clean = tts_text.replace("SpeX", "Specs")
            
            tts_engine_choice = gen_config.get("tts_engine", "speechify").lower()
            tts_voice_choice = gen_config.get("speechify_voice", "tom").lower()
            tts_bin_dir = "/home/endec/tts_engines"
            
            if tts_engine_choice == "dectalk":
                subprocess.run([f"{tts_bin_dir}/dectalk", "-o", ALERT_WAV_FILE, tts_text_clean], check=True)
            elif tts_engine_choice == "voicetext":
                subprocess.run([f"{tts_bin_dir}/vtpaul", "--voice", tts_voice_choice, tts_text_clean, "-o", ALERT_WAV_FILE], check=True)
            elif tts_engine_choice == "loquendo":
                subprocess.run([f"{tts_bin_dir}/loqdave", tts_text_clean, "-o", ALERT_WAV_FILE], check=True)
            elif tts_engine_choice == "cepstral":
                subprocess.run([f"{tts_bin_dir}/cep6", f"/opt/swift/voices/{tts_voice_choice.capitalize()}", "text", tts_text_clean, ALERT_WAV_FILE], check=True)
            elif tts_engine_choice == "speechify" and os.path.exists(SPFY_SYNTH_EXEC):
                subprocess.run([SPFY_SYNTH_EXEC, os.path.join(SPFY_BIN_DIR, "en-US", tts_voice_choice), tts_text_clean, ALERT_WAV_FILE], check=True)
            else:
                subprocess.run(["espeak-ng", "-v", "en-us", "-s", "150", "-p", "40", tts_text_clean, "-w", ALERT_WAV_FILE], check=True)
            
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", ALERT_WAV_FILE, "-ar", "22050", "-ac", "1", "/tmp/tts_norm.wav"], check=True)
            with wave.open("/tmp/tts_norm.wav", "rb") as wf: voice_samples = list(struct.unpack(f"<{wf.getnframes()}h", wf.readframes(wf.getnframes())))
        except Exception as e: logger.error(f"TTS synth error: {e}")

    prefix_samples, suffix_samples, before_samples = get_audio_clip_samples(prefix_path, sample_rate), get_audio_clip_samples(suffix_path, sample_rate), get_audio_clip_samples(before_alert_path, sample_rate)

    if prefix_placement == "before_headers" and prefix_samples: master_samples.extend(prefix_samples); master_samples.extend([0] * int(sample_rate * 0.5))
    master_samples.extend(generate_afsk_burst_samples(header_clean, 3, sample_rate))
    if prefix_placement == "after_headers" and prefix_samples: master_samples.extend([0] * int(sample_rate * 0.5)); master_samples.extend(prefix_samples)

    if has_audio_payload:
        master_samples.extend([0] * int(sample_rate * 0.5)); master_samples.extend(generate_attention_signal_samples(8.0, sample_rate))
        if before_samples: master_samples.extend([0] * int(sample_rate * 0.5)); master_samples.extend(before_samples)
        master_samples.extend([0] * int(sample_rate * 0.5))
        if voice_samples: master_samples.extend(voice_samples)

    if suffix_placement == "before_eom" and suffix_samples: master_samples.extend([0] * int(sample_rate * 0.5)); master_samples.extend(suffix_samples)
    master_samples.extend([0] * int(sample_rate * 0.5)); master_samples.extend(generate_afsk_burst_samples("NNNN", 3, sample_rate))
    if suffix_placement == "after_eom" and suffix_samples: master_samples.extend([0] * int(sample_rate * 0.5)); master_samples.extend(suffix_samples)

    persistent_wav_path = os.path.join(PERSISTENT_AUDIO_DIR, f"alert_{datetime.now().strftime('%Y%m%d_%H%M%S')}.wav")
    with wave.open(persistent_wav_path, "wb") as master_wf:
        master_wf.setnchannels(1); master_wf.setsampwidth(2); master_wf.setframerate(sample_rate)
        packed_data = bytearray()
        for s in master_samples: packed_data.extend(struct.pack("<h", max(-32768, min(32767, s))))
        master_wf.writeframes(packed_data)
    if os.path.exists(output_wav_path): os.remove(output_wav_path)
    os.link(persistent_wav_path, output_wav_path)
    return persistent_wav_path, os.path.basename(persistent_wav_path)

def start_software_recording(stream_name, raw_header):
    file_path = os.path.join(PERSISTENT_AUDIO_DIR, f"raw_capture_{''.join([c if c.isalnum() else '_' for c in stream_name])}.wav")
    wav_handle = wave.open(file_path, "wb")
    wav_handle.setnchannels(1); wav_handle.setsampwidth(2); wav_handle.setframerate(22050)
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
        with RECORDING_LOCK: timed_out = [s for s, r in ACTIVE_RECORDINGS.items() if time.time() - r["start_time"] > MAX_RECORDING_TIMEOUT]
        for s in timed_out: finalize_and_enqueue_alert(s)

def launch_idle_screen():
    global MPV_PROCESS
    if MPV_PROCESS and MPV_PROCESS.poll() is None:
        MPV_PROCESS.terminate()
        try: MPV_PROCESS.wait(2)
        except: MPV_PROCESS.kill()
    config = load_taendec_config()
    mode = config.get("details_channel", {}).get("mode", "static_screen")
    if mode == "off": return
    cmd = []
    if mode == "static_screen":
        pages = config.get("details_channel", {}).get("fallback_text", "EAS Details Channel").split("${newpage}")
        generated_images = []
        total = len(pages)
        for idx, page_text in enumerate(pages):
            wrapped = []
            for line in page_text.strip().split("\n"): wrapped.extend(textwrap.wrap(line, 50)) if line.strip() else wrapped.append("")
            txt_path, img_path = f"/tmp/idle_txt_{idx}.txt", f"/tmp/idle_card_{idx}.png"
            with open(txt_path, "w") as f: f.write("\n".join(wrapped))
            page_str = f",drawtext=font='Sans':text='Page {idx+1} of {total}':x=1650:y=1000:fontsize=36:fontcolor=white" if total > 1 else ""
            filtergraph = f"drawbox=w=1920:h=1080:color=0x000033@1.0:t=fill,drawtext=font='Sans':text='EAS DETAILS CHANNEL':x=(w-text_w)/2:y=100:fontsize=72:fontcolor=white,drawtext=font='Sans':textfile='{txt_path}':x=120:y=250:fontsize=48:fontcolor=yellow:line_spacing=24{page_str}"
            subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i", "color=c=black:s=1920x1080", "-vf", filtergraph, "-vframes", "1", img_path])
            generated_images.append(img_path)
        cmd = ["mpv", "--vo=gpu", "--gpu-context=drm", "--drm-device=/dev/dri/card0", "--loop-file=inf", generated_images[0]] if len(generated_images) == 1 else ["mpv", "--vo=gpu", "--gpu-context=drm", "--drm-device=/dev/dri/card0", "--image-display-duration=10", "--loop-playlist=inf"] + generated_images
    elif mode in ["media_stream", "youtube"] and config.get("details_channel", {}).get("media_url", ""):
        cmd = ["mpv", "--vo=gpu", "--gpu-context=drm", "--drm-device=/dev/dri/card0", "--loop-file=inf", config.get("details_channel", {}).get("media_url", "")]
    if cmd:
        try: MPV_PROCESS = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        except: pass

def generate_alert_card(translated_text, additional_text=""):
    if load_taendec_config().get("details_channel", {}).get("mode", "static_screen") == "off": return []
    body = []
    if translated_text.strip(): body.extend(textwrap.wrap(translated_text.replace("%", "\\%").strip(), 48))
    if additional_text.strip():
        if body: body.append("")
        body.extend(textwrap.wrap(additional_text.replace("%", "\\%").strip(), 48))
    pages = [body[i:i + 11] for i in range(0, len(body), 11)] or [["AN EMERGENCY ALERT HAS BEEN ISSUED"]]
    generated = []
    total = len(pages)
    for idx, page in enumerate(pages):
        txt_path, img_path = f"/tmp/card_text_{idx}.txt", f"/tmp/alert_card_{idx}.png"
        with open(txt_path, "w") as f: f.write("\n".join(page))
        page_str = f",drawtext=font='Sans':text='Page {idx+1} of {total}':x=1650:y=1000:fontsize=36:fontcolor=white" if total > 1 else ""
        filtergraph = f"drawbox=w=1920:h=180:color=0x8b0000@1.0:t=fill,drawtext=font='Sans':text='EMERGENCY ALERT SYSTEM':x=(w-text_w)/2:y=55:fontsize=72:fontcolor=white,drawbox=y=180:w=1920:h=6:color=0xff0000@1.0:t=fill,drawtext=font='Sans':textfile='{txt_path}':x=120:y=280:fontsize=48:fontcolor=yellow:line_spacing=24{page_str}"
        try:
            subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i", "color=c=0x0a0a0a:s=1920x1080", "-vf", filtergraph, "-vframes", "1", img_path], check=True)
            generated.append(img_path)
        except Exception as e: logger.error(f"Failed video card: {e}")
    return generated

def launch_mpv_display(media_sources):
    global MPV_PROCESS
    if load_taendec_config().get("details_channel", {}).get("mode", "static_screen") == "off": return
    if MPV_PROCESS and MPV_PROCESS.poll() is None:
        MPV_PROCESS.terminate()
        try: MPV_PROCESS.wait(2)
        except: MPV_PROCESS.kill()
    if not media_sources: return
    cmd = ["mpv", "--vo=gpu", "--gpu-context=drm", "--drm-device=/dev/dri/card0", "--image-display-duration=inf", media_sources[0]] if len(media_sources) == 1 else ["mpv", "--vo=gpu", "--gpu-context=drm", "--drm-device=/dev/dri/card0", "--image-display-duration=5", "--loop-playlist=inf"] + media_sources
    try: MPV_PROCESS = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    except: pass

def stop_mpv_display(): launch_idle_screen()

def gapless_icecast_worker():
    global ICECAST_ALERT_FILE
    config = load_taendec_config()
    ice = config.get("icecast", {})
    if not ice.get("enabled", False) or not ice.get("server_url"): return
        
    server_url = ice.get("server_url")
    tech_diff_path = ice.get("tech_diff_file", "")
    
    master_cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error",
        "-f", "s16le", "-ar", "22050", "-ac", "1", "-i", "pipe:0",
        "-c:a", "libmp3lame", "-b:a", "128k", "-content_type", "audio/mpeg",
        "-f", "mp3", server_url
    ]
    master_proc = subprocess.Popen(master_cmd, stdin=subprocess.PIPE)
    
    bg_proc = None
    tech_proc = None
    intro_proc = None
    last_bg_retry = 0
    current_state_was_override = False
    intro_duck_pending = False
    
    def spawn_audio_proc(url):
        if not url: return None
        cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", url, "-f", "s16le", "-ar", "22050", "-ac", "1", "-"]
        return subprocess.Popen(cmd, stdout=subprocess.PIPE)
        
    def get_active_stream():
        config = load_taendec_config()
        normal_url = config.get("icecast", {}).get("bg_music_url", "")
        with STATE_LOCK:
            active = STREAM_STATE.get("override_active", False)
            override_url = STREAM_STATE.get("override_url", "")
            fail_time = STREAM_STATE.get("last_failure_time")
            
        if active and fail_time and (time.time() - fail_time > 120):
            logger.info("Override stream failed to recover. Reverting to normal.")
            with STATE_LOCK:
                STREAM_STATE["override_active"] = False
                active = False
                
        if not active:
            return normal_url, False
            
        actual_url = override_url
        if "youtube.com" in override_url or "youtu.be" in override_url:
            try: actual_url = subprocess.check_output(["yt-dlp", "-f", "bestaudio", "-g", override_url]).decode().strip()
            except Exception as e:
                logger.error(f"yt-dlp failed: {e}")
                if not fail_time:
                    with STATE_LOCK: STREAM_STATE["last_failure_time"] = time.time()
                return None, True
                
        with STATE_LOCK: STREAM_STATE["last_failure_time"] = None
        return actual_url, True

    while True:
        if ICECAST_ALERT_FILE and os.path.exists(ICECAST_ALERT_FILE):
            if bg_proc: bg_proc.kill(); bg_proc = None
            if tech_proc: tech_proc.kill(); tech_proc = None
            if intro_proc: intro_proc.kill(); intro_proc = None
            
            alert_proc = subprocess.Popen(["ffmpeg", "-hide_banner", "-loglevel", "error", "-re", "-i", ICECAST_ALERT_FILE, "-f", "s16le", "-ar", "22050", "-ac", "1", "-"], stdout=subprocess.PIPE)
            while ICECAST_ALERT_FILE:
                chunk = alert_proc.stdout.read(4096)
                if not chunk: break
                try: master_proc.stdin.write(chunk); master_proc.stdin.flush()
                except: break
            alert_proc.kill()
            ICECAST_ALERT_FILE = None
            last_bg_retry = 0
            continue

        with STATE_LOCK:
            active_now = STREAM_STATE.get("override_active", False)
            intro_clip = STREAM_STATE.get("intro_clip", "")
            intro_mode = STREAM_STATE.get("intro_mode", "before")
        
        if active_now != current_state_was_override:
            if bg_proc: bg_proc.kill(); bg_proc = None
            if intro_proc: intro_proc.kill(); intro_proc = None
            current_state_was_override = active_now
            last_bg_retry = 0
            intro_duck_pending = False
            
            if active_now and intro_clip and os.path.exists(intro_clip):
                if intro_mode == "before":
                    intro_proc = spawn_audio_proc(intro_clip)
                elif intro_mode == "duck":
                    intro_duck_pending = True
                
        chunk = None
        
        if intro_proc:
            chunk = intro_proc.stdout.read(4096)
            if not chunk:
                intro_proc.kill(); intro_proc = None
        
        if not chunk and bg_proc and bg_proc.poll() is None:
            chunk = bg_proc.stdout.read(4096)
            
            # SEAMLESS TRANSITION: Only kill tech_diff if the BG stream successfully delivers audio
            if chunk and tech_proc:
                tech_proc.kill(); tech_proc = None
            
        if not chunk and not intro_proc:
            if bg_proc: bg_proc.kill(); bg_proc = None
            
            if time.time() - last_bg_retry > 5:
                url, is_override = get_active_stream()
                if url:
                    if is_override and intro_duck_pending and intro_clip and os.path.exists(intro_clip):
                        cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", url, "-i", intro_clip, "-filter_complex", "[0:a]volume=0.3[v];[v][1:a]amix=inputs=2:duration=longest:dropout_transition=2", "-f", "s16le", "-ar", "22050", "-ac", "1", "-"]
                        bg_proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
                        intro_duck_pending = False
                    else:
                        bg_proc = spawn_audio_proc(url)
                last_bg_retry = time.time()
                
            if tech_diff_path and os.path.exists(tech_diff_path):
                if not tech_proc or tech_proc.poll() is not None:
                    tech_proc = subprocess.Popen(["ffmpeg", "-hide_banner", "-loglevel", "error", "-re", "-stream_loop", "-1", "-i", tech_diff_path, "-f", "s16le", "-ar", "22050", "-ac", "1", "-"], stdout=subprocess.PIPE)
                
                if tech_proc and tech_proc.poll() is None:
                    chunk = tech_proc.stdout.read(4096)
                
        if chunk:
            try: master_proc.stdin.write(chunk); master_proc.stdin.flush()
            except: break
        else:
            try:
                master_proc.stdin.write(bytes(4096))
                master_proc.stdin.flush()
                time.sleep(0.092)
            except: break

def stream_and_play_alert_wav(wav_path):
    try: subprocess.run(["aplay", "-D", LOCAL_HW_OUTPUT, wav_path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except: pass

def alert_playback_worker():
    while True:
        payload = ALERT_QUEUE.get()
        try:
            config = load_taendec_config()
            raw_header = payload.get("raw_header", "")
            
            if payload.get("type") != "WEB" and not is_in_alerting_area(raw_header): continue
            if is_duplicate(raw_header): continue
                
            pause_ms = max(0, min(int(config.get("audio_processing", {}).get("pre_alert_pause_ms", 1000)), 7000))
            raw_wav_path = payload.get("raw_wav_path", None)
            is_gwes = payload.get("is_gwes", False)
            
            if payload.get("type") == "WEB":
                evt, fips, dur, org = payload.get("eventCode", "ADR"), payload.get("fipsCodes", "027145"), payload.get("duration", "0030"), payload.get("originator", "EAS")
                sender = config.get("general", {}).get("sender_id", "TaENDEC ").ljust(8, " ")[:8]
                raw_header = f"ZCZC-{org}-{evt}-{fips}+{dur}-{get_utc_header_timestamp()}-{sender}-"
                add_text = urllib.parse.unquote_plus(payload.get("additionalText", "").strip())
                has_custom_audio, raw_wav_path, skip_trans = payload.get("hasAudio", False), payload.get("voice_wav_path", None), payload.get("skip_translation_in_tts", False)
                if config.get("rwt_rmt_scheduler", {}).get("disable_voice", False) and evt in ["RWT", "RMT"]: add_text, skip_trans, has_custom_audio, raw_wav_path = "", True, False, ""
            else:
                add_text, has_custom_audio, skip_trans = payload.get("additionalText", ""), bool(raw_wav_path), payload.get("skip_translation_in_tts", False)
                if config.get("general", {}).get("overwrite_sender_id", False):
                    sender = config.get("general", {}).get("sender_id", "TaENDEC ").ljust(8, " ")[:8]
                    parts = raw_header.strip("-").split("-")
                    if len(parts) >= 6:
                        parts[-1] = sender
                        raw_header = "-".join(parts) + "-"
                        
            set_endec_state("COMPILING & DISPATCHING", {"raw_header": raw_header})
            
            vis_trans = translate_same_to_speech(raw_header, is_visual=True)
            spk_trans = translate_same_to_speech(raw_header, is_visual=False)
            skip_tts = config.get("tts_settings", {}).get("disable_tts_global", False) or skip_trans
            if payload.get("type") == "IPAWS" and config.get("tts_settings", {}).get("disable_tts_ipaws", False): skip_tts = True
            
            # GWES Fallback Logic: If no audio and no text, strip all TTS so compiler skips to Headers/EOM
            if is_gwes and not has_custom_audio and not add_text.strip():
                tts_script = ""
            else:
                tts_script = add_text if (has_custom_audio or skip_tts) else (spk_trans + chr(10) + chr(10) + add_text if add_text else spk_trans)
                
            compiled_wav, file_name = compile_full_eas_audio(raw_header, recorded_wav_path=raw_wav_path, tts_text=tts_script)
            ALERT_HISTORY.append({"timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"), "header": raw_header, "mode": payload.get("type", "UNKNOWN"), "file": file_name})
            
            card_paths = generate_alert_card(translated_text=vis_trans, additional_text=add_text)
            if card_paths: launch_mpv_display(card_paths)
            
            threading.Thread(target=dispatch_http_endpoints, args=(raw_header, add_text, compiled_wav)).start()
            threading.Thread(target=dispatch_discord_webhook, args=(raw_header, add_text, compiled_wav)).start()
            threading.Thread(target=dispatch_gotify_notification, args=(raw_header, add_text)).start()
            
            global ICECAST_ALERT_FILE
            ICECAST_ALERT_FILE = compiled_wav
            
            time.sleep(pause_ms / 1000.0)
            if os.path.exists(compiled_wav):
                stream_and_play_alert_wav(compiled_wav)
                
            ICECAST_ALERT_FILE = None
            stop_mpv_display()
            notify_tv_alert_done(raw_header)
        except Exception as e: logger.error(f"Alert playback crashed: {e}")
        finally:
            set_endec_state("IDLE / MONITORING", None)
            ALERT_QUEUE.task_done()

def handle_incoming_eas_line(stream_name, line):
    line_clean = line.strip()
    if "ZCZC-" in line_clean and is_in_alerting_area(line_clean) and stream_name not in ACTIVE_RECORDINGS:
        set_endec_state("RECEIVING & RECORDING ALERT", {"source_stream": stream_name, "raw_header": line_clean})
        start_software_recording(stream_name, line_clean)
    elif "NNNN" in line_clean and stream_name in ACTIVE_RECORDINGS:
        finalize_and_enqueue_alert(stream_name)

def monitor_stream_worker(stream_name):
    last_url, p_proc, p_multi = "", None, None
    while MONITOR_FLAGS.get(stream_name, False):
        current_url = load_taendec_config().get("monitors", {}).get(stream_name, "")
        if not current_url:
            if p_proc: p_proc.terminate(); p_proc = None
            if p_multi: p_multi.terminate(); p_multi = None
            STREAM_STATUS[stream_name] = {"status": "DISABLED", "last_active": "N/A", "url": ""}
            time.sleep(5); continue
        if current_url != last_url or p_multi is None or p_multi.poll() is not None:
            last_url = current_url
            if p_proc: p_proc.terminate()
            if p_multi: p_multi.terminate()
            STREAM_STATUS[stream_name] = {"status": "CONNECTING", "last_active": "Never", "url": current_url}
            p_proc = subprocess.Popen(["ffmpeg", "-hide_banner", "-loglevel", "error", "-rw_timeout", "15000000", "-i", current_url, "-af", "aresample=resampler=soxr", "-c:a", "pcm_s16le", "-f", "s16le", "-ar", "22050", "-ac", "1", "-"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
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
        logger.warning(f"[MONITOR] Stream {stream_name} dropped. Reconnecting...")
        last_url = ""; time.sleep(3)

def dynamic_monitor_manager():
    while True:
        for name in load_taendec_config().get("monitors", {}):
            if name not in MONITOR_FLAGS:
                MONITOR_FLAGS[name] = True
                threading.Thread(target=monitor_stream_worker, args=(name,), daemon=True).start()
        time.sleep(5)

# --- IPAWS XML FETCH ENGINE ---
def find_all_ns(elem, tag_name): return [e for e in elem.iter() if e.tag.endswith(tag_name)]
def find_first_ns(elem, tag_name):
    for e in elem.iter():
        if e.tag.endswith(tag_name): return e
    return None

def parse_ipaws_start_time(iso_str):
    try: return datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
    except: return None

def parse_ipaws_duration(effective_str, expires_str):
    try:
        eff, exp = datetime.fromisoformat(effective_str.replace("Z", "+00:00")), datetime.fromisoformat(expires_str.replace("Z", "+00:00"))
        diff_min = int((exp - eff).total_seconds() / 60)
        if diff_min <= 0: return "0030"
        diff_min = math.ceil(diff_min / 15) * 15
        if diff_min > 99 * 60: return "9900"
        return f"{diff_min // 60:02d}{diff_min % 60:02d}"
    except: return "0030"

def fetch_feed_content(url, headers):
    if requests:
        try:
            resp = requests.get(url, headers=headers, timeout=10)
            if resp.status_code == 200: return resp.content
        except: pass
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=10) as resp: return resp.read()
    except: pass
    try:
        res = subprocess.run(["curl", "-s", "-L", "-A", headers['User-Agent'], url], capture_output=True, timeout=15)
        if res.returncode == 0 and res.stdout: return res.stdout
    except: pass
    raise Exception(f"All fetch methods failed for {url}")

def ipaws_monitor_worker():
    seen_ids = set()
    gwes_first_seen = {}
    req_headers = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0.0.0 Safari/537.36', 'Accept': 'application/xml, text/xml, */*'}
    
    while True:
        time.sleep(15)
        
        # Cleanup leaked GWES keys that fell off the feed before 2 mins
        now_ts = time.time()
        for k in list(gwes_first_seen.keys()):
            if now_ts - gwes_first_seen[k] > 3600: del gwes_first_seen[k]
            
        config = load_taendec_config()
        ipaws_cfg = config.get("ipaws", {})
        
        feeds = []
        if ipaws_cfg.get("gwes_enabled", False): feeds.append("https://alerts.globaleas.org/IPAWSOPEN_EAS_SERVICE/rest/feed")
        elif ipaws_cfg.get("endec_enabled", False): feeds.append("https://apps.fema.gov/IPAWSOPEN_EAS_SERVICE/rest/feed")
        if ipaws_cfg.get("wea_enabled", False): feeds.append("https://apps.fema.gov/IPAWSOPEN_EAS_SERVICE/rest/PublicWEA/recent/2012-08-21T11:40:43Z")
            
        for feed_url in feeds:
            try:
                is_gwes = "globaleas.org" in feed_url
                xml_data = fetch_feed_content(feed_url, req_headers)
                try: feed_root = ET.fromstring(xml_data)
                except Exception as xml_e: logger.error(f"[IPAWS] XML Parse Error for {feed_url}. Error: {xml_e}"); continue
                
                alerts_to_process = [feed_root] if feed_root.tag.endswith('}alert') else []
                alerts_to_process.extend(find_all_ns(feed_root, '}alert'))
                
                for entry in find_all_ns(feed_root, '}entry'):
                    link_tag = find_first_ns(entry, '}link')
                    if link_tag is None: continue
                    cap_url = link_tag.attrib.get('href')
                    if not cap_url or cap_url in seen_ids: continue
                    
                    if is_gwes:
                        if cap_url not in gwes_first_seen:
                            gwes_first_seen[cap_url] = time.time()
                            continue
                        if time.time() - gwes_first_seen[cap_url] < 120:
                            continue # Ignore for 2 minutes to allow audio to propagate
                        del gwes_first_seen[cap_url]
                        
                    seen_ids.add(cap_url)
                    try:
                        sub_xml = fetch_feed_content(cap_url, req_headers)
                        sub_root = ET.fromstring(sub_xml)
                        alerts_to_process.append(sub_root) if sub_root.tag.endswith('}alert') else alerts_to_process.extend(find_all_ns(sub_root, '}alert'))
                    except Exception as sub_e: logger.error(f"[IPAWS] Fetch error {cap_url}: {sub_e}")
                    
                for alert in alerts_to_process:
                    ident_tag = find_first_ns(alert, '}identifier')
                    alert_id = ident_tag.text if ident_tag is not None else None
                    if not alert_id or alert_id in seen_ids: continue
                    seen_ids.add(alert_id)
                    
                    infos = find_all_ns(alert, '}info')
                    if not infos: continue
                    
                    org_code, evt_code, fips_codes = "CIV", "ADR", set()
                    start_time_text, exp_text, desc_endec, inst_text, desc_wea, audio_url = None, None, "", "", "", ""
                    sent = find_first_ns(alert, '}sent')
                    sent_text = sent.text if sent is not None else None
                    
                    for info in infos:
                        lang_tag = find_first_ns(info, '}language')
                        if lang_tag is not None and lang_tag.text and not lang_tag.text.lower().startswith('en'):
                            continue
                            
                        for p in find_all_ns(info, '}parameter'):
                            vn = find_first_ns(p, '}valueName')
                            if vn is not None and vn.text:
                                if vn.text.strip() == "EAS-ORG":
                                    v = find_first_ns(p, '}value')
                                    if v is not None and v.text: org_code = v.text.strip()
                                elif vn.text.strip() == "CMAMlongtext":
                                    v = find_first_ns(p, '}value')
                                    if v is not None and v.text: desc_wea = v.text.strip()
                        for ec in find_all_ns(info, '}eventCode'):
                            vn = find_first_ns(ec, '}valueName')
                            if vn is not None and vn.text and vn.text.strip() == "SAME":
                                v = find_first_ns(ec, '}value')
                                if v is not None and v.text: evt_code = v.text.strip()
                        for gc in find_all_ns(info, '}geocode'):
                            vn = find_first_ns(gc, '}valueName')
                            if vn is not None and vn.text and vn.text.strip() == "SAME":
                                v = find_first_ns(gc, '}value')
                                if v is not None and v.text: fips_codes.update(v.text.split())
                        eff = find_first_ns(info, '}effective')
                        if eff is not None and eff.text: start_time_text = eff.text
                        exp = find_first_ns(info, '}expires')
                        if exp is not None and exp.text: exp_text = exp.text
                        desc_tag, inst_tag = find_first_ns(info, '}description'), find_first_ns(info, '}instruction')
                        if desc_tag is not None and desc_tag.text: desc_endec = desc_tag.text.strip()
                        if inst_tag is not None and inst_tag.text: inst_text = inst_tag.text.strip()
                        for r in find_all_ns(info, '}resource'):
                            mime = find_first_ns(r, '}mimeType')
                            if mime is not None and mime.text and 'audio' in mime.text.lower():
                                uri = find_first_ns(r, '}uri')
                                if uri is not None and uri.text: audio_url = uri.text

                    if not fips_codes: continue
                    final_start = start_time_text or sent_text
                    
                    sender_override = None
                    if is_gwes and desc_endec:
                        dasdec_pattern = r"(?:The .*?|An EAS Participant|Civil Authorities|.*?) has issued [aA]n? .*? for the following .*? Effective until .*?\. Message from (.*?)\."
                        match = re.search(dasdec_pattern, desc_endec, re.IGNORECASE | re.DOTALL)
                        if match:
                            sender_override = match.group(1).strip()
                            desc_endec = re.sub(dasdec_pattern, "", desc_endec, flags=re.IGNORECASE | re.DOTALL).strip()
                            
                    final_desc = desc_wea if desc_wea else f"{desc_endec} {inst_text}".strip()
                    dur_str = parse_ipaws_duration(final_start, exp_text) if final_start and exp_text else "0030"
                    start_override = parse_ipaws_start_time(final_start) if final_start else None
                    fips_str = "-".join(sorted([f.zfill(6)[-6:] for f in fips_codes if f.strip()]))
                    if not fips_str: continue
                    
                    sender_str = sender_override[:8].ljust(8, " ") if sender_override else "IPAWSCAP"
                    header = f"ZCZC-{org_code}-{evt_code}-{fips_str}+{dur_str}-{get_utc_header_timestamp()}-{sender_str}-"
                    dl_path = None
                    if audio_url:
                        try:
                            audio_bytes = fetch_feed_content(audio_url, req_headers)
                            dl_path = os.path.join(UPLOAD_DIR, f"ipaws_{int(time.time())}.mp3")
                            with open(dl_path, "wb") as af: af.write(audio_bytes)
                        except Exception as e: logger.error(f"[IPAWS] Failed to fetch attached audio: {e}")
                            
                    logger.info(f"Captured new CAP Alert: {header}")
                    ALERT_QUEUE.put({"type": "IPAWS", "is_gwes": is_gwes, "raw_header": header, "additionalText": final_desc, "raw_wav_path": dl_path, "alert_start_time": start_override})
            except Exception as e:
                logger.error(f"[IPAWS] Master Feed Connection Error for {feed_url}: {e}")

# --- NWS RSS FETCH ENGINE ---
def nws_rss_worker():
    seen_ids = set()
    req_headers = {'User-Agent': 'TaENDEC Master System (admin@taendec.local)', 'Accept': 'application/atom+xml, application/xml, text/xml'}
    
    while True:
        time.sleep(45)
        config = load_taendec_config()
        if not config.get("ipaws", {}).get("nws_rss_enabled", False): continue
        
        rss_zones_cfg = config.get("ipaws", {}).get("nws_rss_zones", "")
        all_targets = set([z.strip().upper() for z in rss_zones_cfg.split(",") if z.strip()])
        
        areas = [t for t in all_targets if len(t) == 2]
        zones = [t for t in all_targets if len(t) > 2]
        
        urls_to_poll = []
        if areas: urls_to_poll.append(f"https://api.weather.gov/alerts/active.atom?area={','.join(areas)}")
        if zones: urls_to_poll.append(f"https://api.weather.gov/alerts/active.atom?zone={','.join(zones)}")
        if not all_targets: urls_to_poll.append("https://api.weather.gov/alerts/active.atom")
        
        for feed_url in urls_to_poll:
            try:
                xml_data = fetch_feed_content(feed_url, req_headers)
                root = ET.fromstring(xml_data)
                
                for entry in find_all_ns(root, '}entry'):
                    id_tag = find_first_ns(entry, '}id')
                    alert_id = id_tag.text if id_tag is not None else None
                    if not alert_id or alert_id in seen_ids: continue
                    seen_ids.add(alert_id)
                    
                    evt_code = "ADR"
                    for ec in find_all_ns(entry, '}eventCode'):
                        vn = find_first_ns(ec, '}valueName')
                        if vn is not None and vn.text == 'SAME':
                            v = find_first_ns(ec, '}value')
                            if v is not None and v.text: evt_code = v.text
                            
                    if evt_code == "NWS": continue
                            
                    fips_codes, ugc_codes = set(), set()
                    for gc in find_all_ns(entry, '}geocode'):
                        vn = find_first_ns(gc, '}valueName')
                        if vn is not None and vn.text == 'SAME':
                            v = find_first_ns(gc, '}value')
                            if v is not None and v.text: 
                                for f in v.text.split(): fips_codes.add(f.zfill(6))
                        elif vn is not None and vn.text == 'UGC':
                            v = find_first_ns(gc, '}value')
                            if v is not None and v.text:
                                for f in v.text.split(): ugc_codes.add(f.upper())
                                
                    if not fips_codes: continue
                    
                    state_matched = any(len(t) == 2 and any(u.startswith(t) for u in ugc_codes) for t in all_targets)
                    if all_targets and not (ugc_codes.intersection(all_targets) or fips_codes.intersection(all_targets) or state_matched):
                        continue
                    
                    headline = ""
                    for p in find_all_ns(entry, '}parameter'):
                        vn = find_first_ns(p, '}valueName')
                        if vn is not None and vn.text == 'NWSheadline':
                            v = find_first_ns(p, '}value')
                            if v is not None and v.text: headline = v.text
                            
                    summary_tag = find_first_ns(entry, '}summary')
                    summary = summary_tag.text if summary_tag is not None else ""
                    
                    final_desc = f"{headline}... {chr(10)}{chr(10)}{summary}" if headline else summary
                    
                    sent_tag, expires_tag = find_first_ns(entry, '}sent'), find_first_ns(entry, '}expires')
                    sent_text = sent_tag.text if sent_tag is not None else None
                    expires_text = expires_tag.text if expires_tag is not None else None
                    
                    dur_str = parse_ipaws_duration(sent_text, expires_text) if sent_text and expires_text else "0030"
                    start_override = parse_ipaws_start_time(sent_text) if sent_text else None
                    fips_str = "-".join(sorted(list(fips_codes)))
                    
                    header = f"ZCZC-WXR-{evt_code}-{fips_str}+{dur_str}-{get_utc_header_timestamp()}-NWS     -"
                    
                    logger.info(f"Captured new NWS RSS Alert: {header}")
                    ALERT_QUEUE.put({"type": "NWS", "raw_header": header, "additionalText": final_desc, "raw_wav_path": None, "alert_start_time": start_override, "skip_translation_in_tts": True})
            except Exception as e:
                logger.error(f"[NWS RSS] Feed fetch error on {feed_url}: {e}")

# ---------------------------------------------------------
def schedule_worker():
    while True:
        now_ts = time.time()
        with STATE_LOCK:
            for i in range(len(SCHEDULED_ALERTS) - 1, -1, -1):
                if now_ts >= SCHEDULED_ALERTS[i]["time"]:
                    ALERT_QUEUE.put(SCHEDULED_ALERTS[i]["payload"]); SCHEDULED_ALERTS.pop(i)
        time.sleep(5)

def automated_test_worker():
    last_rwt_run, last_rmt_run = 0, 0
    while True:
        time.sleep(30)
        now = datetime.now()
        sched_cfg = load_taendec_config().get("rwt_rmt_scheduler", {})
        if now.weekday() == int(sched_cfg.get("rwt_exact_day", "-1")) and now.strftime("%H:%M") == sched_cfg.get("rwt_exact_time", "") and time.time() - last_rwt_run > 3600:
            last_rwt_run = time.time()
            ALERT_QUEUE.put({"type": "WEB", "originator": "EAS", "eventCode": sched_cfg.get("rwt_event_type", "RWT"), "duration": sched_cfg.get("rwt_duration", "0030"), "fipsCodes": sched_cfg.get("rwt_fips", "027145"), "additionalText": sched_cfg.get("rwt_text", ""), "voice_wav_path": sched_cfg.get("rwt_voice", ""), "skip_translation_in_tts": False, "hasAudio": bool(sched_cfg.get("rwt_voice", ""))})
        if ((now.day - 1) // 7 + 1) == int(sched_cfg.get("rmt_week", "-1")) and now.weekday() == int(sched_cfg.get("rmt_day", "-1")) and now.strftime("%H:%M") == sched_cfg.get("rmt_time", "") and time.time() - last_rmt_run > 3600:
            last_rmt_run = time.time()
            ALERT_QUEUE.put({"type": "WEB", "originator": "EAS", "eventCode": "RMT", "duration": sched_cfg.get("rmt_duration", "0030"), "fipsCodes": sched_cfg.get("rmt_fips", "027145"), "additionalText": sched_cfg.get("rmt_text", ""), "voice_wav_path": sched_cfg.get("rmt_voice", ""), "skip_translation_in_tts": False, "hasAudio": bool(sched_cfg.get("rmt_voice", ""))})

class APIHandler(BaseHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", self.headers.get("Origin", "*"))
        self.send_header("Access-Control-Allow-Credentials", "true")
        super().end_headers()
    def do_OPTIONS(self):
        self.send_response(200, "OK"); self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS"); self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization, Cookie, Voice-Name"); self.end_headers()
    def verify_auth(self):
        sec = load_taendec_config().get("security", {})
        if not sec.get("require_auth", False): return True
        
        cookie_header = self.headers.get("Cookie", "")
        if f"session_token={SESSION_TOKEN}" in cookie_header: return True
        
        auth_header = self.headers.get("Authorization")
        if auth_header and auth_header.startswith("Basic "):
            try:
                u, p = base64.b64decode(auth_header.split(" ")[1]).decode("utf-8").split(":", 1)
                if u == sec.get("username", "admin") and verify_password(p, sec.get("password", "")): return True
            except: pass
            
        self.send_auth_fail()
        return False
    def send_auth_fail(self):
        self.send_response(401); self.send_header("WWW-Authenticate", 'x-Basic realm="TaENDEC"'); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(json.dumps({"status": "Unauthorized"}).encode("utf-8"))
        return False
    def do_GET(self):
        if self.path.startswith("/archive/"):
            file_path = os.path.join(PERSISTENT_AUDIO_DIR, self.path.split("/")[-1])
            if os.path.exists(file_path):
                self.send_response(200); self.send_header("Content-Type", "audio/wav"); self.end_headers()
                with open(file_path, "rb") as f: self.wfile.write(f.read())
            else: self.send_error(404, "File Not Found")
            return
        if not self.verify_auth(): return
        if self.path in ("/", "/status", "/api/status"):
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
            with STATE_LOCK: self.wfile.write(json.dumps({"endec_state": ENDEC_STATE, "monitored_streams": STREAM_STATUS, "queue_depth": ALERT_QUEUE.qsize(), "scheduled_count": len(SCHEDULED_ALERTS)}, indent=2).encode("utf-8"))
        elif self.path == "/api/history":
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(json.dumps(ALERT_HISTORY).encode("utf-8"))
        elif self.path == "/api/config":
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(json.dumps(load_taendec_config()).encode("utf-8"))
        elif self.path == "/api/fips":
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(json.dumps(GLOBAL_FIPS_MAP).encode("utf-8"))
        elif self.path == "/api/voices":
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(json.dumps(detect_available_speechify_voices()).encode("utf-8"))
        else: self.send_response(404)

    def do_POST(self):
        if self.path == '/api/upload_cepstral':
            try:
                voice_name = self.headers.get('Voice-Name', 'unknown').strip().lower()
                if not voice_name: raise ValueError("No voice name provided")
                
                content_length = int(self.headers.get('Content-Length', 0))
                file_data = self.rfile.read(content_length)
                zip_path = f"/tmp/cepstral_{voice_name}.zip"
                
                with open(zip_path, "wb") as f: f.write(file_data)
                
                target_dir = f"/opt/swift/voices/{voice_name.capitalize()}"
                os.makedirs(target_dir, exist_ok=True)
                
                subprocess.run(["unzip", "-qo", zip_path, "-d", target_dir], check=True)
                
                if not os.path.exists(os.path.join(target_dir, "voice.idx")):
                    import shutil
                    subdirs = [os.path.join(target_dir, d) for d in os.listdir(target_dir) if os.path.isdir(os.path.join(target_dir, d))]
                    if len(subdirs) == 1 and os.path.exists(os.path.join(subdirs[0], "voice.idx")):
                        nested = subdirs[0]
                        for item in os.listdir(nested): shutil.move(os.path.join(nested, item), target_dir)
                        shutil.rmtree(nested)
                os.remove(zip_path)
                
                self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
                self.wfile.write(b'{"status": "ok"}')
            except Exception as e:
                self.send_error(500, str(e))
            return

        if self.path == '/api/stream_override':
            try:
                content_length = int(self.headers.get('Content-Length', 0))
                raw_body = self.rfile.read(content_length) if content_length > 0 else b'{}'
                payload = json.loads(raw_body)
                with STATE_LOCK:
                    STREAM_STATE["override_active"] = payload.get("active", False)
                    if STREAM_STATE["override_active"]:
                        STREAM_STATE["override_url"] = payload.get("url", "")
                        STREAM_STATE["intro_mode"] = payload.get("intro_mode", "before")
                        STREAM_STATE["intro_clip"] = payload.get("intro_clip", "")
                        STREAM_STATE["last_failure_time"] = None
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"status": "ok", "state": STREAM_STATE}).encode("utf-8"))
            except Exception as e:
                self.send_error(500, str(e))
            return
        try: payload = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))).decode("utf-8"))
        except: payload = {}
        
        if self.path == "/api/login":
            sec = load_taendec_config().get("security", {})
            if payload.get("username") == sec.get("username", "admin") and verify_password(payload.get("password"), sec.get("password", "")):
                self.send_response(200)
                self.send_header("Set-Cookie", f"session_token={SESSION_TOKEN}; HttpOnly; Path=/")
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"status": "OK"}).encode("utf-8"))
            else:
                self.send_error(401, "Unauthorized")
            return
            
        if not self.verify_auth(): return
        
        inbound_webhooks = load_taendec_config().get("outputs", {}).get("inbound_webhooks", [])
        if isinstance(inbound_webhooks, str):
            inbound_webhooks = [p.strip() for p in inbound_webhooks.split(",") if p.strip()]
            
        if self.path == "/api/config":
            try:
                with open(CONFIG_FILE, "w") as f: json.dump(payload, f, indent=2)
                self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(json.dumps({"status": "Configuration Saved Successfully"}).encode("utf-8"))
            except Exception as e: self.send_error(500, str(e))
        elif self.path == "/api/transmit" or self.path in inbound_webhooks:
            payload["type"] = "WEB"; ALERT_QUEUE.put(payload)
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(json.dumps({"status": "Alert Queued for Live Transmission"}).encode("utf-8"))
        elif self.path == "/api/schedule":
            payload["type"] = "WEB"
            with STATE_LOCK: SCHEDULED_ALERTS.append({"time": datetime.fromisoformat(payload.get("startTime", datetime.now().isoformat()).replace("Z", "+00:00")).timestamp(), "payload": payload})
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(json.dumps({"status": "Alert Scheduled Successfully"}).encode("utf-8"))
        elif self.path == "/api/upload":
            try:
                safe_name = "".join(c for c in payload.get("filename", "upload.bin") if c.isalnum() or c in "._- ")
                file_path = os.path.join(UPLOAD_DIR, safe_name)
                raw_data = payload.get("data", "")
                if "," in raw_data: raw_data = raw_data.split(",")[1]
                with open(file_path, "wb") as f: f.write(base64.b64decode(raw_data))
                self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(json.dumps({"status": "File Uploaded", "path": file_path}).encode("utf-8"))
            except Exception as e: self.send_error(500, f"Upload failed: {e}")
        else: self.send_error(404, "Endpoint Not Found")


def wea_logger_worker():
    import urllib.parse
    import json
    seen_ids = set()
    ns = {'cap': 'urn:oasis:names:tc:emergency:cap:1.2', 'ns1': 'http://gov.fema.ipaws.services/feed'}
    
    while True:
        time.sleep(60)
        try:
            config = load_taendec_config()
            wea_cfg = config.get("wea_logger", {})
            if not wea_cfg.get("enabled", False): continue
            
            discord_url = wea_cfg.get("discord_webhook", "")
            raw_role_id = str(wea_cfg.get("discord_role_id", "")).strip()
            clean_role_id = re.sub(r"[^0-9]", "", raw_role_id)
            gotify_cfg = config.get("outputs", {}).get("gotify", {})
            gotify_url = f"{gotify_cfg.get('url', '').rstrip('/')}/message?token={gotify_cfg.get('token', '')}" if gotify_cfg.get("enabled") and gotify_cfg.get("url") and gotify_cfg.get("token") else "" 
            geoapify_key = wea_cfg.get("geoapify_api_key", "")
            wea_url = "https://apps.fema.gov/IPAWSOPEN_EAS_SERVICE/rest/PublicWEA/recent/2012-08-21T11:40:43Z"
            
            headers = {'User-Agent': 'TaENDEC Master System (admin@taendec.local)', 'Accept': 'application/xml, text/xml'}
            resp = requests.get(wea_url, headers=headers, timeout=15)
            if resp.status_code != 200: continue
            
            root = ET.fromstring(resp.content)
            alerts = root.findall('.//cap:alert', ns)
            if not alerts and root.tag.endswith('alert'): alerts = [root]
            
            for alert in alerts:
                alert_id = alert.findtext('cap:identifier', namespaces=ns)
                if not alert_id or alert_id in seen_ids: continue
                seen_ids.add(alert_id)
                
                info = alert.find('cap:info', ns)
                if info is None: continue
                
                headline = info.findtext('cap:headline', default='WEA Alert', namespaces=ns)
                sent = alert.findtext('cap:sent', default='Unknown', namespaces=ns)
                expires = info.findtext('cap:expires', default='Unknown', namespaces=ns)
                sender = info.findtext('cap:senderName', namespaces=ns) or alert.findtext('cap:sender', default='Unknown', namespaces=ns)
                
                same_code = "UNKNOWN"
                for ec in info.findall('cap:eventCode', ns):
                    if ec.findtext('cap:valueName', namespaces=ns) == 'SAME':
                        same_code = ec.findtext('cap:value', namespaces=ns)
                        
                cmam_text, cmam_longtext, wea_handling = "N/A", "N/A", "N/A"
                for param in info.findall('cap:parameter', ns):
                    vname = param.findtext('cap:valueName', namespaces=ns)
                    val = param.findtext('cap:value', namespaces=ns)
                    if vname == 'CMAMtext': cmam_text = val
                    elif vname == 'CMAMlongtext': cmam_longtext = val
                    elif vname == 'WEAHandling': wea_handling = val
                
                map_url = ""
                area = info.find('cap:area', ns)
                if area is not None:
                    polygon_str = area.findtext('cap:polygon', default='', namespaces=ns)
                    if polygon_str and geoapify_key:
                        poly_points = []
                        for pair in polygon_str.strip().split():
                            if ',' in pair:
                                lat, lon = pair.split(',')
                                poly_points.append([float(lon), float(lat)])
                        if poly_points and poly_points[0] != poly_points[-1]:
                            poly_points.append(poly_points[0])
                        
                        if poly_points:
                            geojson_data = {'type': 'Feature', 'properties': {'fillcolor': '#ff0000', 'linecolor': '#ff0000', 'linewidth': 2, 'fillopacity': 0.4}, 'geometry': {'type': 'Polygon', 'coordinates': [poly_points]}}
                            safe_geojson = urllib.parse.quote(json.dumps(geojson_data))
                            map_url = f"https://maps.geoapify.com/v1/staticmap?style=dark-matter&width=600&height=400&geojson={safe_geojson}&apiKey={geoapify_key}&format=png"
                
                if discord_url:
                    embed = {
                        "title": f"{headline} ({same_code})",
                        "color": 16711680,
                        "fields": [
                            {"name": "WEA Handling", "value": wea_handling, "inline": True},
                            {"name": "Sender", "value": sender, "inline": True},
                            {"name": "Start Time", "value": sent, "inline": True},
                            {"name": "End Time", "value": expires, "inline": True},
                            {"name": "CMAMtext (90-char)", "value": cmam_text, "inline": False},
                            {"name": "CMAMlongtext (360-char)", "value": cmam_longtext, "inline": False}
                        ],
                        "footer": {"text": "TaENDEC WEA Logger"}
                    }
                    if map_url: embed["image"] = {"url": map_url}
                    requests.post(discord_url, json={"embeds": [embed]})
                
                if gotify_url:
                    requests.post(gotify_url, json={"title": wea_handling, "message": cmam_longtext, "priority": 8})
                    
                print(f"[WEA Logger] Processed and dispatched: {headline} ({same_code})")
        except Exception as e:
            print(f"[WEA Logger] Error: {e}")

def capcp_naad_worker():
    import socket
    import time
    import xml.etree.ElementTree as ET
    import base64
    import os
    import requests
    
    seen_ids = set()
    ns = {'cap': 'urn:oasis:names:tc:emergency:cap:1.2'}
    
    while True:
        try:
            config = load_taendec_config()
            capcp_cfg = config.get("capcp", {})
            if not capcp_cfg.get("enabled", False):
                time.sleep(60)
                continue
                
            pref_lang = capcp_cfg.get("lang", "en-CA")
            gotify_cfg = config.get("outputs", {}).get("gotify", {})
            gotify_url = f"{gotify_cfg.get('url', '').rstrip('/')}/message?token={gotify_cfg.get('token', '')}" if gotify_cfg.get("enabled") and gotify_cfg.get("url") and gotify_cfg.get("token") else ""
            
            host = "streaming1.naad-adna.pelmorex.com"
            port = 8080
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(90.0) 
            s.connect((host, port))
            print(f"[CAP-CP] Connected to NAAD TCP stream.")
            
            buffer = ""
            while True:
                chunk = s.recv(4096)
                if not chunk: break
                buffer += chunk.decode('utf-8', errors='ignore')
                
                while "<Heartbeat" in buffer and "</Heartbeat>" in buffer:
                    buffer = buffer[buffer.find("</Heartbeat>") + 12:]
                    
                while "<alert" in buffer and "</alert>" in buffer:
                    start_idx = buffer.find("<alert")
                    end_idx = buffer.find("</alert>") + 8
                    
                    if start_idx != -1 and start_idx < end_idx:
                        raw_xml = buffer[start_idx:end_idx]
                        buffer = buffer[end_idx:]
                        
                        try:
                            alert = ET.fromstring(raw_xml)
                            alert_id = alert.findtext('cap:identifier', namespaces=ns)
                            
                            if alert_id and alert_id not in seen_ids:
                                seen_ids.add(alert_id)
                                
                                target_info = None
                                for info in alert.findall('cap:info', ns):
                                    if info.findtext('cap:language', namespaces=ns) == pref_lang:
                                        target_info = info
                                        break
                                if target_info is None:
                                    target_info = alert.find('cap:info', ns)
                                    
                                if target_info is not None:
                                    literal_event = target_info.findtext('cap:event', default='CAP-CP Alert', namespaces=ns)
                                    headline = target_info.findtext('cap:headline', default='', namespaces=ns)
                                    desc = target_info.findtext('cap:description', default='', namespaces=ns)
                                    inst = target_info.findtext('cap:instruction', default='', namespaces=ns)
                                    
                                    audio_path = ""
                                    resource = target_info.find('cap:resource', ns)
                                    if resource is not None:
                                        deref = resource.findtext('cap:derefUri', namespaces=ns)
                                        if deref and "base64," in deref:
                                            try:
                                                b64_data = deref.split("base64,")[1]
                                                audio_path = f"/var/lib/eas_alerts/audio_archive/capcp_{alert_id.replace(':', '_')}.wav"
                                                os.makedirs(os.path.dirname(audio_path), exist_ok=True)
                                                with open(audio_path, "wb") as wf:
                                                    wf.write(base64.b64decode(b64_data))
                                            except Exception as e:
                                                print(f"[CAP-CP] Base64 Decode Error: {e}")
                                    
                                    # Use chr(10) to completely bypass escape sequence corruption
                                    nl = chr(10)
                                    msg_body = headline + nl + nl + desc + nl + inst
                                    if gotify_url:
                                        requests.post(gotify_url, json={"title": literal_event, "message": msg_body, "priority": 8})
                                    
                                    add_text = "EMERGENCY ALERT / ALERTE D'URGENCE" + nl + nl + headline + nl + nl + desc + nl + nl + inst
                                    internal_payload = {
                                        "originator": "CIV", 
                                        "eventCode": "CEM", 
                                        "duration": "0100", 
                                        "fipsCodes": "000000",
                                        "additionalText": add_text,
                                        "hasAudio": bool(audio_path),
                                        "voice_wav_path": audio_path,
                                        "skip_translation_in_tts": True,
                                        "is_capcp": True,
                                        "capcp_tone": capcp_cfg.get("tone", "pelmorex"),
                                        "capcp_prefix": capcp_cfg.get("prefix", ""),
                                        "capcp_suffix": capcp_cfg.get("suffix", "")
                                    }
                                    
                                    try:
                                        requests.post("http://127.0.0.1:8085/api/transmit", json=internal_payload)
                                        print(f"[CAP-CP] Local dispatch triggered for: {literal_event}")
                                    except Exception as e:
                                        print(f"[CAP-CP] Internal Dispatch Error: {e}")
                        except ET.ParseError:
                            print("[CAP-CP] Stream XML Parse Error.")
                    else:
                        buffer = ""
                        break
        except Exception as e:
            print(f"[CAP-CP] Stream disconnect: {e}. Retrying in 15s...")
            time.sleep(15)

if __name__ == "__main__":
    logger.info("Starting TaENDEC Master Daemon...")
    threading.Thread(target=session_rotation_worker, daemon=True).start()
    threading.Thread(target=alert_playback_worker, daemon=True).start()
    threading.Thread(target=gapless_icecast_worker, daemon=True).start()
    threading.Thread(target=wea_logger_worker, daemon=True).start()
    threading.Thread(target=capcp_naad_worker, daemon=True).start()

    threading.Thread(target=dynamic_monitor_manager, daemon=True).start()
    threading.Thread(target=schedule_worker, daemon=True).start()
    threading.Thread(target=automated_test_worker, daemon=True).start()
    threading.Thread(target=recording_timeout_worker, daemon=True).start()
    threading.Thread(target=ipaws_monitor_worker, daemon=True).start()
    threading.Thread(target=nws_rss_worker, daemon=True).start()
    launch_idle_screen()
    try:
        server = HTTPServer(("0.0.0.0", STATUS_SERVER_PORT), APIHandler)
        logger.info(f"Web UI and API listening on port {STATUS_SERVER_PORT}")
        server.serve_forever()
    except Exception as e: logger.error(f"Server crashed: {e}")
    except KeyboardInterrupt: pass
    finally:
        if MPV_PROCESS:
            try: MPV_PROCESS.terminate()
            except: pass
        logger.info("TaENDEC Daemon shutting down.")
