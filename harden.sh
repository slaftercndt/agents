#!/usr/bin/env bash
# =============================================================================
# harden.sh — baseline hardening for the Ubuntu VPS.
#
# RUN THIS FIRST, before any credential or .env touches the box. It:
#   1. Configures UFW: allow ONLY SSH (22) + HTTP (80) + HTTPS (443).
#   2. Locks down SSH: key-only auth, no passwords, no root login.
#   3. Installs + enables fail2ban to throttle brute-force SSH.
#
# It is IDEMPOTENT: safe to run repeatedly. Each step checks/overwrites a
# known drop-in rather than appending, so re-runs converge to the same state.
#
# USAGE (as root, or via sudo):
#   sudo ./harden.sh
#
# SAFETY: before disabling password auth we VERIFY an SSH public key is
# already installed for the login user, so you can't lock yourself out. If no
# key is found, the script aborts without changing SSH.
# =============================================================================

set -euo pipefail

# --- Must run as root ---------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
	echo "ERROR: run as root (e.g. sudo ./harden.sh)" >&2
	exit 1
fi

echo "==> Hardening started on $(hostname)"

# -----------------------------------------------------------------------------
# 1. UFW firewall — default deny inbound, allow only the three ports we need.
# -----------------------------------------------------------------------------
echo "==> [1/3] Configuring UFW firewall"

# Install UFW if missing (idempotent: apt is a no-op if already present).
if ! command -v ufw >/dev/null 2>&1; then
	apt-get update -y
	apt-get install -y ufw
fi

# Setting defaults + allowing the same rules repeatedly is idempotent in UFW.
ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp    comment 'SSH'      # keep SSH reachable
ufw allow 80/tcp    comment 'HTTP'     # Caddy: ACME challenge + redirect
ufw allow 443/tcp   comment 'HTTPS'    # Caddy: n8n over TLS

# --force avoids the interactive y/n prompt; enabling when already on is a no-op.
ufw --force enable
echo "    UFW active. Allowed: 22, 80, 443. Everything else denied."

# -----------------------------------------------------------------------------
# 2. SSH hardening — key-only, no passwords, no root login.
#    We write a drop-in in /etc/ssh/sshd_config.d/ instead of editing the main
#    config, so re-runs simply overwrite the drop-in (idempotent + reversible).
# -----------------------------------------------------------------------------
echo "==> [2/3] Hardening SSH"

# Determine the non-root user that owns this session (the one with SSH keys).
# Prefer the sudo-invoking user; fall back to scanning /home for an authorized_keys.
LOGIN_USER="${SUDO_USER:-}"
if [[ -z "${LOGIN_USER}" || "${LOGIN_USER}" == "root" ]]; then
	# Find the first /home/<user> that has authorized_keys.
	for d in /home/*; do
		if [[ -f "${d}/.ssh/authorized_keys" ]]; then
			LOGIN_USER="$(basename "${d}")"
			break
		fi
	done
fi

# SAFETY GUARD: refuse to disable password auth unless a key is actually present
# for the login user (or for root, if you log in as root). Otherwise you'd be
# locked out the moment passwords are disabled.
KEY_FOUND="no"
if [[ -n "${LOGIN_USER}" && -s "/home/${LOGIN_USER}/.ssh/authorized_keys" ]]; then
	KEY_FOUND="yes"
elif [[ -s "/root/.ssh/authorized_keys" ]]; then
	KEY_FOUND="yes"
fi

if [[ "${KEY_FOUND}" != "yes" ]]; then
	echo "ERROR: no SSH public key found in any user's ~/.ssh/authorized_keys." >&2
	echo "       Add your key (ssh-copy-id) BEFORE hardening, or you will be" >&2
	echo "       locked out. Skipping SSH changes." >&2
	exit 1
fi
echo "    SSH key found (user: ${LOGIN_USER:-root}). Safe to disable passwords."

# Write the hardening drop-in. Overwriting is idempotent.
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
# Managed by harden.sh — baseline SSH hardening. Do not edit by hand.
PubkeyAuthentication yes
PasswordAuthentication no
PermitRootLogin no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
EOF

# Validate config before reloading so a typo can't break sshd.
if sshd -t; then
	systemctl reload ssh 2>/dev/null || systemctl reload sshd
	echo "    SSH reloaded: key-only auth, root login disabled."
else
	echo "ERROR: sshd config test failed; not reloading. Review the drop-in." >&2
	exit 1
fi

# -----------------------------------------------------------------------------
# 3. fail2ban — ban IPs that brute-force SSH.
# -----------------------------------------------------------------------------
echo "==> [3/3] Installing + enabling fail2ban"

if ! command -v fail2ban-server >/dev/null 2>&1; then
	apt-get update -y
	apt-get install -y fail2ban
fi

# jail.local overrides ship defaults and survives package upgrades.
# Overwriting it is idempotent.
cat > /etc/fail2ban/jail.local <<'EOF'
# Managed by harden.sh — local fail2ban overrides.
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled = true
port    = ssh
EOF

systemctl enable fail2ban
systemctl restart fail2ban
echo "    fail2ban active (sshd jail: ban after 5 fails in 10m for 1h)."

echo
echo "==> Hardening complete."
echo "    Firewall : 22, 80, 443 only"
echo "    SSH      : key-only, no passwords, no root login"
echo "    fail2ban : sshd jail enabled"
echo "    Open a NEW SSH session to confirm access BEFORE closing this one."
