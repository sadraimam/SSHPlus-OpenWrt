#!/bin/sh

# SSHPlus Standalone Gateway - Native FW4 & Redsocks Architecture
# Built for OpenWrt 22.03.3 (LuCI API-Driven, Zero Legacy Dependencies)
# Hardened Edition: Explicit UCI syntax and native async process handling.

echo ">>> Initialising SSHPlus Master Installation..."

echo "[1/6] Updating package indexes and installing core binaries..."
opkg update
opkg install curl openssh-client openssh-client-utils sshpass procps-ng-pkill procps-ng-pgrep redsocks
if [ $? -ne 0 ]; then
    echo "CRITICAL ERROR: Failed to install native dependencies. Check internet connection."
    exit 1
fi

echo "[2/6] Building base UCI configuration..."
[ -f /etc/config/sshplus ] || cat > /etc/config/sshplus <<'EoL'
config sshplus 'global'
	option active_profile 'profile'

config profile 'profile'
	option host ''
	option user 'root'
	option port '22'
	option auth_method 'password'
	option pass ''
	option key_file '/root/.ssh/id_rsa'
EoL

echo "[3/6] Compiling Native API Controller..."
mkdir -p /usr/lib/lua/luci/controller /usr/lib/lua/luci/view
cat > /usr/lib/lua/luci/controller/sshplus.lua <<'EoL'
module("luci.controller.sshplus", package.seeall)

function index()
	if not nixio.fs.access("/etc/init.d/sshplus") then return end
	entry({"admin", "services", "sshplus"}, template("sshplus_view"), "SSHPlus", 10).dependent = true
	entry({"admin", "services", "sshplus_api"}, call("api_handler")).leaf = true
end

function api_handler()
	local action = luci.http.formvalue("action")
	
	if action == "status" then
		local running = (luci.sys.call("pgrep -f 'sshplus_service' >/dev/null 2>&1") == 0)
		local ip = "N/A"; local uptime = 0
		local active_profile = luci.sys.exec("uci get sshplus.global.active_profile 2>/dev/null"):gsub("\n","")
		
		if running then
			local f = io.open("/tmp/sshplus_start_time", "r")
			if f then 
				local start_time = tonumber(f:read("*l") or "0")
				f:close()
				if start_time > 0 then uptime = os.time() - start_time end 
			end
			local ip_handle = io.popen("curl --max-time 4 -s http://ifconfig.me/ip")
			ip = ip_handle:read("*a"):gsub("\n", ""); ip_handle:close()
			if ip == "" then ip = "Routing Active" end
		end
		
		luci.http.prepare_content("application/json")
		luci.http.write_json({running = running, ip = ip, uptime = uptime, profile = active_profile})
		
	elseif action == "get_config" then
		local host = luci.sys.exec("uci get sshplus.profile.host 2>/dev/null"):gsub("\n","")
		local user = luci.sys.exec("uci get sshplus.profile.user 2>/dev/null"):gsub("\n","")
		local port = luci.sys.exec("uci get sshplus.profile.port 2>/dev/null"):gsub("\n","")
		local auth = luci.sys.exec("uci get sshplus.profile.auth_method 2>/dev/null"):gsub("\n","")
		local pass = luci.sys.exec("uci get sshplus.profile.pass 2>/dev/null"):gsub("\n","")
		local key = luci.sys.exec("uci get sshplus.profile.key_file 2>/dev/null"):gsub("\n","")
		
		luci.http.prepare_content("application/json")
		luci.http.write_json({host=host, user=user, port=port, auth=auth, pass=pass, key=key})
		
	elseif action == "save_config" then
		local host = luci.http.formvalue("host")
		local user = luci.http.formvalue("user")
		local port = luci.http.formvalue("port")
		local auth = luci.http.formvalue("auth")
		local pass = luci.http.formvalue("pass")
		local key = luci.http.formvalue("key")
		
		luci.sys.call("uci set sshplus.profile=profile 2>/dev/null || uci add sshplus profile")
		luci.sys.call("uci set sshplus.profile.host='" .. (host or "") .. "'")
		luci.sys.call("uci set sshplus.profile.user='" .. (user or "root") .. "'")
		luci.sys.call("uci set sshplus.profile.port='" .. (port or "22") .. "'")
		luci.sys.call("uci set sshplus.profile.auth_method='" .. (auth or "password") .. "'")
		luci.sys.call("uci set sshplus.profile.pass='" .. (pass or "") .. "'")
		luci.sys.call("uci set sshplus.profile.key_file='" .. (key or "/root/.ssh/id_rsa") .. "'")
		luci.sys.call("uci set sshplus.global.active_profile='profile'")
		luci.sys.call("uci commit sshplus")
		
		luci.http.status(200, "OK")
		
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
		luci.http.prepare_content("application/json")
		luci.http.write_json({log = log_content})
		
	elseif action == "clear_log" then
		luci.sys.call("echo 'Log cleared at $(date)' > /tmp/sshplus.log")
		luci.http.status(200, "OK")
	end
end
EoL

echo "[4/6] Building API-Driven Native View Template..."
cat > /usr/lib/lua/luci/view/sshplus_view.htm <<'EoL'
<%+header%>
<div class="cbi-map">
	<h2 class="title">SSHPlus Standalone Gateway</h2>
	<div class="cbi-map-descr">Global high-performance SSH transparent proxy routing, operating entirely on layer-3.</div>
	
	<fieldset class="cbi-section">
		<legend>Routing Engine Status</legend>
		<table class="table" style="width: 100%; max-width: 600px; margin: 10px 0;">
			<tr><td width="33%"><strong>Gateway State:</strong></td><td id="statusText" style="font-weight:bold; color:#cc0000;">Checking...</td></tr>
			<tr><td><strong>Outbound WAN IP:</strong></td><td id="ipText">-</td></tr>
			<tr><td><strong>Session Uptime:</strong></td><td id="uptimeText">-</td></tr>
		</table>
		<div class="cbi-section-node">
			<button class="cbi-button cbi-button-apply" id="mainBtn" onclick="toggleService()" style="min-width: 140px; font-weight: bold;">-</button>
		</div>
	</fieldset>

	<fieldset class="cbi-section">
		<legend>Target Server Configuration</legend>
		<div class="cbi-section-node">
			<div class="cbi-value">
				<label class="cbi-value-title">SSH Host / IP</label>
				<div class="cbi-value-field"><input type="text" class="cbi-input-text" id="cfg_host" style="width:300px;" placeholder="server.example.com" /></div>
			</div>
			<div class="cbi-value">
				<label class="cbi-value-title">SSH Port</label>
				<div class="cbi-value-field"><input type="text" class="cbi-input-text" id="cfg_port" style="width:100px;" placeholder="22" /></div>
			</div>
			<div class="cbi-value">
				<label class="cbi-value-title">Username</label>
				<div class="cbi-value-field"><input type="text" class="cbi-input-text" id="cfg_user" style="width:300px;" placeholder="root" /></div>
			</div>
			<div class="cbi-value">
				<label class="cbi-value-title">Auth Method</label>
				<div class="cbi-value-field">
					<select class="cbi-input-select" id="cfg_auth" onchange="toggleAuthFields()">
						<option value="password">Password Authentication</option>
						<option value="key">Private Key (Ed25519/RSA)</option>
					</select>
				</div>
			</div>
			<div class="cbi-value" id="row_pass">
				<label class="cbi-value-title">Password</label>
				<div class="cbi-value-field"><input type="password" class="cbi-input-text" id="cfg_pass" style="width:300px;" /></div>
			</div>
			<div class="cbi-value" id="row_key" style="display:none;">
				<label class="cbi-value-title">Key File Path</label>
				<div class="cbi-value-field"><input type="text" class="cbi-input-text" id="cfg_key" style="width:300px;" placeholder="/root/.ssh/id_rsa" /></div>
			</div>
		</div>
		<div class="cbi-section-node" style="margin-top:15px;">
			<button class="cbi-button cbi-button-save" onclick="saveConfig()" style="font-weight:bold; min-width:140px;">Save & Apply</button>
		</div>
	</fieldset>

	<fieldset class="cbi-section">
		<legend>Daemon Logs <button class="cbi-button cbi-button-reset" style="margin-left:15px; font-size:10px; padding:2px 8px;" onclick="clearLog()">Clear Trace</button></legend>
		<pre id="logViewer" style="background:#111; color:#0f0; padding:12px; font-family:monospace; font-size:12px; height:250px; overflow-y:scroll; border-radius:4px; white-space:pre-wrap; margin-top:10px;">Loading...</pre>
	</fieldset>
</div>

<script>
function formatUptime(s){if(isNaN(s)||s<=0)return"-";let h=Math.floor(s/3600);s%=3600;let m=Math.floor(s/60);s=Math.floor(s%60);let t=[];if(h>0)t.push(h+"h");if(m>0)t.push(m+"m");if(s>0||t.length===0)t.push(s+"s");return t.join(" ")}

function toggleAuthFields() {
	var auth = document.getElementById("cfg_auth").value;
	document.getElementById("row_pass").style.display = (auth === "password") ? "block" : "none";
	document.getElementById("row_key").style.display = (auth === "key") ? "block" : "none";
}

function updateStatus(){
	XHR.get('<%=luci.dispatcher.build_url("admin/services/sshplus_api")%>?action=status',null,function(x,st){
		if(!st) return;
		document.getElementById("statusText").innerText = st.running ? "CONNECTED & ROUTING" : "DISCONNECTED";
		document.getElementById("statusText").style.color = st.running ? "#00cc00" : "#cc0000";
		document.getElementById("ipText").innerText = st.ip || "N/A";
		document.getElementById("uptimeText").innerText = formatUptime(st.uptime);
		let b = document.getElementById("mainBtn");
		b.innerText = st.running ? "Terminate Tunnel" : "Initialize Gateway";
		b.className = st.running ? "cbi-button cbi-button-reset" : "cbi-button cbi-button-apply";
	});
}

function pollLog(){
	XHR.get('<%=luci.dispatcher.build_url("admin/services/sshplus_api")%>?action=log',null,function(x,st){
		if(!st) return;
		var v = document.getElementById("logViewer");
		var isBottom = v.scrollHeight - v.clientHeight <= v.scrollTop + 5;
		v.textContent = st.log || "Log trace window empty.";
		if(isBottom) v.scrollTop = v.scrollHeight;
	});
}

function loadConfig(){
	XHR.get('<%=luci.dispatcher.build_url("admin/services/sshplus_api")%>?action=get_config',null,function(x,cfg){
		if(!cfg) return;
		if(cfg.host) document.getElementById("cfg_host").value = cfg.host;
		if(cfg.user) document.getElementById("cfg_user").value = cfg.user;
		if(cfg.port) document.getElementById("cfg_port").value = cfg.port;
		if(cfg.auth) document.getElementById("cfg_auth").value = cfg.auth;
		if(cfg.pass) document.getElementById("cfg_pass").value = cfg.pass;
		if(cfg.key) document.getElementById("cfg_key").value = cfg.key;
		toggleAuthFields();
	});
}

function saveConfig(){
	var h = encodeURIComponent(document.getElementById("cfg_host").value);
	var u = encodeURIComponent(document.getElementById("cfg_user").value);
	var p = encodeURIComponent(document.getElementById("cfg_port").value || "22");
	var a = encodeURIComponent(document.getElementById("cfg_auth").value);
	var s = encodeURIComponent(document.getElementById("cfg_pass").value);
	var k = encodeURIComponent(document.getElementById("cfg_key").value);
	
	XHR.get('<%=luci.dispatcher.build_url("admin/services/sshplus_api")%>?action=save_config&host='+h+'&user='+u+'&port='+p+'&auth='+a+'&pass='+s+'&key='+k, null, function(){
		alert("Configuration matrices written to UCI.");
		updateStatus();
	});
}

function toggleService(){
	var b = document.getElementById("mainBtn"); b.disabled = true;
	XHR.get('<%=luci.dispatcher.build_url("admin/services/sshplus_api")%>?action=toggle',null,function(){
		setTimeout(function(){ updateStatus(); pollLog(); b.disabled = false; }, 1500);
	});
}

function clearLog(){ XHR.get('<%=luci.dispatcher.build_url("admin/services/sshplus_api")%>?action=clear_log',function(){ pollLog(); }); }

window.addEventListener('load', function(){
	loadConfig(); updateStatus(); pollLog();
	setInterval(function(){ updateStatus(); pollLog(); }, 3000);
});
</script>
<%+footer%>
EoL

echo "[5/6] Building Process Trackers & Routing Engine..."
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
	pkill -f "ssh.*127.0.0.1:8089"
	pkill -f "redsocks.*12345"
	
	# Strip our inclusion scripts from the fw4 nftables stack
	uci -q delete firewall.sshplus_include
	uci commit firewall
	fw4 reload || /etc/init.d/firewall reload
	rm -f /tmp/sshplus_start_time
}
EoL
chmod +x /etc/init.d/sshplus

mkdir -p /var/etc
cat > /usr/bin/sshplus_service <<'EoL'
#!/bin/sh
exec >> /tmp/sshplus.log 2>&1
echo "========================================="
echo "SSHPlus Service Initiated: $(date)"

# Wait for a valid profile
ACTIVE_PROFILE=$(uci get sshplus.global.active_profile 2>/dev/null)
if [ -z "$ACTIVE_PROFILE" ]; then
	echo "Awaiting valid configuration profile..."
	exit 0
fi

HOST=$(uci get sshplus.$ACTIVE_PROFILE.host 2>/dev/null)
USER=$(uci get sshplus.$ACTIVE_PROFILE.user 2>/dev/null)
PORT=$(uci get sshplus.$ACTIVE_PROFILE.port 2>/dev/null)
AUTH=$(uci get sshplus.$ACTIVE_PROFILE.auth_method 2>/dev/null)
PASS=$(uci get sshplus.$ACTIVE_PROFILE.pass 2>/dev/null)
KEY=$(uci get sshplus.$ACTIVE_PROFILE.key_file 2>/dev/null)

if [ -z "$HOST" ]; then
	echo "CRITICAL: Hostname/IP missing. Terminating."
	exit 1
fi

SERVER_IP=$(nslookup "$HOST" 8.8.8.8 | awk '/Address/ {print $3}' | tail -n1)
[ -z "$SERVER_IP" ] && SERVER_IP=$HOST
echo "Resolved target remote IP: $SERVER_IP"

# Instantiate Local SOCKS5 Proxy
date +%s > /tmp/sshplus_start_time
echo "Firing SSH local tunnel forwarder (-D 127.0.0.1:8089)..."
SSH_CMD="-v -T -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o ExitOnForwardFailure=yes -D 127.0.0.1:8089 -N -p $PORT $USER@$HOST"

if [ "$AUTH" = "key" ]; then
	ssh -i "$KEY" $SSH_CMD &
else
	sshpass -p "$PASS" ssh $SSH_CMD &
fi

sleep 4

# Initialize Layer-3 Redsocks Translator
echo "Building layer-3 transparent redsocks redirector..."
cat > /var/etc/redsocks_sshplus.conf <<EOF
base { log_debug = off; log_info = off; log = "file:/tmp/redsocks.log"; daemon = on; redirector = iptables; }
redsocks { local_ip = 127.0.0.1; local_port = 12345; ip = 127.0.0.1; port = 8089; type = socks5; }
EOF

pkill -f "redsocks_sshplus.conf" 2>/dev/null
redsocks -c /var/etc/redsocks_sshplus.conf &
sleep 2

# Inject Firewall-4 (nftables) Directives
echo "Compiling and injecting fw4 nftables routing map..."
cat > /tmp/sshplus_nft.include <<EOF
#!/usr/sbin/nft -f
table inet fw4 {
    chain sshplus_mangle {
        type filter hook prerouting priority mangle; policy accept;
        
        # Exclude LAN/Local/Private subnets from the tunnel loop
        ip daddr { 127.0.0.0/8, 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12 } return
        
        # Exclude the exact IP of the remote VPS to avoid infinite routing blackholes
        ip daddr $SERVER_IP return
        
        # Force all remaining outbound TCP packets to hit the local redsocks interceptor
        ip protocol tcp redirect to :12345
    }
}
EOF
chmod +x /tmp/sshplus_nft.include

# Setup explicit UCI block for firewall inclusion
uci -q delete firewall.sshplus_include
uci set firewall.sshplus_include=include
uci set firewall.sshplus_include.type='script'
uci set firewall.sshplus_include.path='/tmp/sshplus_nft.include'
uci set firewall.sshplus_include.reload='1'
uci commit firewall

fw4 reload || /etc/init.d/firewall reload
echo "Routing successfully hijacked. Traffic is now flowing through the encrypted tunnel."

# Persistent Daemon State Monitor
while pgrep -f "ssh.*127.0.0.1:8089" >/dev/null; do
	sleep 10
done

echo "CRITICAL: Tunnel connection unexpectedly dropped. Cleaning routing tables and restarting..."
uci -q delete firewall.sshplus_include
uci commit firewall
fw4 reload || /etc/init.d/firewall reload
pkill -f "redsocks_sshplus.conf"
rm -f /tmp/sshplus_start_time
exit 1
EoL
chmod +x /usr/bin/sshplus_service

echo "[6/6] Finalizing installation & clearing UI caches..."
rm -rf /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache
/etc/init.d/sshplus enable

echo ""
echo ">>> Installation Complete!"
echo ">>> Head over to LuCI -> Services -> SSHPlus to manage the gateway."
