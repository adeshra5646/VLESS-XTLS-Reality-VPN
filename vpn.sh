#!/bin/bash

# ═══════════════════════════════════════════════════════
#          VLESS + XTLS-Reality AUTO-SETUP
# ═══════════════════════════════════════════════════════

set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

CONFIG="/usr/local/etc/xray/config.json"
INFO_FILE="/root/vpn-info.txt"
LOG_FILE="/root/setup.log"
XRAY_CMD="$(command -v xray 2>/dev/null || echo /usr/local/bin/xray)"
SSH_PORT="22"

# ── Root check ────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root: sudo bash menu.sh${NC}"
  exit 1
fi

# ── OS check ──────────────────────────────────────────
if [ ! -f /etc/debian_version ]; then
  echo -e "${RED}Error: only Debian/Ubuntu are supported.${NC}"
  exit 1
fi

# ══════════════════════════════════════════════════════
#   HELPERS
# ══════════════════════════════════════════════════════

print_header() {
  echo ""
  echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║     VLESS + Reality — Management Menu      ║${NC}"
  echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
}

xray_installed() {
  command -v xray >/dev/null 2>&1 || [ -x "/usr/local/bin/xray" ]
}

get_xray_cmd() {
  XRAY_CMD="$(command -v xray 2>/dev/null || echo /usr/local/bin/xray)"
}

get_public_ip() {
  local ip=""
  ip=$(curl -4 -s --max-time 5 https://api.ipify.org \
    || curl -4 -s --max-time 5 https://ifconfig.me \
    || curl -4 -s --max-time 5 https://icanhazip.com \
    || true)
  echo "$ip" | tr -d '[:space:]'
}

get_server_info() {
  SERVER_IP="$(get_public_ip)"

  if [ -f "$CONFIG" ]; then
    PORT=$(python3 - <<PY 2>/dev/null || echo "443"
import json
with open("$CONFIG", "r") as f:
    d = json.load(f)
print(d["inbounds"][0]["port"])
PY
)

    PRIVATE_KEY=$(python3 - <<PY 2>/dev/null || echo ""
import json
with open("$CONFIG", "r") as f:
    d = json.load(f)
print(d["inbounds"][0]["streamSettings"]["realitySettings"]["privateKey"])
PY
)

    SHORT_ID=$(python3 - <<PY 2>/dev/null || echo ""
import json
with open("$CONFIG", "r") as f:
    d = json.load(f)
print(d["inbounds"][0]["streamSettings"]["realitySettings"]["shortIds"][0])
PY
)

    TARGET=$(python3 - <<PY 2>/dev/null || echo ""
import json
with open("$CONFIG", "r") as f:
    d = json.load(f)
print(d["inbounds"][0]["streamSettings"]["realitySettings"]["serverNames"][0])
PY
)

    UUID=$(python3 - <<PY 2>/dev/null || echo ""
import json
with open("$CONFIG", "r") as f:
    d = json.load(f)
print(d["inbounds"][0]["settings"]["clients"][0]["id"])
PY
)

    get_xray_cmd
    PUBLIC_KEY=$("$XRAY_CMD" x25519 -i "$PRIVATE_KEY" 2>/dev/null | awk '/Public key/ {print $3}' | tr -d '[:space:]')
  fi
}

make_link() {
  local uuid="$1"
  local label="${2:-MyVPN}"
  echo "vless://${uuid}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=${TARGET}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision&headerType=none#${label}"
}

wait_xray() {
  local i
  for i in {1..10}; do
    if systemctl is-active --quiet xray; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# ══════════════════════════════════════════════════════
#   1. INSTALL
# ══════════════════════════════════════════════════════

do_install() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║              Installing VLESS Reality            ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"

  : > "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1

  SERVER_IP="$(get_public_ip)"
  if [ -z "$SERVER_IP" ]; then
    echo -e "${RED}Error: cannot determine server IP.${NC}"
    return 1
  fi
  echo -e "${GREEN}▶ Server IP   : ${SERVER_IP}${NC}"

  PORT="443"
  if ss -ltnp 2>/dev/null | grep -q ":${PORT} "; then
    echo -e "${RED}Error: port 443 is already in use. Stop the service and retry.${NC}"
    ss -ltnp | grep ":${PORT} "
    return 1
  fi
  echo -e "${GREEN}▶ VPN port    : ${PORT}${NC}"
  echo -e "${GREEN}▶ SSH port    : ${SSH_PORT}${NC}"

  echo -e "${YELLOW}▶ Installing packages...${NC}"
  apt-get update -qq
  apt-get install -y -qq \
    curl unzip openssl netcat-openbsd qrencode ufw fail2ban \
    unattended-upgrades ca-certificates python3 lsb-release >/dev/null
  echo -e "${GREEN}▶ Packages installed${NC}"

  echo -e "${YELLOW}▶ Configuring UFW...${NC}"
  [ -f /etc/default/ufw ] && sed -i 's/^IPV6=no/IPV6=yes/' /etc/default/ufw || true
  ufw --force reset >/dev/null 2>&1
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow 22/tcp comment 'SSH'
  ufw allow 443/tcp comment 'VLESS-Reality'
  ufw --force enable >/dev/null
  echo -e "${GREEN}▶ UFW active (SSH:22, VPN:443)${NC}"

  echo -e "${YELLOW}▶ Configuring Fail2Ban...${NC}"
  cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 3
ignoreip = 127.0.0.1/8

[sshd]
enabled  = true
port     = 22
logpath  = %(sshd_log)s
backend  = systemd
maxretry = 3
bantime  = 86400
EOF
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban
  echo -e "${GREEN}▶ Fail2Ban active${NC}"

  echo -e "${YELLOW}▶ Enabling auto security updates...${NC}"
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  echo -e "${GREEN}▶ Auto security updates enabled${NC}"

  echo -e "${YELLOW}▶ Applying kernel tuning...${NC}"
  sed -i '/# --- vless-setup-start ---/,/# --- vless-setup-end ---/d' /etc/sysctl.conf
  cat >> /etc/sysctl.conf <<'EOF'

# --- vless-setup-start ---
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# --- vless-setup-end ---
EOF
  sysctl -p >/dev/null 2>&1 || true
  echo -e "${GREEN}▶ Kernel hardening + BBR enabled${NC}"

  echo -e "${YELLOW}▶ Installing Xray...${NC}"
  bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install >/dev/null
  get_xray_cmd
  if ! xray_installed; then
    echo -e "${RED}Error: Xray install failed.${NC}"
    return 1
  fi
  echo -e "${GREEN}▶ Xray installed${NC}"

  echo -e "${YELLOW}▶ Generating keys...${NC}"
  KEYS=$("$XRAY_CMD" x25519)
  PRIVATE_KEY=$(echo "$KEYS" | awk '/Private key/ {print $3}' | tr -d '[:space:]')
  PUBLIC_KEY=$(echo "$KEYS" | awk '/Public key/ {print $3}' | tr -d '[:space:]')
  UUID=$("$XRAY_CMD" uuid | tr -d '[:space:]')
  SHORT_ID=$(openssl rand -hex 8 | tr -d '[:space:]')

  if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ] || [ -z "$UUID" ] || [ -z "$SHORT_ID" ]; then
    echo -e "${RED}Error: failed to generate Reality credentials.${NC}"
    return 1
  fi

  echo -e "${YELLOW}▶ Selecting SNI target...${NC}"
  TARGETS=(
    "www.microsoft.com"
    "www.cloudflare.com"
    "www.apple.com"
    "www.amazon.com"
  )

  TARGET=""
  for t in "${TARGETS[@]}"; do
    if nc -z -w3 "$t" 443 >/dev/null 2>&1; then
      TARGET="$t"
      break
    fi
  done

  if [ -z "$TARGET" ]; then
    TARGET="www.microsoft.com"
  fi
  echo -e "${GREEN}▶ SNI target  : ${TARGET}${NC}"

  mkdir -p "$(dirname "$CONFIG")"

  echo -e "${YELLOW}▶ Writing Xray config...${NC}"
  cat > "$CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision",
            "comment": "default"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${TARGET}:443",
          "serverNames": [
            "${TARGET}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF

  mkdir -p /etc/systemd/system/xray.service.d
  cat > /etc/systemd/system/xray.service.d/override.conf <<'EOF'
[Service]
Restart=always
RestartSec=5
EOF

  systemctl daemon-reload
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray

  if ! wait_xray; then
    echo -e "${RED}Error: Xray failed to start.${NC}"
    journalctl -u xray -n 50 --no-pager
    return 1
  fi

  if ! ss -ltnp 2>/dev/null | grep -q ":443 "; then
    echo -e "${RED}Error: Xray is running but 443 is not listening.${NC}"
    journalctl -u xray -n 50 --no-pager
    return 1
  fi

  echo -e "${GREEN}▶ Xray started${NC}"

  VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=${TARGET}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision&headerType=none#MyVPN"

  cat > "$INFO_FILE" <<EOF
════════════════════════════════════════════════════
  VLESS + XTLS-Reality — connection details
════════════════════════════════════════════════════

Server IP    : ${SERVER_IP}
VPN Port     : ${PORT}
SSH Port     : 22
UUID         : ${UUID}
Public Key   : ${PUBLIC_KEY}
Short ID     : ${SHORT_ID}
SNI Target   : ${TARGET}
Fingerprint  : chrome
Flow         : xtls-rprx-vision
Connections  : unlimited

IMPORT LINK:
${VLESS_LINK}

════════════════════════════════════════════════════
Generated : $(date '+%Y-%m-%d %H:%M:%S %Z')
Manage    : bash $(realpath "$0")
════════════════════════════════════════════════════
EOF

  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║           ✅ Installation complete!              ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${BOLD}${GREEN}${VLESS_LINK}${NC}"
  echo ""
  echo -e "${YELLOW}══════════ QR CODE ══════════${NC}"
  qrencode -t ANSIUTF8 -m 2 "$VLESS_LINK"
  echo -e "${YELLOW}════════════════════════════${NC}"
  echo ""
  echo -e "${CYAN}📁 Details : ${BOLD}${INFO_FILE}${NC}"
  echo -e "${CYAN}📋 Log     : ${BOLD}${LOG_FILE}${NC}"
  echo ""
  echo -e "${GREEN}Security:${NC}"
  echo "   ✅ UFW          — only SSH 22 and VPN 443"
  echo "   ✅ Fail2Ban     — SSH protection enabled"
  echo "   ✅ BBR          — enabled"
  echo "   ✅ Auto-updates — enabled"
  echo "   ✅ Watchdog     — xray auto-restart enabled"
  echo ""
}

# ══════════════════════════════════════════════════════
#   2. START
# ══════════════════════════════════════════════════════

do_start() {
  if ! xray_installed; then
    echo -e "${RED}Xray is not installed. Run option 1 first.${NC}"
    return 1
  fi

  systemctl start xray

  if wait_xray; then
    echo -e "${GREEN}▶ Xray started successfully.${NC}"
    if [ -f "$CONFIG" ]; then
      get_server_info
      echo ""
      echo -e "${CYAN}Your connection link:${NC}"
      echo -e "${BOLD}${GREEN}$(make_link "$UUID" "MyVPN")${NC}"
    fi
  else
    echo -e "${RED}Error: Xray failed to start.${NC}"
    journalctl -u xray -n 50 --no-pager
  fi
}

# ══════════════════════════════════════════════════════
#   3. RESTART
# ══════════════════════════════════════════════════════

do_restart() {
  if ! xray_installed; then
    echo -e "${RED}Xray is not installed. Run option 1 first.${NC}"
    return 1
  fi

  systemctl restart xray

  if wait_xray; then
    echo -e "${GREEN}▶ Xray restarted successfully.${NC}"
    if [ -f "$CONFIG" ]; then
      get_server_info
      echo -e "${CYAN}Current link:${NC}"
      echo -e "${BOLD}${GREEN}$(make_link "$UUID" "MyVPN")${NC}"
    fi
  else
    echo -e "${RED}Error: Xray failed to restart.${NC}"
    journalctl -u xray -n 50 --no-pager
  fi
}

# ══════════════════════════════════════════════════════
#   4. UNINSTALL
# ══════════════════════════════════════════════════════

do_uninstall() {
  echo ""
  echo -e "${RED}This will completely remove Xray, config, and firewall rules.${NC}"
  read -rp "$(echo -e "${YELLOW}Are you sure? [y/N]: ${NC}")" CONFIRM
  [[ "${CONFIRM,,}" != "y" ]] && { echo "Cancelled."; return; }

  systemctl stop xray 2>/dev/null || true
  systemctl disable xray 2>/dev/null || true
  rm -rf /etc/systemd/system/xray.service.d
  systemctl daemon-reload

  bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh) remove >/dev/null 2>&1 || true

  rm -f "$CONFIG" "$INFO_FILE" "$LOG_FILE"

  ufw --force reset >/dev/null 2>&1 || true
  ufw --force disable >/dev/null 2>&1 || true

  sed -i '/# --- vless-setup-start ---/,/# --- vless-setup-end ---/d' /etc/sysctl.conf
  sysctl -p >/dev/null 2>&1 || true

  rm -f /etc/fail2ban/jail.local
  systemctl restart fail2ban 2>/dev/null || true

  echo ""
  echo -e "${GREEN}✅ Uninstall complete. Server is clean.${NC}"
}

# ══════════════════════════════════════════════════════
#   MAIN MENU LOOP
# ══════════════════════════════════════════════════════

while true; do
  print_header

  if systemctl is-active --quiet xray 2>/dev/null; then
    echo -e "   Status : ${GREEN}● running${NC}"
  elif xray_installed; then
    echo -e "   Status : ${RED}● stopped${NC}"
  else
    echo -e "   Status : ${YELLOW}● not installed${NC}"
  fi

  echo ""
  echo "   1)  Install"
  echo "   2)  Start"
  echo "   3)  Restart"
  echo "   4)  Uninstall"
  echo "   0)  Exit"
  echo ""
  read -rp "$(echo -e "${YELLOW}  Choice: ${NC}")" MENU_CHOICE

  case "$MENU_CHOICE" in
    1) do_install ;;
    2) do_start ;;
    3) do_restart ;;
    4) do_uninstall ;;
    0) echo "Bye."; exit 0 ;;
    *) echo -e "${RED}Unknown option.${NC}" ;;
  esac
done
