#!/usr/bin/env bash
# Copy authorized_keys and setup script to the server, then run setup as root.
# Usage: ./scripts/run-setup-remote.sh [user@host]
# Example: ./scripts/run-setup-remote.sh ec2-user@ec2-13-247-181-255.af-south-1.compute.amazonaws.com

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AUTHORIZED_KEYS="$REPO_ROOT/authorized_keys"

REMOTE="${1:-}"
if [[ -z "$REMOTE" ]]; then
  echo "Usage: $0 user@host" >&2
  echo "Example: $0 ec2-user@ec2-13-247-181-255.af-south-1.compute.amazonaws.com" >&2
  exit 1
fi

if [[ ! -f "$AUTHORIZED_KEYS" ]]; then
  echo "Missing $AUTHORIZED_KEYS. Add at least one SSH public key (one per line)." >&2
  exit 1
fi

if grep -v '^#' "$AUTHORIZED_KEYS" | grep -q .; then
  : # has at least one key
else
  echo "No SSH public keys in $AUTHORIZED_KEYS (only comments or empty lines)." >&2
  exit 1
fi

# Use remote user's home (works for ec2-user or nic; /tmp may be unwritable for nic)
REMOTE_USER="${REMOTE%%@*}"
REMOTE_HOME="/home/$REMOTE_USER"

echo "Copying authorized_keys and setup script to $REMOTE..."
scp "$AUTHORIZED_KEYS" "$REMOTE:$REMOTE_HOME/authorized_keys"
scp "$SCRIPT_DIR/setup-server.sh" "$REMOTE:$REMOTE_HOME/setup-server.sh"

echo "Running setup as root on $REMOTE..."
ssh -t "$REMOTE" "sudo AUTHORIZED_KEYS=$REMOTE_HOME/authorized_keys $REMOTE_HOME/setup-server.sh"

echo "Done. You can now use: ssh nic@${REMOTE#*@} and ssh black_thorn@${REMOTE#*@}"
