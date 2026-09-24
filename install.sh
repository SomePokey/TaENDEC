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

# Dynamically set user and application directory
APP_USER="$USER"
APP_DIR="/home/$APP_USER"

echo "Installing dependencies..."
sudo apt update
sudo apt install -y python3-requests python3-tzlocal ffmpeg espeak-ng alsa-utils multimon-ng mpv apache2

echo "Preparing target directories..."
sudo mkdir -p "$APP_DIR/logs"
sudo mkdir -p /var/www/html
sudo mkdir -p /var/lib/eas_alerts/audio_archive
sudo mkdir -p /var/lib/eas_alerts/uploads

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
    "timezone": "America/Chicago"
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
    "discord_avatar_url": ""
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

# --- 2. Generate Web UI ---
echo "Writing Web UI..."
cat << 'EOF' | sudo tee /var/www/html/index.html > /dev/null
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>TaENDEC Web Controller v6.3.2</title>
<style>
  body { background-color: #0d0d0d; color: #e0e0e0; font-family: monospace, monospace; padding: 20px; }
  .nav-tabs { border-bottom: 2px solid #333; margin-bottom: 20px; }
  .tab-btn { background: #1a1a1a; color: #ccc; border: 1px solid #333; padding: 8px 16px; cursor: pointer; font-family: inherit; }
  .tab-btn.active { background: #ff6600; color: #000; font-weight: bold; }
  .form-group { margin-bottom: 15px; }
  label { display: inline-block; width: 280px; vertical-align: top; }
  select, input[type="text"], input[type="password"], input[type="number"], input[type="time"], textarea { background: #1a1a1a; color: #fff; border: 1px solid #444; padding: 6px; font-family: inherit; }
  .btn-orange { background-color: #ff6600; color: #000; font-weight: bold; border: none; padding: 6px 14px; cursor: pointer; }
  .btn-orange:hover { background-color: #ff8533; }
  .btn-sm { padding: 4px 8px; font-size: 0.85em; }
  table { border-collapse: collapse; width: 100%; margin-top: 10px; }
  th, td { border: 1px solid #333; padding: 6px; text-align: left; }
  th { background: #1a1a1a; }
  .section-divider { border-top: 1px dashed #444; margin: 18px 0; }
  .hidden { display: none; }
  .settings-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
  .settings-panel { background: #151515; padding: 15px; border: 1px solid #333; }
  .settings-panel h4 { margin-top: 0; color: #ff6600; border-bottom: 1px solid #333; padding-bottom: 5px; }
  .settings-panel h5 { margin-top: 15px; margin-bottom: 5px; color: #ccc; border-bottom: 1px dashed #333; padding-bottom: 4px; }
  .upload-group { display: flex; gap: 10px; align-items: center; margin-top: 5px; }
</style>
</head>
<body>

<div id="loadingUI" style="text-align:center; margin-top: 100px; font-size: 1.2em;">
  Connecting to TaENDEC Backend...
</div>

<div id="loginModal" style="display:none; position:fixed; top:0; left:0; width:100%; height:100%; background:rgba(0,0,0,0.9); z-index:9999; align-items:center; justify-content:center;">
  <div style="background:#151515; padding:30px; border:1px solid #ff6600; width:300px;">
    <h3 style="color:#ff6600; margin-top:0;">TaENDEC Login</h3>
    <label>Username:</label><br>
    <input type="text" id="loginUser" style="margin-bottom:10px; width:95%;"><br>
    <label>Password:</label><br>
    <input type="password" id="loginPass" style="margin-bottom:20px; width:95%;" onkeydown="if(event.key === 'Enter') doLogin();"><br>
    <button class="btn-orange" style="width:100%;" onclick="doLogin()">Authenticate</button>
  </div>
</div>

<div id="mainUI" style="display:none;">
  <div class="nav-tabs">
    <button class="tab-btn active" onclick="switchTab('send')">Transmit Alert</button>
    <button class="tab-btn" onclick="switchTab('schedule')">Schedule Alert</button>
    <button class="tab-btn" onclick="switchTab('history'); fetchHistory();">Archive</button>
    <button class="tab-btn" onclick="switchTab('settings'); loadSettings();">System Settings</button>
    <button class="tab-btn" onclick="doLogout()" id="logoutBtn" style="display:none; float:right;">Logout</button>
  </div>

  <div id="tab-encoder">
    <form id="easForm" onsubmit="submitAlert(event)">
      <div class="form-group">
        <label>Select Originator:</label>
        <select id="originator">
          <option value="EAS">Emergency Alert System</option>
          <option value="CIV">Civil Authorities</option>
          <option value="WXR">National Weather Service</option>
        </select>
      </div>
      <div class="form-group">
        <label>Select EAS Event Type:</label>
        <select id="eventType">
          <option value="ADR">Administrative Message (ADR)</option><option value="AVA">Avalanche Watch (AVA)</option><option value="AVW">Avalanche Warning (AVW)</option><option value="BHW">Biological Hazard Warning (BHW)</option><option value="BLU">Blue Alert (BLU)</option><option value="BWW">Boil Water Warning (BWW)</option><option value="BZW">Blizzard Warning (BZW)</option><option value="CAE">Child Abduction Emergency (CAE)</option><option value="CDA">Civil Danger Watch (CDA)</option><option value="CDW">Civil Danger Warning (CDW)</option><option value="CEM">Civil Emergency Message (CEM)</option><option value="CFA">Coastal Flood Watch (CFA)</option><option value="CFW">Coastal Flood Warning (CFW)</option><option value="CHW">Chemical Hazard Warning (CHW)</option><option value="CWW">Contaminated Water Warning (CWW)</option><option value="DBA">Dam Watch (DBA)</option><option value="DBW">Dam Break Warning (DBW)</option><option value="DEW">Contagious Disease Warning (DEW)</option><option value="DMO">Demonstration Message (DMO)</option><option value="DSW">Dust Storm Warning (DSW)</option><option value="EAN">National Emergency Message (EAN)</option><option value="EAT">Emergency Action Termination (EAT)</option><option value="EQW">Earthquake Warning (EQW)</option><option value="EVA">Evacuation Watch (EVA)</option><option value="EVI">Notice of Immediate Evacuation (EVI)</option><option value="EWW">Extreme Wind Warning (EWW)</option><option value="FCW">Food Contamination Warning (FCW)</option><option value="FFA">Flash Flood Watch (FFA)</option><option value="FFS">Flash Flood Statement (FFS)</option><option value="FFW">Flash Flood Warning (FFW)</option><option value="FLA">Flood Watch (FLA)</option><option value="FLS">Flood Statement (FLS)</option><option value="FLW">Flood Warning (FLW)</option><option value="FRW">Fire Warning (FRW)</option><option value="FSW">Flash Freeze Warning (FSW)</option><option value="FZW">Freeze Warning (FZW)</option><option value="HLS">Hurricane Local Statement (HLS)</option><option value="HMW">Hazardous Materials Warning (HMW)</option><option value="HUA">Hurricane Watch (HUA)</option><option value="HUW">Hurricane Warning (HUW)</option><option value="HWA">High Wind Watch (HWA)</option><option value="HWW">High Wind Warning (HWW)</option><option value="IBW">Iceberg Warning (IBW)</option><option value="IFW">Industrial Fire Warning (IFW)</option><option value="LAE">Local Area Emergency (LAE)</option><option value="LEW">Law Enforcement Warning (LEW)</option><option value="LSW">Landslide Warning (LSW)</option><option value="MEP">Notice of a Missing/Endangered Person (MEP)</option><option value="NAT">National Audible Test (NAT)</option><option value="NIC">National Information Center (NIC)</option><option value="NMN">Network Notification Message (NMN)</option><option value="NPM">Nuclear Power Plant Test (NPM)</option><option value="NPT">National Test of the Emergency Alert System (NPT)</option><option value="NST">National Silent Test (NST)</option><option value="NUW">Nuclear Power Plant Warning (NUW)</option><option value="POS">Power Outage Statement (POS)</option><option value="RFW">Red Flag Warning (RFW)</option><option value="RHW">Radiological Hazard Warning (RHW)</option><option value="RMT">Required Monthly Test (RMT)</option><option value="RWT">Required Weekly Test (RWT)</option><option value="SCS">School Closure Statement (SCS)</option><option value="SMW">Special Marine Warning (SMW)</option><option value="SPS">Special Weather Statement (SPS)</option><option value="SPW">Shelter In Place Warning (SPW)</option><option value="SQW">Snow Squall Warning (SQW)</option><option value="SSA">Storm Surge Watch (SSA)</option><option value="SSW">Storm Surge Warning (SSW)</option><option value="SVA">Severe Thunderstorm Watch (SVA)</option><option value="SVR">Severe Thunderstorm Warning (SVR)</option><option value="SVS">Severe Weather Statement (SVS)</option><option value="TOA">Tornado Watch (TOA)</option><option value="TOE">911 Telephone Outage Emergency (TOE)</option><option value="TOR">Tornado Warning (TOR)</option><option value="TRA">Tropical Storm Watch (TRA)</option><option value="TRW">Tropical Storm Warning (TRW)</option><option value="TSA">Tsunami Watch (TSA)</option><option value="TSW">Tsunami Warning (TSW)</option><option value="VOW">Volcano Warning (VOW)</option><option value="WFA">Wildfire Watch (WFA)</option><option value="WFW">Wildfire Warning (WFW)</option><option value="WSA">Winter Storm Watch (WSA)</option><option value="WSW">Winter Storm Warning (WSW)</option>
        </select>
      </div>
      <div class="form-group">
        <label>Effective Duration:</label>
        Hr: <select id="durHr"><option value="00">00</option><option value="01">01</option><option value="02">02</option><option value="03">03</option><option value="04">04</option><option value="05">05</option><option value="06">06</option><option value="07">07</option><option value="08">08</option><option value="09">09</option><option value="10">10</option><option value="11">11</option><option value="12">12</option><option value="13">13</option><option value="14">14</option><option value="15">15</option><option value="16">16</option><option value="17">17</option><option value="18">18</option><option value="19">19</option><option value="20">20</option><option value="21">21</option><option value="22">22</option><option value="23">23</option><option value="24">24</option></select>
        Min: <select id="durMin"><option value="00">00</option><option value="15">15</option><option value="30" selected>30</option><option value="45">45</option></select>
      </div>
      <div class="form-group hidden" id="scheduleTimeGroup">
        <label>Select Start Date and Time:</label>
        <input type="datetime-local" id="startTime">
      </div>
      <div class="section-divider"></div>
      <div class="form-group">
        <label>FIPS Code Search:</label>
        <input type="text" list="fipsDataList" id="fipsSearch" placeholder="Type county name or code..." style="width: 250px;">
        <datalist id="fipsDataList"></datalist>
        <button type="button" class="btn-orange btn-sm" onclick="addSelectedFips()">Add FIPS</button>
      </div>
      <div class="form-group">
        <label>Selected FIPS Codes:</label>
        <input type="text" id="manualFips" placeholder="e.g. 027145-027053" style="width: 300px;">
      </div>
      <div class="section-divider"></div>
      <div class="form-group">
        <label>Custom Voice Audio (Optional):</label>
        <div class="upload-group" style="display:inline-flex; width: 400px; margin-top: 0;">
          <input type="text" id="voice_wav_path" placeholder="Overrides TTS if uploaded..." readonly style="flex-grow: 1;">
          <input type="file" id="voiceUploadFile" accept="audio/*" style="max-width: 150px;">
          <button type="button" class="btn-orange btn-sm" onclick="uploadFile('voiceUploadFile', 'voice_wav_path')">Upload</button>
        </div>
      </div>
      <div class="form-group">
        <label>Visual/TTS Text:</label>
        <textarea id="additionalText" rows="4" style="width: 400px;" placeholder="Supplemental message..."></textarea>
      </div>
      <div class="form-group">
        <label></label>
        <label style="width: auto;"><input type="checkbox" id="skip_translation"> Skip automatic header translation in TTS</label>
      </div>
      <button type="submit" id="submitBtn" class="btn-orange">Transmit Alert Live</button>
    </form>
  </div>

  <div id="tab-settings" class="hidden">
    <h3>TaENDEC Master Configuration</h3>
    <div class="settings-grid">
      <div class="settings-panel">
        <h4>Security & Authentication</h4>
        <label><input type="checkbox" id="cfg_auth_enable"> Require Web UI Login</label><br>
        <label>Admin Username:</label> <input type="text" id="cfg_auth_user"><br>
        <label>Admin Password:</label> <input type="password" id="cfg_auth_pass" placeholder="••••••••"><br>
        <small style="color:#888;">Default login is <b>admin</b> / <b>taendec</b> if left blank.</small>
      </div>

      <div class="settings-panel">
        <h4>General & Audio Settings</h4>
        <label>Sender ID:</label> <input type="text" id="cfg_sender_id" maxlength="8"><br>
        <label>System Timezone:</label> <input type="text" id="cfg_timezone" placeholder="America/Chicago"><br>
        <label>Pre-Alert Pause (ms):</label> <input type="number" id="cfg_pause" min="0" max="7000"><br>
      </div>

      <div class="settings-panel">
        <h4>Geographic Filtering</h4>
        <label><input type="checkbox" id="cfg_enforce_fips"> Enforce Strict Filtering</label><br>
        <label>Allowed States (Prefixes):</label> <input type="text" id="cfg_allowed_states" placeholder="27, 91"><br>
        <label>Allowed FIPS Codes:</label> <input type="text" id="cfg_allowed_fips" style="width: 100%;"><br>
      </div>

      <div class="settings-panel">
        <h4>Monitored Stream Sources</h4>
        <table style="margin-bottom: 10px;">
          <thead><tr><th style="width: 30%;">Name</th><th style="width: 55%;">Stream URL</th><th style="width: 15%;">Action</th></tr></thead>
          <tbody id="monitorsTbody"></tbody>
        </table>
        <button type="button" class="btn-orange btn-sm" onclick="addMonitorRow()">+ Add Monitor</button>
      </div>

      <div class="settings-panel" style="grid-column: span 2;">
        <h4>Outputs & Webhook Automations</h4>
        <div style="display:flex; gap:30px;">
            <div style="flex:1;">
                <h5>Local Network API (TV Station)</h5>
                <label><input type="checkbox" id="cfg_enable_http"> Enable HTTP POST Notifications</label><br>
                <label>Station API IP/Host:</label> <input type="text" id="cfg_tv_ip" placeholder="192.168.12.199" style="width: 90%;"><br>
                <label>Multicast Target Address:</label> <input type="text" id="cfg_tv_multicast" placeholder="224.0.0.1:36332" style="width: 90%;"><br>
            </div>
            <div style="flex:1;">
                <h5>Discord Integration</h5>
                <label><input type="checkbox" id="cfg_enable_discord"> Dispatch Alerts to Discord</label><br>
                <label>Webhook URL(s) (comma-separated):</label> <input type="text" id="cfg_discord_urls" placeholder="https://..., https://..." style="width: 90%;"><br>
                <label>Bot Username Override:</label> <input type="text" id="cfg_discord_username" placeholder="TaENDEC System" style="width: 90%;"><br>
                <label>Bot Avatar URL (Optional):</label> <input type="text" id="cfg_discord_avatar" placeholder="https://..." style="width: 90%;"><br>
            </div>
        </div>
      </div>

      <div class="settings-panel" style="grid-column: span 2;">
        <h4>EAS Details Channel</h4>
        <label>Display Mode:</label>
        <select id="cfg_details_mode">
          <option value="off">Off (Audio Only / No Graphics)</option>
          <option value="static_screen">Static Text Screen</option>
          <option value="media_stream">Direct Video/Audio File</option>
          <option value="youtube">YouTube Stream</option>
        </select><br><br>
        <label>Fallback Text (use ${newpage} for breaks):</label><br>
        <textarea id="cfg_fallback_text" rows="3" style="width: 100%;"></textarea><br><br>
        <label>Media URL / Upload Video File:</label><br>
        <div class="upload-group">
          <input type="text" id="cfg_media_url" placeholder="http://... or local /var/lib/... path" style="width: 60%;">
          <input type="file" id="mediaUploadFile" accept="video/*,audio/*">
          <button type="button" class="btn-orange btn-sm" onclick="uploadFile('mediaUploadFile', 'cfg_media_url')">Upload</button>
        </div>
      </div>

      <div class="settings-panel" style="grid-column: span 2;">
        <h4>Alert Prefix & Suffix Audio Voiceovers</h4>
        
        <label>CIVIL EMERGENCY Prefix:</label>
        <div class="upload-group"><input type="text" id="cfg_prefix_civil" style="width: 60%;"><input type="file" id="up_prefix_civil" accept="audio/*"><button type="button" class="btn-orange btn-sm" onclick="uploadFile('up_prefix_civil', 'cfg_prefix_civil')">Upload</button></div>
        <label>CIVIL EMERGENCY Suffix:</label>
        <div class="upload-group"><input type="text" id="cfg_suffix_civil" style="width: 60%;"><input type="file" id="up_suffix_civil" accept="audio/*"><button type="button" class="btn-orange btn-sm" onclick="uploadFile('up_suffix_civil', 'cfg_suffix_civil')">Upload</button></div>
        <hr style="border: 0; border-bottom: 1px dashed #333; margin: 10px 0;">

        <label>WEATHER WARNING Prefix:</label>
        <div class="upload-group"><input type="text" id="cfg_prefix_wx" style="width: 60%;"><input type="file" id="up_prefix_wx" accept="audio/*"><button type="button" class="btn-orange btn-sm" onclick="uploadFile('up_prefix_wx', 'cfg_prefix_wx')">Upload</button></div>
        <label>WEATHER WARNING Suffix:</label>
        <div class="upload-group"><input type="text" id="cfg_suffix_wx" style="width: 60%;"><input type="file" id="up_suffix_wx" accept="audio/*"><button type="button" class="btn-orange btn-sm" onclick="uploadFile('up_suffix_wx', 'cfg_suffix_wx')">Upload</button></div>
        <hr style="border: 0; border-bottom: 1px dashed #333; margin: 10px 0;">

        <label>WATCH Prefix:</label>
        <div class="upload-group"><input type="text" id="cfg_prefix_watch" style="width: 60%;"><input type="file" id="up_prefix_watch" accept="audio/*"><button type="button" class="btn-orange btn-sm" onclick="uploadFile('up_prefix_watch', 'cfg_prefix_watch')">Upload</button></div>
        <label>WATCH Suffix:</label>
        <div class="upload-group"><input type="text" id="cfg_suffix_watch" style="width: 60%;"><input type="file" id="up_suffix_watch" accept="audio/*"><button type="button" class="btn-orange btn-sm" onclick="uploadFile('up_suffix_watch', 'cfg_suffix_watch')">Upload</button></div>
        <hr style="border: 0; border-bottom: 1px dashed #333; margin: 10px 0;">

        <label>ADVISORY / STATEMENT Prefix:</label>
        <div class="upload-group"><input type="text" id="cfg_prefix_adv" style="width: 60%;"><input type="file" id="up_prefix_adv" accept="audio/*"><button type="button" class="btn-orange btn-sm" onclick="uploadFile('up_prefix_adv', 'cfg_prefix_adv')">Upload</button></div>
        <label>ADVISORY / STATEMENT Suffix:</label>
        <div class="upload-group"><input type="text" id="cfg_suffix_adv" style="width: 60%;"><input type="file" id="up_suffix_adv" accept="audio/*"><button type="button" class="btn-orange btn-sm" onclick="uploadFile('up_suffix_adv', 'cfg_suffix_adv')">Upload</button></div>
        <hr style="border: 0; border-bottom: 1px dashed #333; margin: 10px 0;">

        <label>TEST Prefix:</label>
        <div class="upload-group"><input type="text" id="cfg_prefix_test" style="width: 60%;"><input type="file" id="up_prefix_test" accept="audio/*"><button type="button" class="btn-orange btn-sm" onclick="uploadFile('up_prefix_test', 'cfg_prefix_test')">Upload</button></div>
        <label>TEST Suffix:</label>
        <div class="upload-group"><input type="text" id="cfg_suffix_test" style="width: 60%;"><input type="file" id="up_suffix_test" accept="audio/*"><button type="button" class="btn-orange btn-sm" onclick="uploadFile('up_suffix_test', 'cfg_suffix_test')">Upload</button></div>
        <hr style="border: 0; border-bottom: 1px dashed #333; margin: 10px 0;">

        <label>ALL ALERTS (Fallback) Prefix:</label>
        <div class="upload-group"><input type="text" id="cfg_prefix_all" style="width: 60%;"><input type="file" id="up_prefix_all" accept="audio/*"><button type="button" class="btn-orange btn-sm" onclick="uploadFile('up_prefix_all', 'cfg_prefix_all')">Upload</button></div>
        <label>ALL ALERTS (Fallback) Suffix:</label>
        <div class="upload-group"><input type="text" id="cfg_suffix_all" style="width: 60%;"><input type="file" id="up_suffix_all" accept="audio/*"><button type="button" class="btn-orange btn-sm" onclick="uploadFile('up_suffix_all', 'cfg_suffix_all')">Upload</button></div>
      </div>

      <div class="settings-panel" style="grid-column: span 2;">
        <h4>RWT / RMT Automated Scheduler</h4>
        
        <h5>RWT Settings</h5>
        <label>FIPS Codes:</label> <input type="text" id="cfg_rwt_fips" placeholder="027145-027053"><br>
        <label>Day of Week:</label> <select id="cfg_rwt_exact_day"><option value="0">Mon</option><option value="1">Tue</option><option value="2">Wed</option><option value="3">Thu</option><option value="4">Fri</option><option value="5">Sat</option><option value="6">Sun</option></select><br>
        <label>Time of Day:</label> <input type="time" id="cfg_rwt_exact_time"><br>
        <label>Additional Text:</label><br><textarea id="cfg_rwt_text" rows="2" style="width: 100%;"></textarea><br>
        <label>Voice Clip Override:</label><div class="upload-group"><input type="text" id="cfg_rwt_voice" style="width: 60%;"><input type="file" id="rwtVoiceFile" accept="audio/*"><button type="button" class="btn-orange btn-sm" onclick="uploadFile('rwtVoiceFile', 'cfg_rwt_voice')">Upload</button></div>
        
        <h5>RMT Settings</h5>
        <label>FIPS Codes:</label> <input type="text" id="cfg_rmt_fips" placeholder="027145-027053"><br>
        <label>Week of the Month:</label> <select id="cfg_rmt_week"><option value="1">First</option><option value="2">Second</option><option value="3">Third</option><option value="4">Fourth</option></select><br>
        <label>Day of the Week:</label> <select id="cfg_rmt_day"><option value="0">Mon</option><option value="1">Tue</option><option value="2">Wed</option><option value="3">Thu</option><option value="4">Fri</option><option value="5">Sat</option><option value="6">Sun</option></select><br>
        <label>Time of Day:</label> <input type="time" id="cfg_rmt_time"><br>
        <label>Additional Text:</label><br><textarea id="cfg_rmt_text" rows="2" style="width: 100%;"></textarea><br>
        <label>Voice Clip Override:</label><div class="upload-group"><input type="text" id="cfg_rmt_voice" style="width: 60%;"><input type="file" id="rmtVoiceFile" accept="audio/*"><button type="button" class="btn-orange btn-sm" onclick="uploadFile('rmtVoiceFile', 'cfg_rmt_voice')">Upload</button></div><br>
        
        <label><input type="checkbox" id="cfg_rwt_disable_voice"> Disable TTS completely for all automated tests</label>
      </div>
    </div><br>
    <button class="btn-orange" onclick="saveSettings()">Save Configuration</button>
  </div>

  <div id="tab-history" class="hidden">
    <h3>Archive</h3>
    <table><thead><tr><th>Timestamp</th><th>Header String</th><th>Mode</th><th>Playback</th></tr></thead><tbody id="historyTableBody"></tbody></table>
  </div>
</div>

<script>
  const API_PORT = "8085";
  let currentMode = "send";
  let currentConfig = {};
  let fipsDatabase = {};

  async function apiFetch(url, options = {}) {
    options.headers = options.headers || {};
    if (options.method === "POST" && !options.headers["Content-Type"]) {
        options.headers["Content-Type"] = "application/json";
    }
    const auth = localStorage.getItem("taendec_auth");
    if (auth) { options.headers["Authorization"] = "Basic " + auth; }
    
    try {
        const res = await fetch(url, options);
        if (res.status === 401) {
            document.getElementById("loginModal").style.display = "flex";
            throw new Error("401");
        }
        if (!res.ok) throw new Error("API Error " + res.status);
        return res;
    } catch (err) {
        throw err;
    }
  }

  function doLogin() {
    const u = document.getElementById("loginUser").value;
    const p = document.getElementById("loginPass").value;
    localStorage.setItem("taendec_auth", btoa(u + ":" + p));
    document.getElementById("loginModal").style.display = "none";
    location.reload();
  }

  function doLogout() {
    localStorage.removeItem("taendec_auth");
    location.reload();
  }

  window.onload = async () => {
    try {
      const res = await apiFetch(`http://${window.location.hostname}:${API_PORT}/api/fips`);
      
      document.getElementById("loadingUI").style.display = "none";
      document.getElementById("mainUI").style.display = "block";
      
      if (localStorage.getItem("taendec_auth")) {
          document.getElementById("logoutBtn").style.display = "inline-block";
      }

      fipsDatabase = await res.json();
      const datalist = document.getElementById("fipsDataList");
      for (const [code, name] of Object.entries(fipsDatabase)) {
        const opt = document.createElement("option");
        opt.value = `0${code}`; opt.text = `${name} (${code})`;
        datalist.appendChild(opt);
      }
    } catch (e) {
      document.getElementById("loadingUI").style.display = "none";
      if (e.message !== "401") {
          document.body.innerHTML = `
            <div style="text-align:center; margin-top: 100px; color: #ff3333;">
              <h2>Backend Connection Failed</h2>
              <p>The Web UI could not communicate with the TaENDEC daemon on port ${API_PORT}.</p>
              <p>Check the service status via SSH: <code>sudo systemctl status taendec</code></p>
              <p style="color:#888;">Error details: ${e.message}</p>
            </div>
          `;
      }
    }
  };

  function addSelectedFips() {
    const searchBox = document.getElementById("fipsSearch");
    const targetBox = document.getElementById("manualFips");
    let val = searchBox.value.split(" ")[0].trim();
    if (val.length === 6) {
      let current = targetBox.value.trim();
      targetBox.value = current ? `${current}-${val}` : val;
      searchBox.value = "";
    }
  }

  function switchTab(tab) {
    document.getElementById("tab-encoder").classList.toggle("hidden", tab !== "send" && tab !== "schedule");
    document.getElementById("tab-history").classList.toggle("hidden", tab !== "history");
    document.getElementById("tab-settings").classList.toggle("hidden", tab !== "settings");
    document.getElementById("scheduleTimeGroup").classList.toggle("hidden", tab !== "schedule");
    currentMode = tab;
    if (tab === "send") document.getElementById("submitBtn").innerText = "Transmit Alert Live";
    if (tab === "schedule") document.getElementById("submitBtn").innerText = "Schedule Alert";
    document.querySelectorAll(".tab-btn").forEach(btn => btn.classList.remove("active"));
    if (event && event.target) event.target.classList.add("active");
  }

  async function uploadFile(inputId, targetInputId) {
    const fileInput = document.getElementById(inputId);
    if (fileInput.files.length === 0) return alert("Select a file first.");
    const file = fileInput.files[0];
    const reader = new FileReader();
    reader.onload = async function() {
      const payload = { filename: file.name, data: reader.result };
      try {
        const res = await apiFetch(`http://${window.location.hostname}:${API_PORT}/api/upload`, { method: "POST", body: JSON.stringify(payload) });
        const data = await res.json();
        document.getElementById(targetInputId).value = data.path;
        alert(data.status + ": " + data.path);
      } catch (e) { alert("Upload failed or Unauthorized."); }
    };
    reader.readAsDataURL(file);
  }

  function addMonitorRow(name = "", url = "") {
    const tbody = document.getElementById("monitorsTbody");
    const tr = document.createElement("tr");
    tr.innerHTML = `<td><input type="text" class="mon-name" value="${name}" placeholder="e.g. NWS_MPX" style="width: 90%;"></td><td><input type="text" class="mon-url" value="${url}" placeholder="http://... or ALSA" style="width: 95%;"></td><td><button type="button" class="btn-orange btn-sm" onclick="this.closest('tr').remove()">Remove</button></td>`;
    tbody.appendChild(tr);
  }

  async function loadSettings() {
    try {
      const res = await apiFetch(`http://${window.location.hostname}:${API_PORT}/api/config`);
      currentConfig = await res.json();

      const sec = currentConfig.security || {};
      document.getElementById("cfg_auth_enable").checked = sec.require_auth ?? false;
      document.getElementById("cfg_auth_user").value = sec.username || "admin";
      document.getElementById("cfg_auth_pass").value = sec.password || "";

      document.getElementById("cfg_sender_id").value = currentConfig.general?.sender_id || "TaENDEC ";
      document.getElementById("cfg_timezone").value = currentConfig.general?.timezone || "America/Chicago";
      document.getElementById("cfg_pause").value = currentConfig.audio_processing?.pre_alert_pause_ms || 1000;

      const filters = currentConfig.filters || {};
      document.getElementById("cfg_enforce_fips").checked = filters.enforce_fips_filtering || false;
      document.getElementById("cfg_allowed_states").value = (filters.allowed_state_prefixes || ["27", "91"]).join(", ");
      document.getElementById("cfg_allowed_fips").value = (filters.allowed_fips_codes || []).join(", ");

      const monitors = currentConfig.monitors || {};
      document.getElementById("monitorsTbody").innerHTML = "";
      for (const [name, url] of Object.entries(monitors)) addMonitorRow(name, url);

      const outputs = currentConfig.outputs || {};
      document.getElementById("cfg_enable_http").checked = outputs.enable_http_post ?? true;
      document.getElementById("cfg_tv_ip").value = outputs.tv_station_ip || "192.168.12.199";
      document.getElementById("cfg_tv_multicast").value = outputs.tv_multicast_address || outputs.multicast_address || "224.0.0.1:36332";
      
      document.getElementById("cfg_enable_discord").checked = outputs.enable_discord_webhook ?? false;
      document.getElementById("cfg_discord_urls").value = (outputs.discord_webhook_urls || []).join(", ");
      document.getElementById("cfg_discord_username").value = outputs.discord_username || "TaENDEC System";
      document.getElementById("cfg_discord_avatar").value = outputs.discord_avatar_url || "";

      document.getElementById("cfg_details_mode").value = currentConfig.details_channel?.mode || "static_screen";
      document.getElementById("cfg_media_url").value = currentConfig.details_channel?.media_url || "";
      document.getElementById("cfg_fallback_text").value = currentConfig.details_channel?.fallback_text || "Emergency Alert System Details Channel";

      document.getElementById("cfg_prefix_civil").value = currentConfig.audio_processing?.prefixes?.CIVIL_EMERGENCY || "";
      document.getElementById("cfg_suffix_civil").value = currentConfig.audio_processing?.suffixes?.CIVIL_EMERGENCY || "";
      document.getElementById("cfg_prefix_wx").value = currentConfig.audio_processing?.prefixes?.WEATHER_WARNING || "";
      document.getElementById("cfg_suffix_wx").value = currentConfig.audio_processing?.suffixes?.WEATHER_WARNING || "";
      document.getElementById("cfg_prefix_watch").value = currentConfig.audio_processing?.prefixes?.WATCH || "";
      document.getElementById("cfg_suffix_watch").value = currentConfig.audio_processing?.suffixes?.WATCH || "";
      document.getElementById("cfg_prefix_adv").value = currentConfig.audio_processing?.prefixes?.ADVISORY || "";
      document.getElementById("cfg_suffix_adv").value = currentConfig.audio_processing?.suffixes?.ADVISORY || "";
      document.getElementById("cfg_prefix_test").value = currentConfig.audio_processing?.prefixes?.TEST || "";
      document.getElementById("cfg_suffix_test").value = currentConfig.audio_processing?.suffixes?.TEST || "";
      document.getElementById("cfg_prefix_all").value = currentConfig.audio_processing?.prefixes?.ALL_ALERTS || "";
      document.getElementById("cfg_suffix_all").value = currentConfig.audio_processing?.suffixes?.ALL_ALERTS || "";

      const sched = currentConfig.rwt_rmt_scheduler || {};
      document.getElementById("cfg_rwt_fips").value = sched.rwt_fips || "027145";
      document.getElementById("cfg_rmt_fips").value = sched.rmt_fips || "027145";
      document.getElementById("cfg_rwt_exact_day").value = sched.rwt_exact_day ?? 2;
      document.getElementById("cfg_rwt_exact_time").value = sched.rwt_exact_time || "11:15";
      document.getElementById("cfg_rwt_text").value = sched.rwt_text || "";
      document.getElementById("cfg_rwt_voice").value = sched.rwt_voice || "";
      document.getElementById("cfg_rmt_week").value = sched.rmt_week || 1;
      document.getElementById("cfg_rmt_day").value = sched.rmt_day ?? 2;
      document.getElementById("cfg_rmt_time").value = sched.rmt_time || "11:15";
      document.getElementById("cfg_rmt_text").value = sched.rmt_text || "";
      document.getElementById("cfg_rmt_voice").value = sched.rmt_voice || "";
      document.getElementById("cfg_rwt_disable_voice").checked = sched.disable_voice || false;

    } catch (err) {}
  }

  async function saveSettings() {
    currentConfig.security = {
        require_auth: document.getElementById("cfg_auth_enable").checked,
        username: document.getElementById("cfg_auth_user").value || "admin",
        password: document.getElementById("cfg_auth_pass").value || "taendec"
    };

    currentConfig.general = { sender_id: document.getElementById("cfg_sender_id").value.padEnd(8, " ").substring(0, 8), timezone: document.getElementById("cfg_timezone").value };
    
    currentConfig.audio_processing = currentConfig.audio_processing || {};
    currentConfig.audio_processing.pre_alert_pause_ms = parseInt(document.getElementById("cfg_pause").value) || 0;
    currentConfig.audio_processing.prefixes = {
        CIVIL_EMERGENCY: document.getElementById("cfg_prefix_civil").value,
        WEATHER_WARNING: document.getElementById("cfg_prefix_wx").value,
        WATCH: document.getElementById("cfg_prefix_watch").value,
        ADVISORY: document.getElementById("cfg_prefix_adv").value,
        TEST: document.getElementById("cfg_prefix_test").value,
        ALL_ALERTS: document.getElementById("cfg_prefix_all").value
    };
    currentConfig.audio_processing.suffixes = {
        CIVIL_EMERGENCY: document.getElementById("cfg_suffix_civil").value,
        WEATHER_WARNING: document.getElementById("cfg_suffix_wx").value,
        WATCH: document.getElementById("cfg_suffix_watch").value,
        ADVISORY: document.getElementById("cfg_suffix_adv").value,
        TEST: document.getElementById("cfg_suffix_test").value,
        ALL_ALERTS: document.getElementById("cfg_suffix_all").value
    };

    currentConfig.filters = currentConfig.filters || {};
    currentConfig.filters.enforce_fips_filtering = document.getElementById("cfg_enforce_fips").checked;
    currentConfig.filters.allowed_state_prefixes = document.getElementById("cfg_allowed_states").value.split(",").map(x => x.trim()).filter(Boolean);
    currentConfig.filters.allowed_fips_codes = document.getElementById("cfg_allowed_fips").value.split(/[\s,;-]+/).map(x => x.trim()).filter(Boolean);

    currentConfig.monitors = {};
    document.querySelectorAll("#monitorsTbody tr").forEach(tr => {
      const name = tr.querySelector(".mon-name").value.trim();
      const url = tr.querySelector(".mon-url").value.trim();
      if (name && url) currentConfig.monitors[name] = url;
    });

    currentConfig.outputs = currentConfig.outputs || {};
    currentConfig.outputs.enable_http_post = document.getElementById("cfg_enable_http").checked;
    currentConfig.outputs.tv_station_ip = document.getElementById("cfg_tv_ip").value.trim();
    currentConfig.outputs.tv_multicast_address = document.getElementById("cfg_tv_multicast").value.trim();
    
    currentConfig.outputs.enable_discord_webhook = document.getElementById("cfg_enable_discord").checked;
    currentConfig.outputs.discord_webhook_urls = document.getElementById("cfg_discord_urls").value.split(",").map(x => x.trim()).filter(Boolean);
    currentConfig.outputs.discord_username = document.getElementById("cfg_discord_username").value.trim();
    currentConfig.outputs.discord_avatar_url = document.getElementById("cfg_discord_avatar").value.trim();

    currentConfig.details_channel = currentConfig.details_channel || {};
    currentConfig.details_channel.mode = document.getElementById("cfg_details_mode").value;
    currentConfig.details_channel.media_url = document.getElementById("cfg_media_url").value;
    currentConfig.details_channel.fallback_text = document.getElementById("cfg_fallback_text").value;

    currentConfig.rwt_rmt_scheduler = {
      rwt_fips: document.getElementById("cfg_rwt_fips").value, 
      rmt_fips: document.getElementById("cfg_rmt_fips").value, 
      rwt_exact_day: parseInt(document.getElementById("cfg_rwt_exact_day").value), 
      rwt_exact_time: document.getElementById("cfg_rwt_exact_time").value, 
      rwt_text: document.getElementById("cfg_rwt_text").value, 
      rwt_voice: document.getElementById("cfg_rwt_voice").value, 
      rmt_week: parseInt(document.getElementById("cfg_rmt_week").value), 
      rmt_day: parseInt(document.getElementById("cfg_rmt_day").value), 
      rmt_time: document.getElementById("cfg_rmt_time").value, 
      rmt_text: document.getElementById("cfg_rmt_text").value, 
      rmt_voice: document.getElementById("cfg_rmt_voice").value, 
      disable_voice: document.getElementById("cfg_rwt_disable_voice").checked
    };

    try {
      const res = await apiFetch(`http://${window.location.hostname}:${API_PORT}/api/config`, { method: "POST", body: JSON.stringify(currentConfig) });
      alert((await res.json()).status);
    } catch (err) { alert("Failed to save settings or Unauthorized."); }
  }

  async function submitAlert(e) {
    e.preventDefault();
    const fipsInput = document.getElementById("manualFips").value;
    if (!fipsInput.trim()) return alert("Must specify at least one location.");
    const endpoint = currentMode === "send" ? "/api/transmit" : "/api/schedule";
    const payload = {
      originator: document.getElementById("originator").value, eventCode: document.getElementById("eventType").value, duration: document.getElementById("durHr").value + document.getElementById("durMin").value, fipsCodes: fipsInput, additionalText: document.getElementById("additionalText").value, voiceEngine: "espeak", hasAudio: !!document.getElementById("voice_wav_path").value, voice_wav_path: document.getElementById("voice_wav_path").value, skip_translation_in_tts: document.getElementById("skip_translation").checked, startTime: document.getElementById("startTime").value || new Date().toISOString()
    };
    try {
      const res = await apiFetch(`http://${window.location.hostname}:${API_PORT}${endpoint}`, { method: "POST", body: JSON.stringify(payload) });
      alert((await res.json()).status);
    } catch (err) { alert("API Connection Failed or Unauthorized."); }
  }

  async function fetchHistory() {
    try {
      const res = await apiFetch(`http://${window.location.hostname}:${API_PORT}/api/history`);
      const data = await res.json();
      const tbody = document.getElementById("historyTableBody");
      tbody.innerHTML = "";
      data.forEach(a => {
        tbody.innerHTML += `<tr><td>${a.timestamp}</td><td>${a.header}</td><td>${a.mode}</td><td>${a.file ? `<a href="http://${window.location.hostname}:${API_PORT}/archive/${a.file}" target="_blank">Play</a>` : "N/A"}</td></tr>`;
      });
    } catch (err) { console.log(err); }
  }
</script>

</body>
</html>
EOF

# --- 3. Generate TaENDEC Daemon ---
echo "Writing Python Daemon..."
cat << 'EOF' | sudo tee "$APP_DIR/endec_system.py" > /dev/null
#!/usr/bin/env python3
"""
TaENDEC Master Telemetry & Streaming Daemon
"""

import os
import sys
import time
import json
import wave
import math
import struct
import base64
import textwrap
import logging
import threading
import subprocess
import queue
import re
import csv
import tzlocal
import urllib.request
import urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler
from datetime import datetime, timezone, timedelta

try:
    import requests
except ImportError:
    requests = None

LOG_DIR = "/home/APP_USER_PLACEHOLDER/logs"
PERSISTENT_AUDIO_DIR = "/var/lib/eas_alerts/audio_archive"
UPLOAD_DIR = "/var/lib/eas_alerts/uploads"
CONFIG_FILE = "/home/APP_USER_PLACEHOLDER/taendec_config.json"
CSV_FILE = "/home/APP_USER_PLACEHOLDER/FIPS Codes.csv"

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
    fips_codes = [f.strip() for f in fips_match.group(1).split("-") if f.strip()] if fips_match else []
    
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
            if has_audio:
                with open(wav_path, "rb") as audio_file:
                    form_data = {"payload_json": (None, json.dumps(payload), "application/json"), "files[0]": (os.path.basename(wav_path), audio_file, "audio/wav")}
                    requests.post(url, files=form_data, timeout=15)
            else:
                requests.post(url, json=payload, timeout=10)
        except Exception: pass

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
            else:
                voice_samples = get_audio_clip_samples(recorded_wav_path, sample_rate)
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
        
        content_length = int(self.headers.get('Content-Length', 0))
        post_data = self.rfile.read(content_length)
        
        try:
            payload = json.loads(post_data.decode("utf-8"))
        except:
            payload = {}

        if self.path == "/api/config":
            try:
                with open(CONFIG_FILE, "w") as f:
                    json.dump(payload, f, indent=2)
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"status": "Configuration Saved Successfully"}).encode("utf-8"))
            except Exception as e:
                self.send_error(500, str(e))
                
        elif self.path == "/api/transmit":
            payload["type"] = "WEB"
            ALERT_QUEUE.put(payload)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"status": "Alert Queued for Live Transmission"}).encode("utf-8"))
            
        elif self.path == "/api/schedule":
            payload["type"] = "WEB"
            start_str = payload.get("startTime", datetime.now().isoformat())
            # Basic ISO format parsing
            start_dt = datetime.fromisoformat(start_str.replace("Z", "+00:00"))
            with STATE_LOCK:
                SCHEDULED_ALERTS.append({"time": start_dt.timestamp(), "payload": payload})
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"status": "Alert Scheduled Successfully"}).encode("utf-8"))
            
        elif self.path == "/api/upload":
            try:
                filename = payload.get("filename", "upload.bin")
                safe_name = "".join(c for c in filename if c.isalnum() or c in "._- ")
                file_path = os.path.join(UPLOAD_DIR, safe_name)
                
                raw_data = payload.get("data", "")
                if "," in raw_data:
                    raw_data = raw_data.split(",")[1]
                    
                with open(file_path, "wb") as f:
                    f.write(base64.b64decode(raw_data))
                    
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"status": "File Uploaded", "path": file_path}).encode("utf-8"))
            except Exception as e:
                self.send_error(500, f"Upload failed: {e}")
        else:
            self.send_error(404, "Endpoint Not Found")

if __name__ == "__main__":
    logger.info("Starting TaENDEC Master Daemon...")
    
    threading.Thread(target=background_audio_worker, daemon=True).start()
    threading.Thread(target=alert_playback_worker, daemon=True).start()
    threading.Thread(target=dynamic_monitor_manager, daemon=True).start()
    threading.Thread(target=schedule_worker, daemon=True).start()
    threading.Thread(target=automated_test_worker, daemon=True).start()
    threading.Thread(target=recording_timeout_worker, daemon=True).start()
    
    launch_idle_screen()
    
    try:
        server = HTTPServer(("0.0.0.0", STATUS_SERVER_PORT), APIHandler)
        logger.info(f"Web UI and API listening on port {STATUS_SERVER_PORT}")
        server.serve_forever()
    except Exception as e:
        logger.error(f"Server crashed: {e}")
    except KeyboardInterrupt:
        pass
    finally:
        if MPV_PROCESS:
            try:
                MPV_PROCESS.terminate()
            except:
                pass
        logger.info("TaENDEC Daemon shutting down.")
EOF

# Inject the dynamic username into the generated python script
echo "Applying user permissions to $APP_USER..."
sudo sed -i "s|APP_USER_PLACEHOLDER|$APP_USER|g" "$APP_DIR/endec_system.py"

# Enforce strict correct ownership for the generated files and log directory
sudo chown -R "$APP_USER:$APP_USER" "$APP_DIR/logs"
sudo chown "$APP_USER:$APP_USER" "$APP_DIR/taendec_config.json"
sudo chown "$APP_USER:$APP_USER" "$APP_DIR/endec_system.py"
sudo chown -R "$APP_USER:$APP_USER" /var/lib/eas_alerts
sudo chmod +x "$APP_DIR/endec_system.py"

# --- 4. Move FIPS CSV File ---
if [ -f "/home/$APP_USER/TaENDEC/FIPS Codes.csv" ]; then
    echo "Moving FIPS Codes.csv into root working directory..."
    mv "/home/$APP_USER/TaENDEC/FIPS Codes.csv" "/home/$APP_USER/"
fi

# --- 5. Generate and Enable systemd Service ---
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

echo "Installation complete! The TaENDEC daemon should now be fully stabilized and running as user: $APP_USER."
