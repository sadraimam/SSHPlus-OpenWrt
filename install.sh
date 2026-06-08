#!/bin/sh

# SSHPlus Standalone Gateway Installer
# Cleans out all proprietary branding and converts tunnel into a system-wide gateway.

echo ">>> Starting Standalone SSHPlus Installation..."

# Create clean config file if it doesn't exist
echo "Creating configuration file..."
[ -f /etc/config/sshplus ] || cat > /etc/config/sshplus <<'EoL'
config sshplus 'global'
	option active_profile ''

config profile 'example'
	option host 'host.example.com'
	option user 'root'
	option port '22'
	option auth_method 'password'
	option pass 'your_password'
	option key_file '/root/.ssh/id_rsa'
EoL

# Update package lists and install essential core tools
echo "Updating package lists..."
opkg update
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to update package lists."
    exit 1
fi

echo "Installing necessary network packages (tun2socks, openssh, sshpass)..."
opkg install curl openssh-client openssh-client-utils sshpass procps-ng-pkill procps-ng-pgrep tun2socks ip-full
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to install standalone gateway dependencies."
    exit 1
fi

echo "Creating clean LuCI interface files..."
mkdir -p /usr/lib/lua/luci/controller /usr/lib/lua/luci/model/cbi /usr/lib/lua/luci/view

# Create Core LuCI Controller (Stripped of all old branding frameworks)
cat > /usr/lib/lua/luci/controller/sshplus.lua <<'EoL'
module("luci.controller.sshplus", package.seeall)
function index()
	if not nixio.fs.access("/etc/init.d/sshplus") then return end
	entry({"admin", "services", "sshplus"}, cbi("sshplus_manager"), "SSHPlus", 10).dependent = true
	entry({"admin", "services", "sshplus_api"}, call("api_handler")).leaf = true
end
function api_handler()
	local action = luci.http.formvalue("action")
	if action == "status" then
		local running = (luci.sys.call("pgrep -f 'sshplus_service' >/dev/null 2>&1") == 0)
		local ip = "N/A"; local uptime = 0; local active_profile_id = luci.sys.exec("uci get sshplus.global.active_profile 2>/dev/null"):gsub("\n","")
		local active_profile_name = "None"
		if active_profile_id ~= "" then
			local user = luci.sys.exec("uci get sshplus." .. active_profile_id .. ".user 2>/dev/null"):gsub("\n","")
			local host = luci.sys.exec("uci get sshplus." .. active_profile_id .. ".host 2>/dev/null"):gsub("\n","")
			if user ~= "" and host ~= "" then active_profile_name = user .. "@" .. host else active_profile_name = active_profile_id end
		end
		if running then
			local f = io.open("/tmp/sshplus_start_time", "r")
			if f then local start_time = tonumber(f:read("*l") or "0"); f:close(); if start_time > 0 then uptime = os.time() - start_time end end
			local ip_handle = io.popen("curl --max-time 5 -s http://ifconfig.me/ip")
			ip = ip_handle:read("*a"):gsub("\n", ""); ip_handle:close()
			if ip == "" then ip = "Routing Active" end
		end
		luci.http.prepare_content("application/json"); luci.http.write_json({running = running, ip = ip, uptime = uptime, profile = active_profile_name})
	elseif action == "toggle" then
		local is_running = (luci.sys.call("pgrep -f 'sshplus_service' >/dev/null 2>&1") == 0)
		if is_running then
			luci.sys.call("/etc/init.d/sshplus stop")
		else
			luci.sys.call("/etc/init.d/sshplus start")
		end
		luci.http.status(200, "OK")
	elseif action == "log" then
		local log_content = ""
		local f = io.open("/tmp/sshplus.log", "r")
		if f then log_content = f:read("*a"); f:close() end
		luci.http.prepare_content("application/json"); luci.http.write_json({log = log_content})
	elseif action == "clear_log" then
		luci.sys.call("echo 'Log cleared at $(date)' > /tmp/sshplus.log")
		luci.http.status(200, "OK")
	end
end
EoL

# Create Core LuCI Model Configuration
cat > /usr/lib/lua/luci/model/cbi/sshplus_manager.lua <<'EoL'
local m = Map("sshplus", "SSHPlus Standalone Gateway", "Configures global SSH transparent proxying routing tables.")
local s_status = m:section(SimpleSection, "System Engine Status"); s_status.template = "sshplus_status_section"
local s_global = m:section(TypedSection, "sshplus", "Global Gateway Target"); s_global.anonymous = true; s_global.addremove = false
local active_profile = s_global:option(ListValue, "active_profile", "Active Outbound Profile")
active_profile:value("", "-- Select Server --")
m.uci:foreach("sshplus", "profile", function(s) active_profile:value(s[".name"], string.format("%s@%s", s.user or "user", s.host or "host")) end)
local s_profiles = m:section(TypedSection, "profile", "Server Profiles"); s_profiles.anonymous = false; s_profiles.addremove = true; s_profiles.sortable = true
s_profiles:option(Value, "host", "SSH Endpoint Host/IP"); s_profiles:option(Value, "user", "Username"); s_profiles:option(Value, "port", "Remote SSH Port").placeholder = "22"
local auth = s_profiles:option(ListValue, "auth_method", "Credential Engine"); auth:value("password", "Password Authentication"); auth:value("key", "Private Key File")
local pass = s_profiles:option(Value, "pass", "Password System"); pass.password = true; pass:depends("auth_method", "password")
local keyfile = s_profiles:option(Value, "key_file", "Private Key System Path"); keyfile:depends("auth_method", "key"); keyfile.placeholder = "/root/.ssh/id_rsa"
return m
EoL

# Create Core LuCI View (Clean layout mapping directly under standard Services)
cat > /usr/lib/lua/luci/view/sshplus_status_section.htm <<'EoL'
<style>
.sshplus-main-container{width:100%;margin:10px auto;background:rgba(0,0,0,0.05);border:1px solid rgba(0,0,0,0.1);border-radius:6px;padding:20px}
.sshplus-layout{display:flex;gap:20px}
.sshplus-log-viewer{flex:1;background-color:#1c1c1c;color:#00ff00;font-family:monospace;font-size:11px;padding:12px;border-radius:4px;height:250px;overflow-y:scroll;white-space:pre-wrap}
.sshplus-status-panel{flex:0 0 240px}
.sshplus-status-row{display:flex;justify-content:space-between;margin-bottom:12px}
.sshplus-status-label{font-weight:bold}
.sshplus-status-state{color:#00aa00;font-weight:bold}
.sshplus-status-state.disconnected{color:#ff0000}
.sshplus-actions{margin-top:15px;display:flex;gap:10px}
.sshplus-btn{flex:1;padding:8px;border-radius:4px;border:none;cursor:pointer;font-weight:bold;color:#fff}
.sshplus-btn.disconnect{background:#cc0000}
.sshplus-btn.connect{background:#00aa00}
.sshplus-btn-clear{background:#555;width:40px}
</style>
<div class="sshplus-main-container">
	<div class="sshplus-layout">
		<div class="sshplus-status-panel">
			<div class="sshplus-status-row"><span class="sshplus-status-label">Profile:</span><span id="profileText">-</span></div>
			<div class="sshplus-status-row"><span class="sshplus-status-label">Gateway Status:</span><span id="statusText" class="sshplus-status-state">Checking...</span></div>
			<div class="sshplus-status-row"><span class="sshplus-status-label">WAN IP:</span><span id="ipText">-</span></div>
			<div class="sshplus-status-row"><span class="sshplus-status-label">Uptime:</span><span id="uptimeText">-</span></div>
			<div class="sshplus-actions">
				<button class="sshplus-btn" id="mainBtn" onclick="toggleService()"></button>
				<button class="sshplus-btn sshplus-btn-clear" onclick="clearLog()">✖</button>
			</div>
		</div>
		<pre id="logViewer" class="sshplus-log-viewer">Initialising...</pre>
	</div>
</div>
<script>
var logPollInterval;
function formatUptime(s){if(isNaN(s)||s<=0)return"-";let h=Math.floor(s/3600);s%=3600;let m=Math.floor(s/60);s=Math.floor(s%60);let t=[];if(h>0){t.push(h+"h")}if(m>0){t.push(m+"m")}if(s>0||t.length===0){t.push(s+"s")}return t.join(" ")}
function updateStatus(){XHR.get('<%=luci.dispatcher.build_url("admin/services/sshplus_api")%>?action=status',null,function(x,st){if(!st)return;let r=st.running,ip=st.ip?.trim()||"N/A",up=st.uptime||0,p=st.profile||"None";let s=document.getElementById("statusText");s.innerHTML=r?"CONNECTED":"DISCONNECTED";s.className="sshplus-status-state"+(r?"":" disconnected");document.getElementById("ipText").innerText=ip;document.getElementById("uptimeText").innerText=formatUptime(up);document.getElementById("profileText").innerText=p;let b=document.getElementById("mainBtn");b.className="sshplus-btn"+(r?" disconnect":" connect");b.innerText=r?"Stop Gateway":"Start Gateway"})}
function pollLog(){XHR.get('<%=luci.dispatcher.build_url("admin/services/sshplus_api")%>?action=log',null,function(x,st){if(!st)return;var v=document.getElementById("logViewer");var isScrolledBottom=v.scrollHeight-v.clientHeight<=v.scrollTop+5;var logText=st.log||"Log empty.";if(v.textContent!==logText){v.textContent=logText;if(isScrolledBottom){v.scrollTop=v.scrollHeight}}})}
function toggleService(){var b=document.getElementById("mainBtn");b.disabled=true;XHR.get('<%=luci.dispatcher.build_url("admin/services/sshplus_api")%>?action=toggle',null,function(){setTimeout(function(){updateStatus();pollLog();b.disabled=false},2000)})}
function clearLog(){XHR.get('<%=luci.dispatcher.build_url("admin/services/sshplus_api")%>?action=clear_log',null,function(){pollLog()})}
function startPolling(){if(!logPollInterval){logPollInterval=setInterval(function(){updateStatus();pollLog()},2500)}updateStatus();pollLog()}
window.addEventListener('load',startPolling);
</script>
EoL

echo "Creating unified daemon hooks..."
# Create clean init.d process tracker
cat > /etc/init.d/sshplus <<'EoL'
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1

start_service() {
	procd_open_instance
	procd_set_param command /usr/bin/sshplus_service
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_set_param respawn
	procd_close_instance
}

stop_service() {
	pkill -f "/usr/bin/sshplus_service"
	pkill -f "sshpass.*-D 127.0.0.1:8089"
	pkill -f "tun2socks"
	
	# Clean global IP route components completely on stop execution
	ip route del default dev tun0 table 200 2>/dev/null
	ip rule del fwmark 1 table 200 2>/dev/null
	iptables -t mangle -D PREROUTING -i br-lan -j SSHPLUS_MARK 2>/dev/null
	iptables -t mangle -F SSHPLUS_MARK 2>/dev/null
	iptables -t mangle -X SSHPLUS_MARK 2>/dev/null
	ip link del tun0 2>/dev/null
	rm -f /tmp/sshplus_start_time
}
EoL
chmod +x /etc/init.d/sshplus

# Create the primary transparent proxy routing logic engine
cat > /usr/bin/sshplus_service <<'EoL'
#!/bin/sh
exec >> /tmp/sshplus.log 2>&1

SSH_BIN="/usr/bin/ssh"
while true; do
	ACTIVE_PROFILE=$(uci get sshplus.global.active_profile 2>/dev/null)
	if [ -z "$ACTIVE_PROFILE" ]; then
		echo "CRITICAL: No target profile selected. Sleeping..."
		sleep 60
		continue
	fi
	
	HOST=$(uci get sshplus.$ACTIVE_PROFILE.host 2>/dev/null)
	USER=$(uci get sshplus.$ACTIVE_PROFILE.user 2>/dev/null)
	PORT=$(uci get sshplus.$ACTIVE_PROFILE.port 2>/dev/null)
	AUTH_METHOD=$(uci get sshplus.$ACTIVE_PROFILE.auth_method 2>/dev/null)
	PASS=$(uci get sshplus.$ACTIVE_PROFILE.pass 2>/dev/null)
	KEY_FILE=$(uci get sshplus.$ACTIVE_PROFILE.key_file 2>/dev/null)
	
	# Resolve destination IP manually to avoid routing loop blackholes
	SERVER_IP=$(nslookup "$HOST" 8.8.8.8 | awk '/Address/ {print $3}' | tail -n1)
	[ -z "$SERVER_IP" ] && SERVER_IP=$HOST

	echo "Found destination gateway address: $SERVER_IP"
	date +%s > /tmp/sshplus_start_time
	
	# Fire local SOCKS5 proxy server instance
	SSH_CMD="-v -T -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o ExitOnForwardFailure=yes -D 127.0.0.1:8089 -N -p $PORT $USER@$HOST"
	if [ "$AUTH_METHOD" = "key" ]; then
		/usr/bin/stdbuf -o0 $SSH_BIN -i "$KEY_FILE" $SSH_CMD &
	else
		/usr/bin/stdbuf -o0 sshpass -p "$PASS" $SSH_BIN $SSH_CMD &
	fi
	
	sleep 4
	
	# Instantiate Virtual layer 3 tunnel device interface
	echo "Building layer 3 tunnel virtual environment..."
	ip tuntap add dev tun0 mode tun 2>/dev/null
	ip link set dev tun0 up
	ip address add 10.0.0.1/24 dev tun0
	
	# Launch tun2socks engine wrapper to bridge IP layer into SOCKS5 structural loop
	tun2socks -device tun0 -proxy socks5://127.0.0.1:8089 &
	sleep 2
	
	# Build routing rules: Avoid proxying the SSH server itself (creates loop freeze)
	echo "Injecting clean routing rules engines..."
	ip route add "$SERVER_IP" via $(ip route show | awk '/default/ {print $3}') 2>/dev/null
	
	# Map custom secondary default route tables through the tunnel
	ip route add default dev tun0 table 200 2>/dev/null
	ip rule add fwmark 1 table 200 2>/dev/null
	
	# Use Firewall mangle markers to throw LAN traffic down the newly created tun0 gateway
	iptables -t mangle -N SSHPLUS_MARK 2>/dev/null
	iptables -t mangle -F SSHPLUS_MARK
	iptables -t mangle -A SSHPLUS_MARK -d 192.168.0.0/16 -j RETURN
	iptables -t mangle -A SSHPLUS_MARK -d 10.0.0.0/8 -j RETURN
	iptables -t mangle -A SSHPLUS_MARK -j MARK --set-mark 1
	iptables -t mangle -A PREROUTING -i br-lan -j SSHPLUS_MARK
	
	echo "System-wide network gateway routing rules applied successfully."
	
	# Keep service foreground check loop alive to handle reconnection states safely
	while pgrep -f "ssh.*127.0.0.1:8089" >/dev/null; do
		sleep 10
	done
	
	echo "Outbound structural link drop encountered. Dropping gateway engine tables..."
	# Clean up routing before trying to reconnect or loop back around
	iptables -t mangle -D PREROUTING -i br-lan -j SSHPLUS_MARK 2>/dev/null
	ip rule del fwmark 1 table 200 2>/dev/null
	ip route del default dev tun0 table 200 2>/dev/null
	pkill -f "tun2socks"
	ip link del tun0 2>/dev/null
	rm -f /tmp/sshplus_start_time
	sleep 5
done
EoL
chmod +x /usr/bin/sshplus_service

# Clear the index cache entirely to drop old custom branding tabs
rm -rf /tmp/luci-indexcache

echo "Enabling and starting service daemon..."
/etc/init.d/sshplus enable
/etc/init.d/sshplus restart

echo ">>> Installation complete. SSHPlus is now running as a standalone system gateway."
