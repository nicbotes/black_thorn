# Black Thorn – server setup

Repeatable setup for a single server with:

- **Superuser `nic`** – full sudo access.
- **User `black_thorn`** – no sudo, SSH only via keys from this repo. Cannot change its own SSH authorized keys (they are root-owned). Openclaw is installed in their home.

SSH access is key-only; the keys are taken from the `authorized_keys` file in this directory.

**Before setup** you log in as the default EC2 user (e.g. `ec2-user` on Amazon Linux) and run the script with `sudo`. **At the end of setup, `ec2-user` is removed**; from then on only `nic` and `black_thorn` can log in. In another terminal, verify you can `ssh nic@server` before closing your ec2-user session.

## One-time setup

1. **Add your SSH public key(s)** to `authorized_keys` (one per line; lines starting with `#` are ignored).

2. **Run the setup** in one of these ways.

   **Option A – from your machine (recommended):**
   ```bash
   chmod +x scripts/run-setup-remote.sh
   ./scripts/run-setup-remote.sh ec2-user@ec2-13-247-181-255.af-south-1.compute.amazonaws.com
   ```

   **Option B – manually:**
   ```bash
   scp authorized_keys ec2-user@YOUR_SERVER:/tmp/authorized_keys
   scp scripts/setup-server.sh ec2-user@YOUR_SERVER:/tmp/
   ssh ec2-user@YOUR_SERVER 'sudo AUTHORIZED_KEYS=/tmp/authorized_keys /tmp/setup-server.sh'
   ```

3. **Log in:**
   - `ssh nic@YOUR_SERVER` (sudo)
   - `ssh black_thorn@YOUR_SERVER` (restricted user, no sudo)

## What the setup does

- Creates user `nic` in the `wheel` group (sudo).
- Creates user `black_thorn` with no sudo.
- Installs the contents of `authorized_keys` for both users.
- For `black_thorn`: normal home at `/home/black_thorn`, `~/.ssh/authorized_keys` root-owned so they cannot add or change SSH keys. **Go (Golang)** is installed system-wide so black_thorn can use `go`.
- **Cron for nic:** A script at `/home/nic/bin/sync-authorized-keys.sh` (mode 700, only nic can read) fetches [GitHub nicbotes.keys](https://github.com/nicbotes.keys) every 6 hours and updates `authorized_keys` for both nic and black_thorn. black_thorn cannot read the script or nic’s home.
- **Last step (after the server is secured):** Node.js 22+ is installed (NodeSource if needed), then **openclaw** is installed for `black_thorn` via the official install script. Openclaw runs only after users, SSH, and ec2-user removal are done.
- Installs **htop** and **ufw** (SSH allowed, then enable; ufw not available on all distros, e.g. Amazon Linux 2023 uses firewalld).
- **Removes the `ec2-user` account** (and its home) so only `nic` and `black_thorn` remain.
- Configures `sshd`: key-only auth, no password or challenge-response, `PermitRootLogin no`, `MaxAuthTries 3`, and a `Match User black_thorn` block to disable forwarding.
- **Locks both accounts** (`passwd -l`): no password can be used even if re-enabled elsewhere; SSH key is the only way in.
- **Hardening check:** At the end of the setup, a series of assertions run (users, permissions, sshd config, sync script). If any fail, the script exits with code 1.

## Changing authorized keys later

1. Edit `authorized_keys` in this repo.
2. Copy it to the server and re-run the part of the setup that writes keys, or run the full setup again (creating users is idempotent). For a quick key-only update:

   ```bash
   # Update nic's keys
   scp authorized_keys nic@YOUR_SERVER:/tmp/authorized_keys
   ssh nic@YOUR_SERVER 'cat /tmp/authorized_keys > ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'

   # Update black_thorn's keys (must be root)
   scp authorized_keys ec2-user@YOUR_SERVER:/tmp/authorized_keys
   ssh ec2-user@YOUR_SERVER 'sudo bash -c "grep -v \"^#\" /tmp/authorized_keys | grep -v \"^[[:space:]]*\$\" > /home/black_thorn/.ssh/authorized_keys"'
   ```

Or run the full setup script again; it overwrites the key files.

## Security recommendations

Beyond what the setup script does (key-only SSH, locked accounts, no root login), consider:

| Control | Why |
|--------|-----|
| **Restrict SSH by IP** | In AWS Security Group (or host firewall), allow port 22 only from your IP or a VPN/bastion. Reduces exposure to the internet. |
| **Fail2ban** | Rate-limit SSH attempts (e.g. block IP after 5 failed tries). Less critical with key-only auth but still limits noise and brute-force. |
| **Automatic security updates** | Enable `dnf-automatic` (Amazon Linux 2023) or `yum-cron` / `unattended-upgrades` (Debian) so security patches apply without manual action. |
| **Host firewall** | Only allow required ports (e.g. 22 for SSH, 80/443 if you run a web app). Deny everything else by default. |
| **EC2: IMDSv2** | Prefer instance metadata service v2 (session-oriented, no GET from link-local). Reduces risk if something on the box is compromised. |
| **Minimal software** | Remove or disable services you don’t need (e.g. old web server, unused cron jobs). |
| **Audit logging** | Keep auth logs and consider `auditd` or cloud trail for EC2 for who did what and when. |
| **Separate key for black_thorn** | Use a different key for `black_thorn` than for `nic` so compromise of the app user doesn’t grant sudo. |

Optional and more involved: move SSH to a non-default port (reduces log noise, not real security), or put the box behind a VPN/bastion and only allow SSH from there.

---

## Is this “proper” IaC?

What you have is **scripted, repeatable setup**: one script + one `authorized_keys` file, both in version control. That’s a solid, simple form of “infrastructure as code” for a single server: run the script and you get a consistent state.

If you want **stricter IaC** (declarative, idempotent, standard tooling), the usual next step is **Ansible** (playbooks for users, files, sshd, packages). Terraform is better for cloud resources (EC2, security groups); for full OS config people often pair it with Ansible or a script.
