#!/bin/ash
#
# Xray OpenWrt TProxy Installer
#
# Installs and configures a complete Xray + TProxy transparent proxy stack
# for OpenWrt / GL.iNet routers.
#
# Features:
# - installs required dependencies with opkg
# - installs xray-core from repo or direct .ipk URL
# - supports VLESS + REALITY with:
#   - XHTTP
#   - TCP
# - configures transparent interception with TProxy
# - writes persistent init scripts
# - disables/removes sing-box optionally
# - runs automatic post-install validation
# - supports validation again later from the main menu
#
# Installed files:
# - /etc/xray/config.json
# - /etc/init.d/xray
# - /etc/init.d/xray-tproxy
#
# Usage:
#   wget -O /tmp/install.sh https://raw.githubusercontent.com/<YOUR_USERNAME>/<YOUR_REPO>/main/install.sh
#   chmod +x /tmp/install.sh
#   /tmp/install.sh
#
# Notes:
# - run as root
# - intended for OpenWrt / GL.iNet environments with opkg available
# - split tunneling rules are embedded in the installer template
# - validates config before enabling the stack
#
# License:
# - MIT

set -eu

APP_NAME="Xray OpenWrt TProxy Installer"
VERSION="1.1"

XRAY_CFG_DIR="/etc/xray"
XRAY_CFG_FILE="/etc/xray/config.json"
XRAY_INIT="/etc/init.d/xray"
XRAY_TPROXY_INIT="/etc/init.d/xray-tproxy"
BACKUP_DIR_BASE="/root/xray-installer-backups"
STATE_FILE="/root/.xray_tproxy_installer_state"

FORCE_COLOR="${FORCE_COLOR:-1}"

if [ "$FORCE_COLOR" = "1" ] || [ -t 1 ] || [ -n "${TERM:-}" ]; then
  C_RESET="$(printf '\033[0m')"
  C_RED="$(printf '\033[31m')"
  C_GREEN="$(printf '\033[32m')"
  C_YELLOW="$(printf '\033[33m')"
  C_BLUE="$(printf '\033[34m')"
  C_MAGENTA="$(printf '\033[35m')"
  C_CYAN="$(printf '\033[36m')"
  C_BOLD="$(printf '\033[1m')"
else
  C_RESET=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_MAGENTA=""
  C_CYAN=""
  C_BOLD=""
fi

info()  { echo "${C_CYAN}$*${C_RESET}"; }
ok()    { echo "${C_GREEN}$*${C_RESET}"; }
warn()  { echo "${C_YELLOW}$*${C_RESET}"; }
err()   { echo "${C_RED}$*${C_RESET}" >&2; }
note()  { echo "${C_BLUE}$*${C_RESET}"; }
step()  { echo "${C_MAGENTA}${C_BOLD}$*${C_RESET}"; }
title() { echo "${C_BOLD}${C_BLUE}$*${C_RESET}"; }
die()   { err "ERROR: $*"; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

ask() {
  prompt="$1"
  default="${2:-}"
  if [ -n "$default" ]; then
    printf "%s [%s]: " "$prompt" "$default" >&2
  else
    printf "%s: " "$prompt" >&2
  fi
  IFS= read -r value || true
  if [ -z "${value:-}" ]; then
    value="$default"
  fi
  printf '%s' "$value"
}

ask_required() {
  prompt="$1"
  default="${2:-}"
  while :; do
    val="$(ask "$prompt" "$default")"
    if [ -n "$val" ]; then
      printf '%s' "$val"
      return 0
    fi
    warn "Value is required."
  done
}

ask_yes_no() {
  prompt="$1"
  default="${2:-y}"
  while :; do
    ans="$(ask "$prompt" "$default")"
    case "$ans" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) warn "Please answer y or n." ;;
    esac
  done
}

validate_transport() {
  case "$1" in
    xhttp|tcp) return 0 ;;
    *) return 1 ;;
  esac
}

install_pkg_if_missing() {
  pkg="$1"
  if ! opkg list-installed | grep -q "^${pkg} "; then
    info "Installing package: $pkg"
    opkg install "$pkg"
  else
    ok "Package already installed: $pkg"
  fi
}

timestamp() {
  date +"%Y%m%d-%H%M%S"
}

backup_existing_files() {
  bdir="$BACKUP_DIR_BASE/backup-$(timestamp)"
  mkdir -p "$BACKUP_DIR_BASE" "$bdir"
  [ -f "$XRAY_CFG_FILE" ] && cp -a "$XRAY_CFG_FILE" "$bdir/config.json"
  [ -f "$XRAY_INIT" ] && cp -a "$XRAY_INIT" "$bdir/init_xray"
  [ -f "$XRAY_TPROXY_INIT" ] && cp -a "$XRAY_TPROXY_INIT" "$bdir/init_xray_tproxy"
  [ -d "$XRAY_CFG_DIR" ] && cp -a "$XRAY_CFG_DIR" "$bdir/xray_dir" 2>/dev/null || true
  echo "$bdir" > "$STATE_FILE.backupdir"
  ok "Backup saved to: $bdir"
}

save_state() {
  cat > "$STATE_FILE" <<EOF
SERVER_HOST=$(json_escape "$SERVER_HOST")
SERVER_PORT=$(json_escape "$SERVER_PORT")
TRANSPORT=$(json_escape "$TRANSPORT")
WAN_IF=$(json_escape "$WAN_IF")
LAN_IF=$(json_escape "$LAN_IF")
XRAY_CONFIG=$XRAY_CFG_FILE
EOF
}

load_state_if_present() {
  if [ -f "$STATE_FILE" ]; then
    . "$STATE_FILE"
    return 0
  fi
  return 1
}

xray_check() {
  cfg="$1"
  [ -f "$cfg" ] || return 1
  xray run -test -config "$cfg" >/dev/null 2>&1
}

write_xray_init() {
  cat > "$XRAY_INIT" <<'EOF'
#!/bin/sh /etc/rc.common

START=95
STOP=10
USE_PROCD=1

BIN="/usr/bin/xray"
CFG="/etc/xray/config.json"

validate_config() {
  [ -x "$BIN" ] || return 1
  [ -f "$CFG" ] || return 1
  "$BIN" run -test -config "$CFG" >/dev/null 2>&1
}

start_service() {
  validate_config || {
    echo "xray: config check FAILED ($CFG). Not starting."
    return 1
  }

  procd_open_instance
  procd_set_param command "$BIN" run -config "$CFG"
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_set_param respawn
  procd_set_param file "$CFG"
  procd_set_param pidfile /var/run/xray.pid
  procd_close_instance
}
EOF
  chmod +x "$XRAY_INIT"
}

write_xray_tproxy_init() {
  lan_if="$1"
  server_host="$2"

  cat > "$XRAY_TPROXY_INIT" <<EOF
#!/bin/sh /etc/rc.common

START=96
STOP=09

XRAY_PORT="12345"
XRAY_MARK="0x111"
XRAY_TABLE="111"
LAN_IF="$(json_escape "$lan_if")"
SERVER_HOST="$(json_escape "$server_host")"

boot() {
  start
}

start() {
  WAN_IF="\$(ubus call network.interface.wan status | jsonfilter -e '@.l3_device')"
  WAN_GW="\$(ubus call network.interface.wan status | jsonfilter -e '@.route[0].nexthop')"
  SERVER_IP="\$(resolveip -4 "\$SERVER_HOST" | tail -n1)"

  [ -n "\$WAN_IF" ] || {
    echo "xray-tproxy: WAN_IF is empty"
    return 1
  }

  [ -n "\$WAN_GW" ] || {
    echo "xray-tproxy: WAN_GW is empty"
    return 1
  }

  [ -n "\$SERVER_IP" ] || {
    echo "xray-tproxy: SERVER_IP is empty"
    return 1
  }

  ip rule del iif br-lan lookup 2022 2>/dev/null || true
  ip rule del fwmark 0x1 lookup vpn 2>/dev/null || true

  ip route replace "\${SERVER_IP}/32" via "\${WAN_GW}" dev "\${WAN_IF}"

  ip rule del fwmark \${XRAY_MARK} lookup \${XRAY_TABLE} 2>/dev/null || true
  ip route flush table \${XRAY_TABLE} 2>/dev/null || true

  ip rule add fwmark \${XRAY_MARK} lookup \${XRAY_TABLE}
  ip route add local 0.0.0.0/0 dev lo table \${XRAY_TABLE}

  iptables -t mangle -N XRAY 2>/dev/null || true
  iptables -t mangle -F XRAY

  iptables -t mangle -A XRAY -d 0.0.0.0/8 -j RETURN
  iptables -t mangle -A XRAY -d 10.0.0.0/8 -j RETURN
  iptables -t mangle -A XRAY -d 100.64.0.0/10 -j RETURN
  iptables -t mangle -A XRAY -d 127.0.0.0/8 -j RETURN
  iptables -t mangle -A XRAY -d 169.254.0.0/16 -j RETURN
  iptables -t mangle -A XRAY -d 172.16.0.0/12 -j RETURN
  iptables -t mangle -A XRAY -d 192.168.0.0/16 -j RETURN
  iptables -t mangle -A XRAY -d 224.0.0.0/4 -j RETURN
  iptables -t mangle -A XRAY -d 240.0.0.0/4 -j RETURN
  iptables -t mangle -A XRAY -d "\${SERVER_IP}/32" -j RETURN

  iptables -t mangle -D PREROUTING -i \${LAN_IF} -p tcp -j XRAY 2>/dev/null || true
  iptables -t mangle -D PREROUTING -i \${LAN_IF} -p udp -j XRAY 2>/dev/null || true

  iptables -t mangle -A XRAY -p tcp -j TPROXY --on-port \${XRAY_PORT} --tproxy-mark \${XRAY_MARK}/\${XRAY_MARK}
  iptables -t mangle -A XRAY -p udp -j TPROXY --on-port \${XRAY_PORT} --tproxy-mark \${XRAY_MARK}/\${XRAY_MARK}

  iptables -t mangle -A PREROUTING -i \${LAN_IF} -p tcp -j XRAY
  iptables -t mangle -A PREROUTING -i \${LAN_IF} -p udp -j XRAY
}

stop() {
  iptables -t mangle -D PREROUTING -i \${LAN_IF} -p tcp -j XRAY 2>/dev/null || true
  iptables -t mangle -D PREROUTING -i \${LAN_IF} -p udp -j XRAY 2>/dev/null || true
  iptables -t mangle -F XRAY 2>/dev/null || true
  iptables -t mangle -X XRAY 2>/dev/null || true

  ip rule del fwmark \${XRAY_MARK} lookup \${XRAY_TABLE} 2>/dev/null || true
  ip route flush table \${XRAY_TABLE} 2>/dev/null || true

  ip rule del iif br-lan lookup 2022 2>/dev/null || true
  ip rule del fwmark 0x1 lookup vpn 2>/dev/null || true
}
EOF
  chmod +x "$XRAY_TPROXY_INIT"
}

write_common_routing_block() {
  cat <<'EOF'
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules": [
      {
        "type": "field",
        "domain": [
          "domain:__SERVER_HOST__"
        ],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "ip": [
          "127.0.0.0/8",
          "10.0.0.0/8",
          "172.16.0.0/12",
          "192.168.0.0/16",
          "169.254.0.0/16",
          "::1/128",
          "fc00::/7",
          "fe80::/10"
        ],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "domain": [
          "domain:cp.cloudflare.com",
          "domain:api.deepl.com",
          "domain:cdn.deepl.com",
          "domain:deepl.com",
          "domain:deeplstatic.com",
          "domain:dl-abtest.deepl.com",
          "domain:dl-prod.deepl.com",
          "domain:dl-web.deepl.com",
          "domain:images.deepl.com",
          "domain:prod.deepl.com",
          "domain:s.deepl.com",
          "domain:s.deeplstatic.com",
          "domain:static.deepl.com",
          "domain:www.deepl.com",
          "domain:www2.deepl.com",
          "domain:dis.gd",
          "domain:discord.co",
          "domain:discord.com",
          "domain:discord.design",
          "domain:discord.dev",
          "domain:discord.gg",
          "domain:discord.gift",
          "domain:discord.gifts",
          "domain:discord.media",
          "domain:discord.new",
          "domain:discord.store",
          "domain:discord.tools",
          "domain:discordapp.com",
          "domain:discordapp.dev",
          "domain:discordapp.net",
          "domain:discordcdn.com",
          "domain:clients2.google.com",
          "domain:clients3.google.com",
          "domain:clients4.google.com",
          "domain:clients6.google.com",
          "domain:ggpht.com",
          "domain:googleapis.com",
          "domain:googleusercontent.com",
          "domain:googlevideo.com",
          "domain:gstatic.com",
          "domain:manifest.googlevideo.com",
          "domain:meet.google.com",
          "domain:meetings.googleapis.com",
          "domain:play.google.com",
          "domain:redirector.googlevideo.com",
          "domain:youtu.be",
          "domain:youtube.com",
          "domain:youtube.googleapis.com",
          "domain:youtubei.googleapis.com",
          "domain:yt3.ggpht.com",
          "domain:yt3.googleusercontent.com",
          "domain:ytimg.com",
          "domain:ytimg.l.google.com",
          "domain:cdninstagram.com",
          "domain:facebook-hardware.com",
          "domain:facebook.com",
          "domain:fb.com",
          "domain:fbcdn.com",
          "domain:fbsbx.com",
          "domain:graph.facebook-hardware.com",
          "domain:graph.oculus.com",
          "domain:horizon.meta.com",
          "domain:instagram.com",
          "domain:m.me",
          "domain:messenger.com",
          "domain:meta.com",
          "domain:mmg.whatsapp.net",
          "domain:oculus.com",
          "domain:oculuscdn.com",
          "domain:oculusvr.com",
          "domain:static.whatsapp.net",
          "domain:wa.me",
          "domain:web.whatsapp.com",
          "domain:whatsapp.com",
          "domain:whatsapp.net",
          "domain:chatgpt.com",
          "domain:openai.com",
          "domain:auth.split.io",
          "domain:bestchange.com",
          "domain:cdn.phncdn.com",
          "domain:cdn.phprcdn.com",
          "domain:cdn.pornhub.com",
          "domain:cdn.pornhubpremium.com",
          "domain:content.pornhub.com",
          "domain:discord-activities.com",
          "domain:discordactivities.com",
          "domain:discordmerch.com",
          "domain:discordpartygames.com",
          "domain:discordsays.com",
          "domain:discordstatus.com",
          "domain:facebook.net",
          "domain:fbcdn.net",
          "domain:gvt1.com",
          "domain:gvt2.com",
          "domain:gvt3.com",
          "domain:habr.com",
          "domain:ingamejob.com",
          "domain:linkedin.com",
          "domain:metadsp.com",
          "domain:metamarketers.com",
          "domain:mytbc.ge",
          "domain:nanobanana.io",
          "domain:nperf.com",
          "domain:ntc.party",
          "domain:phcdn.com",
          "domain:phncdn.com",
          "domain:phprcdn.com",
          "domain:phprcdn.net",
          "domain:pornhub.com",
          "domain:pornhubpremium.com",
          "domain:rbxcdn.com",
          "domain:roblox.com",
          "domain:rutracker.net",
          "domain:sdk.split.io",
          "domain:sentry.io",
          "domain:speedtest.net",
          "domain:streamable.com",
          "domain:tbcbank.ge",
          "domain:tbconline.ge",
          "domain:twimg.com",
          "domain:twitter.com",
          "domain:x.com",
          "domain:youtube-nocookie.com",
          "domain:youtubekids.com",
          "domain:youtubemusic.com",
          "domain:yt.be",
          "domain:cdn-telegram.org",
          "domain:t.me",
          "domain:telegra.ph",
          "domain:telegram.me",
          "domain:telegram.org",
          "domain:muscdn.com",
          "domain:tiktok.com",
          "domain:tiktokv.com"
        ],
        "outboundTag": "proxy"
      },
      {
        "type": "field",
        "ip": [
          "104.26.8.2",
          "104.26.9.2",
          "172.67.71.70"
        ],
        "outboundTag": "proxy"
      },
      {
        "type": "field",
        "domain": [
          "full:stun.l.google.com",
          "full:stun1.l.google.com",
          "full:stun2.l.google.com",
          "full:stun3.l.google.com",
          "full:stun4.l.google.com"
        ],
        "outboundTag": "proxy"
      },
      {
        "type": "field",
        "network": "udp",
        "port": "19302-19309",
        "outboundTag": "proxy"
      },
      {
        "type": "field",
        "network": "udp",
        "port": "3478-3481",
        "outboundTag": "proxy"
      },
      {
        "type": "field",
        "ip": [
          "91.108.4.0/22",
          "91.108.8.0/22",
          "91.108.12.0/22",
          "91.108.16.0/22",
          "91.108.20.0/22",
          "91.108.56.0/22",
          "91.105.192.0/23",
          "149.154.160.0/20",
          "185.76.151.0/24"
        ],
        "outboundTag": "proxy"
      },
      {
        "type": "field",
        "ip": [
          "162.159.128.0/24",
          "162.159.129.0/24",
          "162.159.130.0/24",
          "162.159.131.0/24",
          "162.159.132.0/24",
          "162.159.133.0/24",
          "162.159.134.0/24",
          "162.159.135.0/24",
          "162.159.136.0/24",
          "162.159.137.0/24",
          "162.159.138.0/24",
          "162.159.139.0/24",
          "104.160.0.0/13",
          "35.190.0.0/17",
          "34.64.0.0/10",
          "34.128.0.0/10",
          "66.22.192.0/18"
        ],
        "outboundTag": "proxy"
      },
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "direct"
      }
    ]
  }
EOF
}

write_xray_config_xhttp() {
  server_host="$1"
  server_port="$2"
  uuid="$3"
  public_key="$4"
  short_id="$5"
  sni="$6"
  xhttp_path="$7"
  xhttp_mode="$8"
  wan_if="$9"

  {
    cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "dns": {
    "queryStrategy": "UseIPv4",
    "servers": [
      "1.1.1.1",
      "8.8.8.8",
      "localhost"
    ]
  },
  "inbounds": [
    {
      "tag": "tproxy-in",
      "listen": "0.0.0.0",
      "port": 12345,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      },
      "streamSettings": {
        "sockopt": {
          "tproxy": "tproxy"
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "streamSettings": {
        "sockopt": {
          "interface": "$(json_escape "$wan_if")"
        }
      }
    },
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "$(json_escape "$server_host")",
            "port": $server_port,
            "users": [
              {
                "id": "$(json_escape "$uuid")",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "serverName": "$(json_escape "$sni")",
          "fingerprint": "chrome",
          "publicKey": "$(json_escape "$public_key")",
          "shortId": "$(json_escape "$short_id")",
          "spiderX": "/"
        },
        "xhttpSettings": {
          "path": "$(json_escape "$xhttp_path")",
          "mode": "$(json_escape "$xhttp_mode")",
          "host": "$(json_escape "$sni")"
        },
        "sockopt": {
          "interface": "$(json_escape "$wan_if")"
        }
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
EOF
    write_common_routing_block | sed "s/__SERVER_HOST__/$(json_escape "$server_host")/g"
    echo "}"
  } > "$XRAY_CFG_FILE"
}

write_xray_config_tcp() {
  server_host="$1"
  server_port="$2"
  uuid="$3"
  public_key="$4"
  short_id="$5"
  sni="$6"
  flow="$7"
  wan_if="$8"

  {
    cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "dns": {
    "queryStrategy": "UseIPv4",
    "servers": [
      "1.1.1.1",
      "8.8.8.8",
      "localhost"
    ]
  },
  "inbounds": [
    {
      "tag": "tproxy-in",
      "listen": "0.0.0.0",
      "port": 12345,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      },
      "streamSettings": {
        "sockopt": {
          "tproxy": "tproxy"
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "streamSettings": {
        "sockopt": {
          "interface": "$(json_escape "$wan_if")"
        }
      }
    },
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "$(json_escape "$server_host")",
            "port": $server_port,
            "users": [
              {
                "id": "$(json_escape "$uuid")",
                "encryption": "none",
                "flow": "$(json_escape "$flow")"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "$(json_escape "$sni")",
          "fingerprint": "chrome",
          "publicKey": "$(json_escape "$public_key")",
          "shortId": "$(json_escape "$short_id")",
          "spiderX": "/"
        },
        "sockopt": {
          "interface": "$(json_escape "$wan_if")"
        }
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
EOF
    write_common_routing_block | sed "s/__SERVER_HOST__/$(json_escape "$server_host")/g"
    echo "}"
  } > "$XRAY_CFG_FILE"
}

validate_service_status() {
  svc="$1"
  out="$(/etc/init.d/"$svc" status 2>/dev/null || true)"
  case "$out" in
    *running*) ok "PASS: /etc/init.d/$svc status -> running" ;;
    "") err "FAIL: /etc/init.d/$svc status unavailable" ;;
    *) err "FAIL: /etc/init.d/$svc status -> $out" ;;
  esac
}

validate_enabled_rc() {
  svc="$1"
  if /etc/init.d/"$svc" enabled >/dev/null 2>&1; then
    ok "PASS: $svc enabled"
  else
    err "FAIL: $svc enabled"
  fi
}

validate_exact_match() {
  label="$1"
  expected="$2"
  shift 2
  out="$("$@" 2>/dev/null || true)"
  if [ "$out" = "$expected" ]; then
    ok "PASS: $label"
    echo "$out"
  else
    err "FAIL: $label"
    echo "Expected:"
    echo "$expected"
    echo "Got:"
    echo "$out"
  fi
}

validate_grep_match() {
  label="$1"
  pattern="$2"
  shift 2
  out="$("$@" 2>/dev/null || true)"
  if printf '%s\n' "$out" | grep -F -q -- "$pattern"; then
    ok "PASS: $label"
    printf '%s\n' "$out"
  else
    err "FAIL: $label"
    printf '%s\n' "$out"
  fi
}

validate_grep_all() {
  label="$1"
  shift
  cmd="$1"
  shift

  out="$(sh -c "$cmd" 2>/dev/null || true)"
  missing="0"

  for pat in "$@"; do
    if ! printf '%s\n' "$out" | grep -F -q -- "$pat"; then
      missing="1"
      err "Missing expected fragment for $label: $pat"
    fi
  done

  if [ "$missing" = "0" ]; then
    ok "PASS: $label"
    printf '%s\n' "$out"
  else
    err "FAIL: $label"
    printf '%s\n' "$out"
  fi
}

validate_xray_process_exact() {
  out="$(ps w 2>/dev/null | grep '/usr/bin/xray run -config /etc/xray/config.json' | grep -v 'grep' || true)"
  if [ -n "$out" ]; then
    ok "PASS: xray process exists"
    printf '%s\n' "$out"
  else
    err "FAIL: xray process exists"
  fi
}

run_post_install_validation() {
  echo
  title "=== Post-install validation ==="
  echo "Xray config path: $XRAY_CFG_FILE"
  echo

  validate_service_status xray
  validate_enabled_rc xray-tproxy

  validate_grep_match \
    "ip rule show contains fwmark 0x111 lookup 111" \
    "fwmark 0x111 lookup 111" \
    ip rule show

  validate_exact_match \
    "ip route show table 111" \
    "local default dev lo scope host " \
    sh -c "ip route show table 111"

  validate_grep_all \
    "iptables mangle XRAY chain exists with required rules" \
    "iptables -t mangle -S XRAY" \
    "-N XRAY" \
    "-A XRAY -p tcp -j TPROXY --on-port 12345 --on-ip 0.0.0.0 --tproxy-mark 0x111/0x111" \
    "-A XRAY -p udp -j TPROXY --on-port 12345 --on-ip 0.0.0.0 --tproxy-mark 0x111/0x111"

  validate_grep_all \
    "iptables PREROUTING hooks to XRAY exist" \
    "iptables -t mangle -S PREROUTING" \
    "-A PREROUTING -i br-lan -p tcp -j XRAY" \
    "-A PREROUTING -i br-lan -p udp -j XRAY"

  validate_grep_all \
    "xray listens on port 12345" \
    "netstat -lnptu | grep 12345" \
    "tcp" \
    "udp" \
    "12345"

  validate_xray_process_exact

  echo
  title "=== Manual traffic tests after validation ==="
  echo "  - chatgpt.com"
  echo "  - youtube.com"
  echo "  - Discord"
  echo "  - Telegram"
  echo
}

preflight() {
  [ "$(id -u)" = "0" ] || die "Run as root."
  need_cmd opkg
  need_cmd ubus
  need_cmd jsonfilter
  need_cmd resolveip
  need_cmd ip
  need_cmd iptables
  need_cmd sed
  need_cmd awk
}

detect_interfaces() {
  DETECTED_WAN_IF="$(ubus call network.interface.wan status | jsonfilter -e '@.l3_device' 2>/dev/null || true)"
  DETECTED_LAN_IF="$(ubus call network.interface.lan status | jsonfilter -e '@.device' 2>/dev/null || true)"
  [ -n "${DETECTED_LAN_IF:-}" ] || DETECTED_LAN_IF="br-lan"
}

collect_inputs() {
  detect_interfaces

  echo
  title "=== Connection parameters ==="
  note "Use your own server values. Defaults below are generic examples only."
  echo

  SERVER_HOST="$(ask_required "Server address / domain")"
  SERVER_PORT="$(ask_required "Server port" "443")"
  UUID="$(ask_required "UUID")"
  PUBLIC_KEY="$(ask_required "Reality public key")"
  SHORT_ID="$(ask_required "Reality short ID")"
  SNI="$(ask_required "SNI / serverName" "google.com")"

  TRANSPORT="$(ask_required "Protocol (xhttp or tcp)" "xhttp")"
  validate_transport "$TRANSPORT" || die "Unsupported protocol: $TRANSPORT"

  XHTTP_PATH=""
  XHTTP_MODE=""
  TCP_FLOW=""

  if [ "$TRANSPORT" = "xhttp" ]; then
    XHTTP_PATH="$(ask_required "XHTTP path" "/")"
    XHTTP_MODE="$(ask_required "XHTTP mode" "stream-one")"
  else
    TCP_FLOW="$(ask_required "TCP flow" "xtls-rprx-vision")"
  fi

  echo
  note "Detected WAN interface: ${DETECTED_WAN_IF:-unknown}"
  note "Detected LAN interface: ${DETECTED_LAN_IF:-unknown}"

  if ask_yes_no "Use detected WAN/LAN interfaces?" "y"; then
    WAN_IF="${DETECTED_WAN_IF:-eth1}"
    LAN_IF="${DETECTED_LAN_IF:-br-lan}"
  else
    WAN_IF="$(ask_required "WAN interface" "${DETECTED_WAN_IF:-eth1}")"
    LAN_IF="$(ask_required "LAN interface" "${DETECTED_LAN_IF:-br-lan}")"
  fi
}

install_or_upgrade_stack() {
  preflight

  echo
  step "== Step 1/6: Updating package lists =="
  opkg update

  step "== Step 2/6: Checking dependencies =="
  install_pkg_if_missing ca-bundle
  install_pkg_if_missing ip-full
  install_pkg_if_missing jq
  install_pkg_if_missing nano
  install_pkg_if_missing iptables-mod-tproxy
  install_pkg_if_missing kmod-ipt-tproxy

  echo
  XRAY_IPK_URL="$(ask "Direct xray-core .ipk URL (leave empty to install from repo)" "")"

  if [ -n "$XRAY_IPK_URL" ]; then
    step "== Step 3/6: Installing xray-core from direct URL =="
    cd /tmp
    rm -f /tmp/xray-core-custom.ipk
    if command -v wget >/dev/null 2>&1; then
      wget -O /tmp/xray-core-custom.ipk "$XRAY_IPK_URL"
    elif command -v uclient-fetch >/dev/null 2>&1; then
      uclient-fetch -O /tmp/xray-core-custom.ipk "$XRAY_IPK_URL"
    else
      die "Neither wget nor uclient-fetch is available."
    fi
    opkg install /tmp/xray-core-custom.ipk
  else
    step "== Step 3/6: Ensuring xray-core is installed =="
    install_pkg_if_missing xray-core
  fi

  command -v xray >/dev/null 2>&1 || die "xray binary not found after install"

  collect_inputs

  echo
  step "== Step 4/6: Backing up and generating files =="
  backup_existing_files
  mkdir -p "$XRAY_CFG_DIR"

  if [ "$TRANSPORT" = "xhttp" ]; then
    write_xray_config_xhttp "$SERVER_HOST" "$SERVER_PORT" "$UUID" "$PUBLIC_KEY" "$SHORT_ID" "$SNI" "$XHTTP_PATH" "$XHTTP_MODE" "$WAN_IF"
  else
    write_xray_config_tcp "$SERVER_HOST" "$SERVER_PORT" "$UUID" "$PUBLIC_KEY" "$SHORT_ID" "$SNI" "$TCP_FLOW" "$WAN_IF"
  fi

  write_xray_init
  write_xray_tproxy_init "$LAN_IF" "$SERVER_HOST"
  save_state

  info "Validating generated Xray config..."
  xray run -test -config "$XRAY_CFG_FILE" || die "Generated Xray config is invalid."

  if [ -x /etc/init.d/sing-box ] || opkg list-installed | grep -q '^sing-box '; then
    echo
    if ask_yes_no "Sing-box detected. Disable it?" "y"; then
      /etc/init.d/sing-box disable 2>/dev/null || true
      /etc/init.d/sing-box stop 2>/dev/null || true
    fi

    if opkg list-installed | grep -q '^sing-box '; then
      if ask_yes_no "Remove sing-box package too?" "n"; then
        opkg remove sing-box || true
      fi
    fi
  fi

  echo
  step "== Step 5/6: Enabling services =="
  /etc/init.d/xray enable
  /etc/init.d/xray start
  /etc/init.d/xray-tproxy enable
  /etc/init.d/xray-tproxy start

  sleep 2

  step "== Step 6/6: Running validation =="
  run_post_install_validation

  title "=== Installed stack summary ==="
  echo "  Xray config path: $XRAY_CFG_FILE"
  echo "  Xray init path:   $XRAY_INIT"
  echo "  TProxy init path: $XRAY_TPROXY_INIT"
  echo
  note "After reboot:"
  echo "  Run this script again and choose:"
  echo "  2) Validate installed stack"
  echo
}

validate_installed_stack() {
  preflight

  if ! load_state_if_present; then
    warn "No installer state file found. Validation will still run."
  fi

  if [ -f "$XRAY_CFG_FILE" ]; then
    ok "Found Xray config: $XRAY_CFG_FILE"
    if xray_check "$XRAY_CFG_FILE"; then
      ok "PASS: Xray config validates"
    else
      err "FAIL: Xray config validation failed"
    fi
  else
    err "FAIL: Xray config not found: $XRAY_CFG_FILE"
  fi

  run_post_install_validation
}

print_menu() {
  echo
  title "${APP_NAME} v${VERSION}"
  note "OpenWrt / GL.iNet bootstrap for Xray + TProxy transparent proxy"
  echo
  echo "1) Install / upgrade Xray + TProxy stack"
  echo "2) Validate installed stack"
  echo "3) Exit"
  printf "Choose option (1-3): "
}

main() {
  while :; do
    print_menu
    IFS= read -r choice || true
    case "${choice:-}" in
      1) install_or_upgrade_stack ;;
      2) validate_installed_stack ;;
      3) exit 0 ;;
      *) warn "Unknown option. Please enter 1-3." ;;
    esac
  done
}

main
