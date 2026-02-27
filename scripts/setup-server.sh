#!/usr/bin/env bash
# Repeatable server setup: superuser nic, restricted user black_thorn.
# SSH access only via authorized keys from the repo config file.
#
# Run as root on the server. The initial login user is typically ec2-user
# (default on Amazon Linux EC2); you SSH in as ec2-user, then run this with sudo.
#
# Prereq: copy authorized_keys to the server first, e.g.:
#   scp authorized_keys ec2-user@server:/tmp/authorized_keys
#   ssh ec2-user@server 'sudo AUTHORIZED_KEYS=/tmp/authorized_keys /tmp/setup-server.sh'

set -euo pipefail

AUTHORIZED_KEYS="${AUTHORIZED_KEYS:-/tmp/authorized_keys}"
SSHD_CONFIG="/etc/ssh/sshd_config"
BLACK_THORN_HOME="/home/black_thorn"

# --- Ensure we have authorized_keys content (no comments/empties)
if [[ ! -f "$AUTHORIZED_KEYS" ]]; then
  echo "Missing authorized_keys file at: $AUTHORIZED_KEYS" >&2
  echo "Copy it to the server first, e.g.: scp authorized_keys ec2-user@server:/tmp/authorized_keys" >&2
  exit 1
fi

KEYS_CONTENT=$(grep -v '^#' "$AUTHORIZED_KEYS" | grep -v '^[[:space:]]*$' || true)
if [[ -z "$KEYS_CONTENT" ]]; then
  echo "No SSH public keys found in $AUTHORIZED_KEYS (only comments or empty lines)." >&2
  exit 1
fi

# --- Install htop, ufw, git, cronie, golang, tree (Linux; skip if already present; golang for black_thorn)
if command -v dnf &>/dev/null; then
  for pkg in htop git cronie tree; do command -v "$pkg" &>/dev/null || { dnf install -y "$pkg" 2>/dev/null || yum install -y "$pkg" 2>/dev/null || true; }; done
  command -v go &>/dev/null || { dnf install -y golang 2>/dev/null || yum install -y golang 2>/dev/null || true; }
  command -v ufw &>/dev/null || { dnf install -y ufw 2>/dev/null || yum install -y ufw 2>/dev/null; } || true
elif command -v apt-get &>/dev/null; then
  apt-get update -qq
  for pkg in htop git ufw cron tree; do command -v "$pkg" &>/dev/null || { apt-get install -y "$pkg" || true; }; done
  command -v go &>/dev/null || { apt-get install -y golang-go || true; }
fi
if command -v ufw &>/dev/null; then
  ufw allow 22/tcp 2>/dev/null || true
  ufw status | grep -q "Status: active" || { echo "y" | ufw enable 2>/dev/null || ufw --force enable; echo "ufw enabled (SSH allowed)"; }
fi

# --- Create superuser nic (with sudo)
if ! getent passwd nic &>/dev/null; then
  useradd -m -s /bin/bash -G wheel nic
  echo "Created user: nic (wheel/sudo)"
else
  echo "User nic already exists"
fi
mkdir -p /home/nic/.ssh
chown nic:nic /home/nic/.ssh
chmod 700 /home/nic/.ssh
echo "$KEYS_CONTENT" > /home/nic/.ssh/authorized_keys
chown nic:nic /home/nic/.ssh/authorized_keys
chmod 600 /home/nic/.ssh/authorized_keys
passwd -l nic 2>/dev/null || true
# nic has no password (key-only); allow passwordless sudo so e.g. sudo su - black_thorn works
echo 'nic ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/nic
chmod 440 /etc/sudoers.d/nic

# --- Create restricted user black_thorn (no sudo); normal home
if ! getent passwd black_thorn &>/dev/null; then
  useradd -m -s /bin/bash -d "$BLACK_THORN_HOME" black_thorn
  echo "Created user: black_thorn (no sudo)"
else
  echo "User black_thorn already exists"
fi
passwd -l black_thorn 2>/dev/null || true

# black_thorn SSH: root-owned authorized_keys so they cannot add/change keys
mkdir -p "${BLACK_THORN_HOME}/.ssh"
echo "$KEYS_CONTENT" > "${BLACK_THORN_HOME}/.ssh/authorized_keys"
chown root:black_thorn "${BLACK_THORN_HOME}/.ssh/authorized_keys"
chmod 640 "${BLACK_THORN_HOME}/.ssh/authorized_keys"
chown root:black_thorn "${BLACK_THORN_HOME}/.ssh"
chmod 750 "${BLACK_THORN_HOME}/.ssh"

# --- Cron for nic: sync authorized_keys from GitHub (script in nic's home, not readable by black_thorn)
NIC_KEYS_URL="https://github.com/nicbotes.keys"
NIC_BIN="/home/nic/bin"
SYNC_SCRIPT="$NIC_BIN/sync-authorized-keys.sh"
mkdir -p "$NIC_BIN"
chown nic:nic "$NIC_BIN"
chmod 700 "$NIC_BIN"
cat > "$SYNC_SCRIPT" << 'SYNC_SCRIPT_END'
#!/usr/bin/env bash
# Sync authorized_keys from GitHub for nic and black_thorn. Run as nic (cron).
set -euo pipefail
KEYS_URL="https://github.com/nicbotes.keys"
TMP=$(mktemp)
trap 'rm -f "$TMP" "${TMP}.keys" "${TMP}.merged"' EXIT
curl -fsSL "$KEYS_URL" -o "$TMP" || exit 0
grep -v '^#' "$TMP" | grep -v '^[[:space:]]*$' > "${TMP}.keys" || true
[[ -s "${TMP}.keys" ]] || exit 0

# Merge remote keys with existing ones so we never silently drop a working key.
for user in nic black_thorn; do
  AUTH_FILE="/home/${user}/.ssh/authorized_keys"
  if [[ -f "$AUTH_FILE" ]]; then
    sort -u "$AUTH_FILE" "${TMP}.keys" > "${TMP}.merged"
  else
    cp "${TMP}.keys" "${TMP}.merged"
  fi
  if [[ "$user" == "nic" ]]; then
    cp "${TMP}.merged" "$AUTH_FILE"
    chmod 600 "$AUTH_FILE"
  else
    sudo cp "${TMP}.merged" "$AUTH_FILE"
    sudo chown root:black_thorn "$AUTH_FILE"
    sudo chmod 640 "$AUTH_FILE"
  fi
done
SYNC_SCRIPT_END
chown nic:nic "$SYNC_SCRIPT"
chmod 700 "$SYNC_SCRIPT"
# Cron: every 6 hours (nic only; script and bin dir are 700, black_thorn cannot read)
if command -v crontab &>/dev/null; then
  (crontab -l -u nic 2>/dev/null | grep -v sync-authorized-keys || true; echo "0 */6 * * * $SYNC_SCRIPT") | crontab -u nic -
  echo "Cron installed for nic (sync keys every 6h)."
else
  echo "crontab not found; install cronie/cron and re-run setup to add cron job."
fi

# --- SSH daemon: keys only; only backup and restart if we may have changed something
SSHD_NEEDS_UPDATE=0
if ! grep -q 'Match User black_thorn' "$SSHD_CONFIG"; then SSHD_NEEDS_UPDATE=1; fi
if grep -q '^PasswordAuthentication yes' "$SSHD_CONFIG"; then SSHD_NEEDS_UPDATE=1; fi
if [[ "$SSHD_NEEDS_UPDATE" -eq 1 ]]; then
  BACKUP="${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "$SSHD_CONFIG" "$BACKUP"
  echo "sshd_config backup: $BACKUP"
fi

# Global: SSH key-only, no password/challenge, locked-down
set_sshd_option() {
  local key="$1" value="$2"
  if grep -q '^'"$key"' ' "$SSHD_CONFIG"; then
    sed -i 's/^'"$key"' .*/'"$key"' '"$value"'/' "$SSHD_CONFIG"
  elif grep -q '^#'"$key"' ' "$SSHD_CONFIG"; then
    sed -i 's/^#'"$key"' .*/'"$key"' '"$value"'/' "$SSHD_CONFIG"
  else
    echo "$key $value" >> "$SSHD_CONFIG"
  fi
}
set_sshd_option "PasswordAuthentication" "no"
set_sshd_option "PubkeyAuthentication" "yes"
set_sshd_option "PermitRootLogin" "no"
set_sshd_option "MaxAuthTries" "3"
set_sshd_option "PermitEmptyPasswords" "no"
# Only allow explicit SSH users we expect on this box
set_sshd_option "AllowUsers" "nic black_thorn ec2-user"
# Disable keyboard-interactive and challenge-response (password-like)
for key in KbdInteractiveAuthentication ChallengeResponseAuthentication; do
  if grep -qE '^#?'"$key"' ' "$SSHD_CONFIG"; then
    set_sshd_option "$key" "no"
  fi
done 2>/dev/null || true

# Match block for black_thorn: TCP forwarding yes (for OpenClaw dashboard tunnel)
if ! grep -q 'Match User black_thorn' "$SSHD_CONFIG"; then
  SSHD_NEEDS_UPDATE=1
  [[ -z "$BACKUP" ]] && { BACKUP="${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"; cp -a "$SSHD_CONFIG" "$BACKUP"; echo "sshd_config backup: $BACKUP"; }
  cat >> "$SSHD_CONFIG" << 'SSHD_MATCH'

# Restrict black_thorn: no sudo, cannot change own SSH keys (file is root-owned); AllowTcpForwarding yes for OpenClaw dashboard tunnel
Match User black_thorn
  AllowAgentForwarding no
  AllowTcpForwarding yes
  PermitTTY yes
  X11Forwarding no
SSHD_MATCH
else
  # Block exists; ensure TCP forwarding is allowed so "ssh -L" tunnel to dashboard works
  if grep -A6 'Match User black_thorn' "$SSHD_CONFIG" | grep -q 'AllowTcpForwarding no'; then
    [[ "$SSHD_NEEDS_UPDATE" -eq 0 ]] && { BACKUP="${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"; cp -a "$SSHD_CONFIG" "$BACKUP"; echo "sshd_config backup: $BACKUP"; }
    sed -i 's/^[[:space:]]*AllowTcpForwarding no/  AllowTcpForwarding yes/' "$SSHD_CONFIG"
    SSHD_NEEDS_UPDATE=1
  fi
fi

# Restart SSH only if we had something to update
if [[ "$SSHD_NEEDS_UPDATE" -eq 1 ]]; then
  if systemctl is-active -q sshd 2>/dev/null; then systemctl restart sshd
  elif systemctl is-active -q ssh 2>/dev/null; then systemctl restart ssh
  else service sshd restart 2>/dev/null || service ssh restart 2>/dev/null || true; fi
fi

# Default EC2 user: keep as break-glass account (password locked, no sudo).
# This avoids a total lockout if nic/black_thorn keys are ever misconfigured.
if getent passwd ec2-user &>/dev/null; then
  passwd -l ec2-user 2>/dev/null || true
  # Ensure ec2-user is not a sudoer; nic is the only intended sudo-capable login.
  gpasswd -d ec2-user wheel 2>/dev/null || true
  echo "ec2-user account kept (password locked, no sudo). Once you've verified nic/black_thorn SSH works and you have console access, you can remove it with: sudo userdel -r ec2-user"
fi

# --- Last step: Node 22+ and openclaw for black_thorn (server is already secured); skip if already done
need_node22() {
  if ! command -v node &>/dev/null; then return 0; fi
  local v; v=$(node -v 2>/dev/null | sed 's/^v//; s/\..*//'); [[ -z "$v" ]] || [[ "$v" -lt 22 ]]
}
if need_node22 && command -v curl &>/dev/null; then
  echo "Installing Node.js 22 (openclaw requires v22+)..."
  if command -v dnf &>/dev/null; then
    curl -fsSL https://rpm.nodesource.com/setup_22.x | bash - 2>/dev/null || true
    dnf remove -y nodejs nodejs-npm nodejs-docs nodejs-full-i18n nodejs-libs 2>/dev/null || true
    dnf install -y nodejs 2>/dev/null || true
  elif command -v apt-get &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - 2>/dev/null || true
    apt-get install -y nodejs 2>/dev/null || true
  fi
fi

openclaw_installed() {
  sudo -u black_thorn bash -c 'command -v openclaw &>/dev/null || [[ -x "$HOME/.npm-global/bin/openclaw" ]]' 2>/dev/null
}
if command -v curl &>/dev/null; then
  if openclaw_installed; then
    echo "Openclaw already installed for black_thorn, skipping install."
  else
    echo "Installing openclaw for black_thorn (last step; server is secure)..."
    sudo -u black_thorn bash -c 'curl -fsSL https://openclaw.ai/install.sh | bash' || true
    chown -R black_thorn:black_thorn "$BLACK_THORN_HOME" 2>/dev/null || true
  fi
  # Always re-lock .ssh so black_thorn cannot remove or modify authorized_keys
  if [[ -f "${BLACK_THORN_HOME}/.ssh/authorized_keys" ]]; then
    chown root:black_thorn "${BLACK_THORN_HOME}/.ssh/authorized_keys"
    chmod 640 "${BLACK_THORN_HOME}/.ssh/authorized_keys"
  fi
  chown root:black_thorn "${BLACK_THORN_HOME}/.ssh"
  chmod 750 "${BLACK_THORN_HOME}/.ssh"
  grep -q '.npm-global/bin' "${BLACK_THORN_HOME}/.bashrc" 2>/dev/null || echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> "${BLACK_THORN_HOME}/.bashrc"
  chown black_thorn:black_thorn "${BLACK_THORN_HOME}/.bashrc" 2>/dev/null || true
  # Cron: run openclaw security audit regularly (docs recommend running regularly)
  if openclaw_installed && command -v crontab &>/dev/null; then
    (crontab -l -u black_thorn 2>/dev/null | grep -v "openclaw security audit" || true
     echo '0 3 * * * PATH=$HOME/.npm-global/bin:$PATH openclaw security audit >> $HOME/.openclaw/security-audit.log 2>&1'
     echo '0 4 * * 0 PATH=$HOME/.npm-global/bin:$PATH openclaw security audit --deep >> $HOME/.openclaw/security-audit-deep.log 2>&1') | crontab -u black_thorn -
    mkdir -p "${BLACK_THORN_HOME}/.openclaw"
    chown black_thorn:black_thorn "${BLACK_THORN_HOME}/.openclaw"
    echo "Cron installed for black_thorn: openclaw security audit (daily), audit --deep (weekly)."
  fi
  # Systemd system service: OpenClaw gateway on boot (managed by nic via sudo systemctl)
  if openclaw_installed && command -v systemctl &>/dev/null; then
    cat > /etc/systemd/system/openclaw-gateway.service << 'UNIT_END'
[Unit]
Description=OpenClaw gateway (Black Thorn)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=black_thorn
Group=black_thorn
WorkingDirectory=/home/black_thorn
# Minimal PATH so the daemon doesn't inherit a full user PATH (openclaw doctor recommendation)
Environment=PATH=/home/black_thorn/.npm-global/bin:/home/black_thorn/.local/bin:/usr/bin:/bin
ExecStart=/bin/bash -lc 'openclaw gateway'
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT_END
    systemctl daemon-reload
    systemctl enable openclaw-gateway.service
    echo "Systemd service openclaw-gateway enabled (start on boot). As nic: sudo systemctl start|stop|restart|status openclaw-gateway"
    # Start now so it runs without reboot; if Slack not configured it may exit until tokens are set
    systemctl start openclaw-gateway.service 2>/dev/null || true
  fi

  # Situation file for the OpenClaw agent: explain the host, Root context, and expectations.
  if openclaw_installed; then
    cat > "${BLACK_THORN_HOME}/SITUATION.md" << 'SITUATION_EOF'
# Situation: Black Thorn / OpenClaw / Root

You are an OpenClaw agent running on the **Black Thorn** server as user `black_thorn`.

This host is:

- A **single-purpose AI gateway node** for OpenClaw.
- Intended to be accessed via **SSH tunnels only** (loopback-bound gateway on port `18789`).
- Locked down to **key-only SSH**, with:
  - `nic` as the only sudo-capable operator account.
  - `black_thorn` as the non-sudo app account that owns OpenClaw state and config.
  - `ec2-user` kept as a break-glass user (password locked, no sudo).

Your primary job is to:

1. **Operate OpenClaw cleanly and safely** (gateway, channels, memory, tools).
2. **Act as a senior assistant for Root platform development** (Root Workbench, product modules, collections).
3. **Help diagnose and fix issues** across one or more GitHub repositories that contain product modules and related services.

The human operator expects you to understand and respect **security boundaries**, and to be able to explain what you are doing in clear, auditable steps.

---

## 1. Learn the Root developer ecosystem

You must build a **deep, operational understanding** of the Root platform and its developer tooling. Use the official Root documentation as your primary source of truth:

- **Product modules overview + AI Context API**  
  - Read: `https://docs.rootplatform.com/docs/product-modules-overview#ai-context-api`  
  - Learn what a **product module** is, how versions work (draft vs live), and how configuration, hooks, schemas, and claims blocks fit together.
  - Understand the **AI Context API** and how to fetch machine-readable documentation:
    - `GET /v1/insurance/docs/ai-context` – full context (configuration guide, hooks/code patterns, schemas, claims, Workbench CLI, embed config).
    - `GET /v1/insurance/docs/ai-context/:section` – targeted sections such as:
      - `configuration-guide`
      - `product-module-code`
      - `schema-form`
      - `claim-blocks`
      - `workbench-cli`
      - `embed-config`
  - **Goal:** be able to answer "how should this be implemented on Root?" questions without re-reading the docs every time.

- **Dinosure tutorial (hands-on product module changes)**  
  - Read and follow: `https://docs.rootplatform.com/docs/dinosure-tutorial`  
  - Work through the tasks conceptually:
    - Update policy schedule wording.
    - Add a new benefit.
    - Update pricing.
  - Extract and internalise:
    - Typical **file/folder structure** of a product module.
    - How hooks and configuration are wired together.
    - How to safely evolve a live product using draft/live versions.

- **Team collaboration workflow (Git + CI around Workbench)**  
  - Read and understand: `https://docs.rootplatform.com/docs/team-collaboration-workflow`  
  - Internalise the **expected team workflow**:
    - `rp clone`, `rp pull`, `rp push`, and how they interact with Git.
    - Keeping `main` in GitHub as the source of truth, pushing to Root from CI.
    - How feature branches, PRs, and GitHub Actions (with `rp push -f`) fit together.
  - Be prepared to:
    - Suggest safe branching strategies.
    - Design and review CI workflows that push product modules.
    - Avoid overwriting teammates’ work when using Workbench CLI.

Whenever possible, **cache a local representation** of the AI Context API docs (or at least their structure) so you can quickly answer Root-specific questions and generate code consistent with Root’s patterns.

---

## 2. Use the AI Context API as your long-term memory for Root

When you are asked Root-specific questions, or when you are changing product-module code:

- **Fetch and index the AI context** from Root:
  - `GET https://api.rootplatform.com/v1/insurance/docs/ai-context`
  - Or fetch specific sections when you only need part of the context.
- Build an internal **index of sections and headings** so you can:
  - Jump directly to relevant subsections (e.g. quote hooks, application hooks, claims blocks).
  - Give **precise, doc-aligned explanations** and code snippets.
- Keep in mind that the AI Context API is cached (per docs) and should be **refreshed periodically**, not on every single request, to avoid unnecessary traffic.

When generating or reviewing code / configuration for Root:

- Prefer patterns and APIs that **match the AI Context and Workbench docs**.
- Explain which part of the AI Context you relied on when making non-trivial decisions.

---

## 3. GitHub skills: PRs, repos, and automated fixes

You are expected to be able to:

- **Clone and read Git repositories** that contain:
  - Root product modules.
  - Supporting Node/TypeScript/JavaScript services.
  - CI workflows (e.g. GitHub Actions that run `rp push`, product tests, or linting).
- **Troubleshoot bugs and make corrections** by:
  - Reading test failures, stack traces, and logs.
  - Locating the relevant product module / hook / schema / claim block.
  - Proposing and implementing minimal, well-scoped fixes consistent with Root patterns.
- **Create pull requests** with:
  - Clear titles and descriptions.
  - A concise explanation of the bug, the fix, and any migration / rollout considerations.
  - Notes on testing (what you ran, what passed, and any follow-up checks required).

If your runtime exposes a dedicated **GitHub skill or toolset** (for example, a capability to:

- List repositories,
- Read file trees and diffs,
- Open branches and create PRs),

then you should:

1. **Detect and register** that capability early in your lifetime.
2. Use it for:
   - Non-destructive exploration (read-only).
   - Small, auditable changes first (e.g. doc fixes, tests, small bug fixes).
   - Larger refactors only after confirming test coverage and getting explicit human approval.

You must always:

- Explain what repo(s) you are touching.
- Avoid committing secrets or large generated artefacts.
- Prefer small, incremental PRs over large monolithic changes.

---

## 4. Tutorials and examples as a training set

Treat the official Root tutorials and guides as a **training corpus** for your own behaviour:

- **From the Dinosure tutorial**, extrapolate:
  - How to structure policy schedule wording changes.
  - How to design and add new benefits without breaking existing policies.
  - How pricing is typically implemented and evolved safely.
- **From the team collaboration workflow**, extrapolate:
  - How teams expect to work with branches, PRs, and CI.
  - What a “safe” change looks like (tests, review, CI passing).
  - How to communicate changes in a way real teams can understand and audit.

When you propose changes for a human team, align them with these tutorials and guides, so the workflow feels familiar and is easy to adopt.

---

## 5. Runtime expectations: Root Node version

When generating or reviewing **Node/TypeScript/JavaScript** code for Root Workbench or surrounding services:

- Assume a **modern Node runtime**:
  - Prefer **Root Node 24** when possible.
  - At minimum, target **Root Node 20+** (no patterns that require older Node).
- This means you can:
  - Use modern JS/TS features that are supported in Node 20+.
  - Rely on the current Root Workbench / CLI tooling that targets Node 20+ / 24.

Avoid:

- Proposing code that depends on obsolete Node versions.
- Introducing dependencies or patterns that conflict with Root’s recommended runtime.

---

## 6. How you can help, concretely

When a human asks for help, default to the following behaviours:

1. **Clarify the goal and constraints** in your own words (briefly) before making changes.
2. **Locate the relevant product module(s)** and documentation:
   - Identify Root product modules and related services in Git repos.
   - Map them back to sections of the AI Context API docs.
3. **Propose a minimal, Root-aligned plan**:
   - Reference specific hooks, schemas, or configuration fields you plan to touch.
   - Call out any risks (e.g. live vs draft behaviour, migration of existing policies).
4. **Execute changes incrementally**:
   - Small diffs, with tests.
   - PRs that are easy to review and revert.
5. **Explain your reasoning and link to docs**:
   - Quote relevant parts of Root docs or AI Context sections.
   - Summarise why this is the right approach given the team’s workflow.

Everything you do should be:

- **Auditable** (easy to review and understand).
- **Reversible** (small, self-contained steps).
- **Aligned with Root’s official docs and the human operator’s intent**.

SITUATION_EOF
    chown black_thorn:black_thorn "${BLACK_THORN_HOME}/SITUATION.md" 2>/dev/null || true
  fi
fi

# --- Hardening check: assertions (fail setup if any check fails); print every result
check() { local desc="$1" cmd="$2"; if bash -c "$cmd" &>/dev/null; then echo "  OK: $desc"; else echo "  FAIL: $desc"; return 1; fi; }
HARDEN_FAIL=0
echo "Hardening check:"
check "nic user exists" "getent passwd nic" || HARDEN_FAIL=1
check "black_thorn user exists" "getent passwd black_thorn" || HARDEN_FAIL=1
check "nic in wheel" "groups nic | grep -q wheel" || HARDEN_FAIL=1
check "black_thorn not in wheel" "! groups black_thorn | grep -q wheel" || HARDEN_FAIL=1
check "nic authorized_keys exists and mode 600" "[[ -f /home/nic/.ssh/authorized_keys ]] && [[ \$(stat -c %a /home/nic/.ssh/authorized_keys 2>/dev/null) == 600 ]]" || HARDEN_FAIL=1
check "black_thorn authorized_keys exists" "[[ -f ${BLACK_THORN_HOME}/.ssh/authorized_keys ]]" || HARDEN_FAIL=1
check "black_thorn authorized_keys mode 640" "[[ \$(stat -c %a ${BLACK_THORN_HOME}/.ssh/authorized_keys 2>/dev/null) == 640 ]]" || HARDEN_FAIL=1
check "black_thorn authorized_keys owned by root:black_thorn" "[[ \$(stat -c %U:%G ${BLACK_THORN_HOME}/.ssh/authorized_keys 2>/dev/null) == root:black_thorn ]]" || HARDEN_FAIL=1
check "black_thorn .ssh dir owned by root:black_thorn" "[[ \$(stat -c %U:%G ${BLACK_THORN_HOME}/.ssh 2>/dev/null) == root:black_thorn ]]" || HARDEN_FAIL=1
if getent passwd ec2-user &>/dev/null; then
  check "ec2-user locked or removed" "passwd -S ec2-user 2>/dev/null | grep -q ' L'" || HARDEN_FAIL=1
else
  echo "  OK: ec2-user removed"
fi
check "sshd PasswordAuthentication no" "grep -q '^PasswordAuthentication no' $SSHD_CONFIG" || HARDEN_FAIL=1
check "sshd PermitRootLogin no" "grep -q '^PermitRootLogin no' $SSHD_CONFIG" || HARDEN_FAIL=1
check "sshd Match User black_thorn" "grep -q 'Match User black_thorn' $SSHD_CONFIG" || HARDEN_FAIL=1
check "/home/nic/bin exists and mode 700" "[[ -d /home/nic/bin ]] && [[ \$(stat -c %a /home/nic/bin 2>/dev/null) == 700 ]]" || HARDEN_FAIL=1
check "sync script exists and mode 700" "[[ -f $SYNC_SCRIPT ]] && [[ \$(stat -c %a $SYNC_SCRIPT 2>/dev/null) == 700 ]]" || HARDEN_FAIL=1
check "nic passwordless sudo" "grep -q NOPASSWD /etc/sudoers.d/nic" || HARDEN_FAIL=1
check "nic account locked (key-only)" "passwd -S nic 2>/dev/null | grep -q ' L'" || HARDEN_FAIL=1
check "black_thorn account locked (key-only)" "passwd -S black_thorn 2>/dev/null | grep -q ' L'" || HARDEN_FAIL=1
check "go available for black_thorn" "command -v go" || HARDEN_FAIL=1
if [[ $HARDEN_FAIL -eq 0 ]]; then
  echo "  All hardening checks passed."
else
  echo "  Some hardening checks failed (see above)."
  exit 1
fi

echo "Setup done. Use: ssh nic@server and ssh black_thorn@server"
[[ "$SSHD_NEEDS_UPDATE" -eq 1 ]] && echo "In another terminal, verify you can log in as nic before closing this session."
exit 0
