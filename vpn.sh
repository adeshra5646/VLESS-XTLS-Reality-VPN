#!/bin/bash

# ═══════════════════════════════════════════════════════
#   VLESS + XTLS-Reality AUTO-SETUP + SECURITY
#   v3.1 — single link, unlimited devices, menu-driven
# ═══════════════════════════════════════════════════════

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

CONFIG="/usr/local/etc/xray/config.json"
INFO_FILE="/root/vpn-info.txt"
XRAY_CMD=$(command -v xray 2>/dev/null || echo "/usr/local/bin/xray")

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

get_server_info() {
  SERVER_IP=$(curl -4 -s --max-time 5 https://api.ipify.org \
           || curl -4 -s --max-time 5 https://ifconfig.me \
           || curl -4 -s --max-time 5 https://icanhazip.com)
  SERVER_IP=$(echo "$SERVER_IP" | tr -d '[:space:]')

  if [ -f "$CONFIG" ]; then
    PORT=$(python3 -c "import json; d=json.load(open('$CONFIG')); print(d['inbounds'][0]['port'])" 2>/dev/null || echo "443")
    PRIVATE_KEY=$(python3 -c "import json; d=json.load(open('$CONFIG')); print(d['inbounds'][0]['streamSettings']['realitySettings']['privateKey'])" 2>/dev/null || echo "")
    SHORT_ID=$(python3 -c "import json; d=json.load(open('$CONFIG')); print(d['inbounds'][0]['streamSettings']['realitySettings']['shortIds'][0])" 2>/dev/null || echo "")
    TARGET=$(python3 -c "import json; d=json.load(open('$CONFIG')); print(d['inbounds'][0]['streamSettings']['realitySettings']['serverNames'][0])" 2>/dev/null || echo "")
    FINGERPRINT=$(python3 -c "import json; d=json.load(open('$CONFIG')); print(d['inbounds'][0]['streamSettings']['realitySettings'].get('fingerprint','chrome'))" 2>/dev/null || echo "chrome")
    PUBLIC_KEY=$($XRAY_CMD x25519 -i "$PRIVATE_KEY" 2>/dev/null | grep -i "Public" | awk '{print $NF}' | tr -d '[:space:]')
    UUID=$(python3 -c "import json; d=json.load(open('$CONFIG')); print(d['inbounds'][0]['settings']['clients'][0]['id'])" 2>/dev/null || echo "")
  fi
}

make_link() {
  local uuid="$1" label="${2:-MyVPN}"
  echo "vless://${uuid}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=${TARGET}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision&headerType=none#${label}"
}

xray_installed() {
  command -v xray &>/dev/null || [ -f "/usr/local/bin/xray" ]
}

# ══════════════════════════════════════════════════════
#   1. INSTALL
# ══════════════════════════════════════════════════════

do_install() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║              Installing VLESS Reality            ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"

  # Redirect all output to log as well
  exec > >(tee /root/setup.log) 2>&1

  # ── Fingerprint ─────────────────────────────────────
  echo ""
  echo -e "${YELLOW}Choose TLS fingerprint:${NC}"
  echo "  1) chrome  (default)"
  echo "  2) firefox"
  echo "  3) safari"
  echo "  4) edge"
  read -rp "$(echo -e "${YELLOW}Your choice [1-4, default 1]: ${NC}")" FP_CHOICE
  case "$FP_CHOICE" in
    2) FINGERPRINT="firefox" ;;
    3) FINGERPRINT="safari"  ;;
    4) FINGERPRINT="edge"    ;;
    *) FINGERPRINT="chrome"  ;;
  esac
  echo -e "${GREEN}▶ Fingerprint : ${FINGERPRINT}${NC}"

  # ── Server IP ───────────────────────────────────────
  SERVER_IP=$(curl -4 -s --max-time 5 https://api.ipify.org \
           || curl -4 -s --max-time 5 https://ifconfig.me \
           || curl -4 -s --max-time 5 https://icanhazip.com)
  SERVER_IP=$(echo "$SERVER_IP" | tr -d '[:space:]')
  [ -z "$SERVER_IP" ] && { echo -e "${RED}Error: cannot determine server IP.${NC}"; return 1; }
  echo -e "${GREEN}▶ Server IP   : ${SERVER_IP}${NC}"

  # ── Port 443 ────────────────────────────────────────
  PORT=443
  if ss -tlnp | grep -q ":${PORT} "; then
    echo -e "${RED}Error: port 443 is already in use. Stop the service and retry.${NC}"
    ss -tlnp | grep ":${PORT} "
    return 1
  fi
  echo -e "${GREEN}▶ VPN port    : ${PORT} (HTTPS/Reality)${NC}"

  # ── Packages ────────────────────────────────────────
  echo -e "${YELLOW}▶ Installing packages...${NC}"
  apt-get update -qq
  apt-get install -y -qq \
    curl unzip openssl netcat-openbsd \
    qrencode ufw fail2ban unattended-upgrades \
    2>/dev/null
  echo -e "${GREEN}▶ Packages installed${NC}"

  # ── UFW ─────────────────────────────────────────────
  SSH_PORT=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | awk -F':' '{print $NF}' | head -n1)
  SSH_PORT=${SSH_PORT:-22}
  echo -e "${GREEN}▶ SSH port    : ${SSH_PORT}${NC}"

  [ -f /etc/default/ufw ] && sed -i 's/^IPV6=no/IPV6=yes/' /etc/default/ufw

  ufw --force reset >/dev/null 2>&1
  ufw default deny incoming  >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow "${SSH_PORT}/tcp" comment 'SSH'
  ufw allow 443/tcp           comment 'VLESS-Reality'
  ufw --force enable >/dev/null
  echo -e "${GREEN}▶ UFW active (SSH:${SSH_PORT}, VPN:443)${NC}"

  # ── Fail2Ban ────────────────────────────────────────
  cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 3
ignoreip = 127.0.0.1/8

[sshd]
enabled  = true
port     = ${SSH_PORT}
logpath  = %(sshd_log)s
backend  = systemd
maxretry = 3
bantime  = 86400
EOF
  systemctl enable fail2ban --quiet
  systemctl restart fail2ban
  echo -e "${GREEN}▶ Fail2Ban active (ban after 3 attempts, 24h)${NC}"

  # ── Auto-updates ────────────────────────────────────
  cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  echo -e "${GREEN}▶ Auto security updates enabled${NC}"

  # ── Kernel hardening + BBR ──────────────────────────
  sed -i '/# --- vless-setup-start ---/,/# --- vless-setup-end ---/d' /etc/sysctl.conf
  cat >> /etc/sysctl.conf << 'EOF'

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
  sysctl -p >/dev/null 2>&1
  echo -e "${GREEN}▶ Kernel hardening + BBR enabled${NC}"

  # ── Install Xray ────────────────────────────────────
  echo -e "${YELLOW}▶ Installing Xray...${NC}"
  bash <(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh) 1>/dev/null
  XRAY_CMD=$(command -v xray || echo "/usr/local/bin/xray")
  echo -e "${GREEN}▶ Xray installed${NC}"

  # ── Generate keys ───────────────────────────────────
  echo -e "${YELLOW}▶ Generating keys...${NC}"
  KEYS=$($XRAY_CMD x25519)
  PRIVATE_KEY=$(echo "$KEYS" | grep -i "Private" | awk '{print $NF}' | tr -d '[:space:]')
  PUBLIC_KEY=$(echo "$KEYS"  | grep -i "Public"  | awk '{print $NF}' | tr -d '[:space:]')
  UUID=$($XRAY_CMD uuid | tr -d '[:space:]')
  SHORT_ID=$(openssl rand -hex 8 | tr -d '[:space:]')

  [ -z "$PRIVATE_KEY" ] || [ -z "$UUID" ] && { echo -e "${RED}Error: key generation failed.${NC}"; return 1; }

  # ── SNI target ──────────────────────────────────────
  TARGETS=("www.microsoft.com" "www.samsung.com" "www.asus.com" "dl.google.com")
  TARGET=""
  echo -e "${YELLOW}▶ Checking SNI targets...${NC}"
  for t in "${TARGETS[@]}"; do
    if nc -z -w3 "$t" 443 2>/dev/null; then
      TARGET="$t"
      echo -e "${GREEN}▶ SNI target  : ${TARGET} (reachable)${NC}"
      break
    fi
  done
  [ -z "$TARGET" ] && { TARGET="www.microsoft.com"; echo -e "${YELLOW}⚠  Defaulting to ${TARGET}${NC}"; }

  # ── Xray config ─────────────────────────────────────
  # No limitIp field = unlimited simultaneous connections on one link
  cat > "$CONFIG" << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
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
          "serverNames": ["${TARGET}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"],
          "fingerprint": "${FINGERPRINT}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF

  # ── Systemd watchdog ────────────────────────────────
  XRAY_SERVICE="/etc/systemd/system/xray.service"
  if [ -f "$XRAY_SERVICE" ] && ! grep -q "Restart=always" "$XRAY_SERVICE"; then
    sed -i '/\[Service\]/a Restart=always\nRestartSec=5' "$XRAY_SERVICE"
    systemctl daemon-reload
  fi
  echo -e "${GREEN}▶ Watchdog configured (auto-restart on crash)${NC}"

  # ── Start Xray ──────────────────────────────────────
  systemctl enable xray --quiet
  systemctl restart xray
  sleep 2

  if ! systemctl is-active --quiet xray; then
    echo -e "${RED}Error: Xray failed to start.${NC}"
    journalctl -u xray -n 20 --no-pager
    return 1
  fi
  echo -e "${GREEN}▶ Xray started${NC}"

  # ── Build link ──────────────────────────────────────
  VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=${TARGET}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision&headerType=none#MyVPN"

  # ── Save info ───────────────────────────────────────
  cat > "$INFO_FILE" << EOF
════════════════════════════════════════════════════
  VLESS + XTLS-Reality — connection details v3.1
════════════════════════════════════════════════════

Server IP    : ${SERVER_IP}
VPN Port     : ${PORT}
SSH Port     : ${SSH_PORT}
UUID         : ${UUID}
Public Key   : ${PUBLIC_KEY}
Short ID     : ${SHORT_ID}
SNI Target   : ${TARGET}
Fingerprint  : ${FINGERPRINT}
Flow         : xtls-rprx-vision
Connections  : unlimited (no limitIp)

IMPORT LINK:
${VLESS_LINK}

════════════════════════════════════════════════════
  Generated : $(date '+%Y-%m-%d %H:%M:%S %Z')
  Manage    : bash $(realpath "$0")
════════════════════════════════════════════════════
EOF

  # ── Final output ────────────────────────────────────
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
  echo -e "${CYAN}📋 Log     : ${BOLD}/root/setup.log${NC}"
  echo -e "${CYAN}📱 App     : ${BOLD}https://hiddify.com${NC}"
  echo ""
  echo -e "${GREEN}Security:${NC}"
  echo "   ✅ UFW         — SSH (${SSH_PORT}) + VPN (443) only"
  echo "   ✅ Fail2Ban    — ban after 3 failed SSH attempts (24h)"
  echo "   ✅ BBR         — congestion control enabled"
  echo "   ✅ Auto-updates — security patches automatic"
  echo "   ✅ Watchdog    — Xray restarts on crash"
  echo "   ✅ Flow        — xtls-rprx-vision"
  echo "   ✅ Unlimited   — no connection limit per link"
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
  sleep 1
  if systemctl is-active --quiet xray; then
    echo -e "${GREEN}▶ Xray started successfully.${NC}"
    if [ -f "$CONFIG" ]; then
      get_server_info
      echo ""
      echo -e "${CYAN}Your connection link:${NC}"
      echo -e "${BOLD}${GREEN}$(make_link "$UUID" "MyVPN")${NC}"
    fi
  else
    echo -e "${RED}Error: Xray failed to start.${NC}"
    journalctl -u xray -n 20 --no-pager
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
  sleep 1
  if systemctl is-active --quiet xray; then
    echo -e "${GREEN}▶ Xray restarted successfully.${NC}"
  else
    echo -e "${RED}Error: Xray failed to restart.${NC}"
    journalctl -u xray -n 20 --no-pager
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

  systemctl stop xray    2>/dev/null || true
  systemctl disable xray 2>/dev/null || true
  bash <(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh) --remove 1>/dev/null 2>&1 || true
  rm -f "$CONFIG" "$INFO_FILE"
  echo -e "${GREEN}▶ Xray removed.${NC}"

  ufw --force reset   >/dev/null 2>&1 || true
  ufw --force disable >/dev/null 2>&1 || true
  echo -e "${GREEN}▶ UFW rules cleared.${NC}"

  sed -i '/# --- vless-setup-start ---/,/# --- vless-setup-end ---/d' /etc/sysctl.conf
  sysctl -p >/dev/null 2>&1
  echo -e "${GREEN}▶ Sysctl entries removed.${NC}"

  rm -f /etc/fail2ban/jail.local
  systemctl restart fail2ban 2>/dev/null || true
  echo -e "${GREEN}▶ Fail2Ban config cleared.${NC}"

  echo ""
  echo -e "${GREEN}✅ Uninstall complete. Server is clean.${NC}"
}

# ══════════════════════════════════════════════════════
#   MAIN MENU LOOP
# ══════════════════════════════════════════════════════

while true; do
  echo ""
  echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║     VLESS + Reality — Management Menu      ║${NC}"
  echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"

  # Live status indicator
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
    1) do_install   ;;
    2) do_start     ;;
    3) do_restart   ;;
    4) do_uninstall ;;
    0) echo "Bye."; exit 0 ;;
    *) echo -e "${RED}Unknown option.${NC}" ;;
  esac
done
