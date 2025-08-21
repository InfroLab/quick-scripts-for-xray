#!/bin/bash
# ==============================================================================
#  initial_network_setup
#  Safe SSH + UFW + Fail2Ban + BBR setup with Full Restore
#  - Default mode: RESTORE (safer)
#  - Supports dry-run (prints actions, changes nothing)
#  - Backs up configs into /var/backups/initial_network_setup/
#  - Tracks what this script changed in /var/lib/initial_network_setup/state.json
#  - Full restore puts back original files and UFW rules/state
#
#  Install:
#    sudo cp initial_network_setup /usr/local/bin/initial_network_setup
#    sudo chmod +x /usr/local/bin/initial_network_setup
#
#  Run:
#    sudo initial_network_setup
#
#  Tested on Ubuntu 22.04 / 24.04 (systemd, ufw, openssh-server).
# ==============================================================================

set -euo pipefail

# --------------------------- Constants & Paths --------------------------------
SCRIPT_NAME="initial_network_setup"
INSTALL_PATH="/usr/local/bin/$SCRIPT_NAME"

BACKUP_DIR="/var/backups/$SCRIPT_NAME"
MARKER_DIR="/var/lib/$SCRIPT_NAME"
MARKER_FILE="$MARKER_DIR/state.json"

SSHD_CONFIG="/etc/ssh/sshd_config"
SYSCTL_CONF="/etc/sysctl.conf"
UFW_USER_RULES="/etc/ufw/user.rules"
UFW_USER6_RULES="/etc/ufw/user6.rules"

TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"

# ------------------------------- UI Helpers -----------------------------------
banner() {
  cat <<'EOF'
  ___       _ _   _       _     _   _      _                      _        ____       _               
 |_ _|_ __ (_) |_(_) __ _| |   | \ | | ___| |___      _____  _ __| | __   / ___|  ___| |_ _   _ _ __  
  | || '_ \| | __| |/ _` | |   |  \| |/ _ \ __\ \ /\ / / _ \| '__| |/ /   \___ \ / _ \ __| | | | '_ \ 
  | || | | | | |_| | (_| | |   | |\  |  __/ |_ \ V  V / (_) | |  |   <     ___) |  __/ |_| |_| | |_) |
 |___|_| |_|_|\__|_|\__,_|_|___|_| \_|\___|\__| \_/\_/ \___/|_|  |_|\_\___|____/ \___|\__|\__,_| .__/ 
                          |_____|                                    |_____|                   |_|                                                          
EOF
}

hr() { echo "--------------------------------------------------------------------------------"; }

note() { echo -e "\n=== $* ===\n"; }

ask() {
  local prompt="$1"; local default="${2:-}"; local reply
  if [ -n "$default" ]; then
    prompt="$prompt [$default]"
  fi
  read -rp "$prompt: " reply
  if [ -z "$reply" ] && [ -n "$default" ]; then
    reply="$default"
  fi
  echo "$reply"
}

# DRY-RUN aware executor
run_cmd() {
  if [[ "${DRYRUN:-no}" == "yes" ]]; then
    echo "[DRY-RUN] $*"
  else
    eval "$@"
  fi
}

# ------------------------------ Sanity Checks ---------------------------------
require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "❌ This script must be run as root (use sudo)."
    exit 1
  fi
}

# --------------------------- State/Backup Helpers ------------------------------
ensure_dirs() {
  run_cmd "mkdir -p '$BACKUP_DIR' '$MARKER_DIR'"
}

# jq may not be installed on minimal systems; install unless dry-run
ensure_jq() {
  if command -v jq >/dev/null 2>&1; then
    return
  fi
  if [[ "${DRYRUN:-no}" == "yes" ]]; then
    echo "[DRY-RUN] Would install jq (required to manage $MARKER_FILE)"
    return
  fi
  echo "Installing jq (for state management)..."
  apt-get update -y
  apt-get install -y jq
}

state_get() {
  local key="$1"
  if [[ ! -f "$MARKER_FILE" ]]; then
    echo "unknown"; return
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "unknown"; return
  fi
  jq -r --arg k "$key" '.[$k] // "unknown"' "$MARKER_FILE"
}

state_set() {
  local key="$1"; local val="$2"
  ensure_jq
  if [[ "${DRYRUN:-no}" == "yes" ]]; then
    echo "[DRY-RUN] state_set $key=$val -> $MARKER_FILE"
    return
  fi
  [[ -f "$MARKER_FILE" ]] || echo "{}" > "$MARKER_FILE"
  local tmp; tmp="$(mktemp)"
  jq --arg k "$key" --arg v "$val" '.[$k]=$v' "$MARKER_FILE" > "$tmp"
  mv "$tmp" "$MARKER_FILE"
}

# ------------------------------- UFW Helpers ----------------------------------
ufw_is_active() {
  ufw status 2>/dev/null | grep -qi "active"
}

backup_ufw_state() {
  # record whether UFW was installed and active before changes
  local installed_before="false"
  if command -v ufw >/dev/null 2>&1; then
    installed_before="true"
  fi
  state_set "ufw_installed_before" "$installed_before"

  local was_active="false"
  if command -v ufw >/dev/null 2>&1 && ufw_is_active; then
    was_active="true"
  fi
  state_set "ufw_was_active" "$was_active"

  # Back up rules files if they exist
  if [[ -f "$UFW_USER_RULES" ]]; then
    run_cmd "cp '$UFW_USER_RULES' '$BACKUP_DIR/user.rules.bak.$TIMESTAMP'"
    state_set "ufw_user_rules_backup" "$BACKUP_DIR/user.rules.bak.$TIMESTAMP"
  else
    state_set "ufw_user_rules_backup" "none"
  fi

  if [[ -f "$UFW_USER6_RULES" ]]; then
    run_cmd "cp '$UFW_USER6_RULES' '$BACKUP_DIR/user6.rules.bak.$TIMESTAMP'"
    state_set "ufw_user6_rules_backup" "$BACKUP_DIR/user6.rules.bak.$TIMESTAMP"
  else
    state_set "ufw_user6_rules_backup" "none"
  fi
}

restore_ufw_state_full() {
  local was_active; was_active="$(state_get ufw_was_active)"
  local rules_bak; rules_bak="$(state_get ufw_user_rules_backup)"
  local rules6_bak; rules6_bak="$(state_get ufw_user6_rules_backup)"

  if ! command -v ufw >/dev/null 2>&1; then
    echo "UFW not installed, skipping UFW restore."
    return
  fi

  # Disable first to safely replace rule files
  if ufw_is_active; then
    run_cmd "ufw disable"
  fi

  # If we have backed-up rules, put them back
  if [[ "$rules_bak" != "unknown" && "$rules_bak" != "none" && -f "$rules_bak" ]]; then
    run_cmd "cp '$rules_bak' '$UFW_USER_RULES'"
  fi
  if [[ "$rules6_bak" != "unknown" && "$rules6_bak" != "none" && -f "$rules6_bak" ]]; then
    run_cmd "cp '$rules6_bak' '$UFW_USER6_RULES'"
  fi

  # Re-enable only if UFW was active originally; otherwise keep disabled
  if [[ "$was_active" == "true" ]]; then
    run_cmd "ufw --force enable"
    note "UFW restored and re-enabled to its previous state."
  else
    note "UFW restored and left disabled (it was disabled originally)."
  fi
}

# ---------------------------- SSH Config Helpers ------------------------------
backup_sshd() {
  if [[ -f "$SSHD_CONFIG" ]]; then
    run_cmd "cp '$SSHD_CONFIG' '$BACKUP_DIR/sshd_config.bak.$TIMESTAMP'"
    state_set "sshd_backup" "$BACKUP_DIR/sshd_config.bak.$TIMESTAMP"
  fi
}

restore_sshd_latest() {
  local latest
  latest="$(ls -t "$BACKUP_DIR"/sshd_config.bak.* 2>/dev/null | head -n1 || true)"
  if [[ -n "$latest" ]]; then
    run_cmd "cp '$latest' '$SSHD_CONFIG'"
    note "Restored sshd_config from $latest"
  else
    note "No sshd_config backup found; skipping."
  fi
}

# ---------------------------- sysctl/BBR Helpers ------------------------------
backup_sysctl() {
  if [[ -f "$SYSCTL_CONF" ]]; then
    run_cmd "cp '$SYSCTL_CONF' '$BACKUP_DIR/sysctl.conf.bak.$TIMESTAMP'"
    state_set "sysctl_backup" "$BACKUP_DIR/sysctl.conf.bak.$TIMESTAMP"
  fi
}

restore_sysctl_latest_or_strip_bbr() {
  local latest
  latest="$(ls -t "$BACKUP_DIR"/sysctl.conf.bak.* 2>/dev/null | head -n1 || true)"
  if [[ -n "$latest" ]]; then
    run_cmd "cp '$latest' '$SYSCTL_CONF'"
    run_cmd "sysctl -p || true"
    note "sysctl.conf restored from $latest"
  else
    # fallback: just remove our added lines if present
    run_cmd "sed -i '/^net.core.default_qdisc=fq$/d' '$SYSCTL_CONF' || true"
    run_cmd "sed -i '/^net.ipv4.tcp_congestion_control=bbr$/d' '$SYSCTL_CONF' || true"
    run_cmd "sysctl -p || true"
    note "Removed BBR lines from sysctl.conf (no backup found)."
  fi
}

# ------------------------------- Self-Install ---------------------------------
offer_self_install() {
  if [[ "$0" != "$INSTALL_PATH" && ! -f "$INSTALL_PATH" ]]; then
    local ans
    ans="$(ask "Install this script to $INSTALL_PATH so it can be run anywhere? (yes/no)" "yes")"
    if [[ "$ans" == "yes" ]]; then
      run_cmd "cp '$0' '$INSTALL_PATH'"
      run_cmd "chmod +x '$INSTALL_PATH'"
      note "Installed to $INSTALL_PATH"
    fi
  fi
}

# ==============================================================================
#                                     MAIN
# ==============================================================================
require_root
banner
hr
echo " Script location : $INSTALL_PATH"
echo " Backups stored  : $BACKUP_DIR"
echo " Marker file     : $MARKER_FILE"
hr
echo " 1) Install  — setup SSH port, BBR, Fail2Ban, and (optionally) UFW"
echo " 2) Restore  — FULL RESTORE of original configs and UFW state  [default]"
hr

MODE="$(ask 'Choose mode' '2')"
ensure_dirs
offer_self_install

# ------------------------------- RESTORE MODE ---------------------------------
if [[ "$MODE" == "2" ]]; then
  note "RESTORE mode selected (full restore)."

  # Dry-run question even for restore
  DRYRUN="$(ask 'Run in dry-run mode (only print actions, no changes)? (yes/no)' 'no')"

  # Restore sshd_config
  restore_sshd_latest

  # Restore sysctl (BBR off if it wasn’t originally)
  restore_sysctl_latest_or_strip_bbr

  # Fail2Ban: remove only if our script installed it
  if [[ "$(state_get fail2ban_installed_by_script)" == "true" ]]; then
    run_cmd "systemctl stop fail2ban || true"
    run_cmd "systemctl disable fail2ban || true"
    run_cmd "apt-get remove -y fail2ban || true"
    note "Fail2Ban removed (it was installed by this script)."
  else
    note "Skipping Fail2Ban removal (not installed by this script)."
  fi

  # UFW: fully restore previous rules/state
  restore_ufw_state_full

  # Restart SSH as a final step
  run_cmd "systemctl restart ssh || true"
  note "Restore complete."

  # Optional: mark restore timestamp (keep state for auditing)
  state_set "restored_at_utc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  exit 0
fi

# ------------------------------- INSTALL MODE ---------------------------------
note "INSTALL mode selected."

# Ask for dry-run up front
DRYRUN="$(ask 'Run in dry-run mode (only print actions, no changes)? (yes/no)' 'no')"

# 1) New SSH port (must include in firewall list too)
while true; do
  NEW_SSH_PORT="$(ask 'Enter new SSH port (required, cannot be 22; 1025-65534)' '')"
  if [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] && [ "$NEW_SSH_PORT" -gt 1024 ] && [ "$NEW_SSH_PORT" -lt 65535 ] && [ "$NEW_SSH_PORT" -ne 22 ]; then
    break
  fi
  echo "Invalid port. Use an integer 1025-65534, not 22."
done
state_set "new_ssh_port" "$NEW_SSH_PORT"

# Back up SSHD and update port
backup_sshd
if grep -qE '^[[:space:]]*Port[[:space:]]+' "$SSHD_CONFIG"; then
  run_cmd "sed -i 's/^[[:space:]]*Port[[:space:]].*/Port $NEW_SSH_PORT/' '$SSHD_CONFIG'"
else
  run_cmd "printf '\\nPort %s\\n' '$NEW_SSH_PORT' >> '$SSHD_CONFIG'"
fi
note "SSH port set to $NEW_SSH_PORT in $SSHD_CONFIG"

# 2) Firewall ports list (must include new SSH port)
DEFAULT_PORTS="443,8443,8080,80,$NEW_SSH_PORT"
PORT_LIST="$(ask "Enter comma-separated allowed ports (default: $DEFAULT_PORTS)" "$DEFAULT_PORTS")"
if [[ ! ",$PORT_LIST," == *",$NEW_SSH_PORT,"* ]]; then
  echo "❌ The list must include the new SSH port ($NEW_SSH_PORT)."; exit 1
fi
IFS=',' read -r -a PORTS <<< "$PORT_LIST"

# 3) Enable BBR (unless user says no) — with backup
ENABLE_BBR="$(ask 'Enable BBR congestion control? (yes/no)' 'yes')"
if [[ "$ENABLE_BBR" == "yes" ]]; then
  backup_sysctl
  run_cmd "grep -q '^net.core.default_qdisc=fq$' '$SYSCTL_CONF' || echo 'net.core.default_qdisc=fq' >> '$SYSCTL_CONF'"
  run_cmd "grep -q '^net.ipv4.tcp_congestion_control=bbr$' '$SYSCTL_CONF' || echo 'net.ipv4.tcp_congestion_control=bbr' >> '$SYSCTL_CONF'"
  run_cmd "sysctl -p"
  state_set "bbr_enabled_by_script" "true"
  note "BBR enabled."
else
  state_set "bbr_enabled_by_script" "false"
  note "BBR skipped."
fi

# 4) Install & Enable Fail2Ban (unless no)
INSTALL_F2B="$(ask 'Install and enable Fail2Ban? (yes/no)' 'yes')"
if [[ "$INSTALL_F2B" == "yes" ]]; then
  run_cmd "apt-get update -y"
  run_cmd "apt-get install -y fail2ban"
  run_cmd "systemctl enable fail2ban"
  run_cmd "systemctl start fail2ban"
  state_set "fail2ban_installed_by_script" "true"
  note "Fail2Ban installed and started."
else
  state_set "fail2ban_installed_by_script" "false"
  note "Fail2Ban skipped."
fi

# 5) Restart SSH now? (safe prompt)
RESTART_SSH="$(ask 'Restart SSH server now? (yes/no)' 'yes')"
if [[ "$RESTART_SSH" == "yes" ]]; then
  note "Restarting SSH..."
  run_cmd "systemctl restart ssh"
else
  note "Skipping SSH restart (remember to restart later to apply port change)."
fi

# 6) UFW activation, with full backup of prior state/rules
ENABLE_UFW="$(ask 'Activate UFW now? (yes/no) — default NO (safer)' 'no')"
if [[ "$ENABLE_UFW" == "no" ]]; then
  state_set "ufw_action" "skipped"
  note "UFW activation skipped. Exiting install."
  state_set "installed_at_utc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  exit 0
fi

# Before enabling UFW, ensure user updated SSH client to new port
echo
echo "⚠️  IMPORTANT: Update your SSH client to use port $NEW_SSH_PORT BEFORE continuing."
CONFIRM="$(ask "Type 'yes' to continue with UFW activation" 'no')"
if [[ "$CONFIRM" != "yes" ]]; then
  echo "Aborting to prevent lockout."; exit 1
fi

# Backup UFW state and rules *before* we touch it
backup_ufw_state

# Ensure UFW package exists
if ! command -v ufw >/dev/null 2>&1; then
  run_cmd "apt-get install -y ufw"
fi

# Baseline policy + open selected ports (both TCP/UDP)
run_cmd "ufw default deny incoming"
run_cmd "ufw default allow outgoing"
for p in "${PORTS[@]}"; do
  run_cmd "ufw allow ${p}/tcp"
  run_cmd "ufw allow ${p}/udp"
done
run_cmd "ufw --force enable"
state_set "ufw_action" "enabled"
note "UFW enabled. Allowed ports: $PORT_LIST"

# Final bookkeeping
state_set "installed_at_utc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
note "Install complete."
