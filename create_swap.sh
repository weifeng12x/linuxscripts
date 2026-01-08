#!/usr/bin/env bash
set -euo pipefail

# create-swap.sh
# Interactive swapfile creator for Ubuntu (and most Linux distros using /etc/fstab)
# - Asks for swap size (e.g. 2G, 2048M)
# - Creates /swapfile (or /swapfile-<size> if /swapfile already exists)
# - Sets permissions, mkswap, swapon
# - Adds /etc/fstab entry (idempotent)
# - Optionally sets vm.swappiness persistently

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "ERROR: Please run as root: sudo $0"
  exit 1
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: Missing command: $1"; exit 1; }
}

need_cmd free
need_cmd swapon
need_cmd mkswap
need_cmd chmod
need_cmd grep
need_cmd tee
need_cmd awk
need_cmd sed

echo "Current memory/swap status:"
free -h || true
echo
swapon --show || true
echo

read -r -p "Enter swap size (e.g. 2G, 2048M) [default: 2G]: " SWAP_SIZE
SWAP_SIZE="${SWAP_SIZE:-2G}"

# Basic validation
if [[ ! "$SWAP_SIZE" =~ ^[0-9]+[MG]$ ]]; then
  echo "ERROR: Invalid size format. Use like 2G or 2048M."
  exit 1
fi

SWAPFILE="/swapfile"
if [[ -e "$SWAPFILE" ]]; then
  # Avoid overwriting existing /swapfile; create a unique name
  SWAPFILE="/swapfile-${SWAP_SIZE}"
  if [[ -e "$SWAPFILE" ]]; then
    echo "ERROR: $SWAPFILE already exists. Please remove it or choose a different size."
    exit 1
  fi
  echo "NOTE: /swapfile already exists; will create: $SWAPFILE"
fi

echo
echo "Creating swapfile: $SWAPFILE ($SWAP_SIZE)"

# Try fallocate first; fallback to dd if fallocate fails (some FS don't support it)
if command -v fallocate >/dev/null 2>&1; then
  if ! fallocate -l "$SWAP_SIZE" "$SWAPFILE" 2>/dev/null; then
    echo "fallocate failed; falling back to dd..."
    USE_DD=1
  else
    USE_DD=0
  fi
else
  USE_DD=1
fi

if [[ "${USE_DD:-0}" -eq 1 ]]; then
  need_cmd dd
  # Convert size to MiB for dd
  NUM="${SWAP_SIZE%[MG]}"
  UNIT="${SWAP_SIZE: -1}"
  if [[ "$UNIT" == "G" ]]; then
    COUNT=$((NUM * 1024))
  else
    COUNT=$((NUM))
  fi
  dd if=/dev/zero of="$SWAPFILE" bs=1M count="$COUNT" status=progress
fi

echo "Setting permissions (600)..."
chmod 600 "$SWAPFILE"

echo "Formatting swap (mkswap)..."
mkswap "$SWAPFILE" >/dev/null

echo "Enabling swap (swapon)..."
swapon "$SWAPFILE"

echo
echo "Swap enabled. Current swap devices:"
swapon --show
echo
free -h || true
echo

# Add to /etc/fstab (idempotent)
FSTAB_LINE="$SWAPFILE none swap sw 0 0"
if grep -qE "^[[:space:]]*${SWAPFILE//\//\\/}[[:space:]]+none[[:space:]]+swap[[:space:]]" /etc/fstab; then
  echo "fstab already contains an entry for $SWAPFILE; skipping."
else
  echo "Adding to /etc/fstab for persistence..."
  echo "$FSTAB_LINE" | tee -a /etc/fstab >/dev/null
fi

# Optional swappiness tuning
echo
CURRENT_SWAPPINESS="$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "unknown")"
echo "Current vm.swappiness: $CURRENT_SWAPPINESS"
read -r -p "Set vm.swappiness permanently? [y/N]: " SET_SW
SET_SW="${SET_SW:-N}"

if [[ "$SET_SW" =~ ^[Yy]$ ]]; then
  read -r -p "Enter swappiness value (recommended 10-20 for servers) [default: 10]: " SWAPPINESS
  SWAPPINESS="${SWAPPINESS:-10}"
  if [[ ! "$SWAPPINESS" =~ ^[0-9]+$ ]] || (( SWAPPINESS < 0 || SWAPPINESS > 200 )); then
    echo "ERROR: swappiness must be an integer between 0 and 200."
    exit 1
  fi

  echo "Applying runtime swappiness..."
  sysctl -w "vm.swappiness=$SWAPPINESS" >/dev/null

  CONF_FILE="/etc/sysctl.d/99-swappiness.conf"
  echo "Persisting to $CONF_FILE ..."
  echo "vm.swappiness=$SWAPPINESS" | tee "$CONF_FILE" >/dev/null

  echo "Done. New vm.swappiness: $(cat /proc/sys/vm/swappiness)"
fi

echo
echo "All done."
echo "Swapfile: $SWAPFILE"
echo "To disable/remove later:"
echo "  sudo swapoff $SWAPFILE"
echo "  sudo sed -i '\\|^$SWAPFILE none swap sw 0 0$|d' /etc/fstab"
echo "  sudo rm -f $SWAPFILE"
