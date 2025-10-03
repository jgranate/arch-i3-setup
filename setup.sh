#!/usr/bin/env bash
# setup.sh — minimal post-install for Arch
# Run as root after first login (not from archinstall)

set -euo pipefail

PKG_FILE="${PKG_FILE:-packages.txt}"

# Detect your real user
REAL_USER="${SUDO_USER:-$(logname)}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

log() { echo -e "\n==> $*"; }

install_base_pkgs() {
  log "Installing Arch packages from ${PKG_FILE}…"
  [[ -f "$PKG_FILE" ]] || { echo "Missing $PKG_FILE"; exit 2; }
  grep -v -E '^\s*(#|$)' "$PKG_FILE" | grep -v -E '^(yay|paru)$' \
    | xargs -r pacman -S --needed --noconfirm
}

bootstrap_yay() {
  if command -v yay >/dev/null 2>&1; then
    log "yay already installed."
    return
  fi
  log "Bootstrapping yay…"
  pacman -S --needed --noconfirm git base-devel
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  sudo -u "$REAL_USER" git clone https://aur.archlinux.org/yay.git "$tmpdir/yay"
  pushd "$tmpdir/yay" >/dev/null
  sudo -u "$REAL_USER" makepkg -si --noconfirm
  popd >/dev/null
}

make_scripts_exec() {
  log "Making scripts executable…"
  for f in \
    "$REAL_HOME/.config/scripts/set-resolution.sh" \
    "$REAL_HOME/.config/polybar/launch.sh"
  do
    if [[ -f "$f" ]]; then
      chmod +x "$f"
      chown "$REAL_USER":"$REAL_USER" "$f"
    fi
  done
}

enable_pipewire() {
  log "Enabling PipeWire + PulseAudio…"
  if command -v loginctl >/dev/null 2>&1; then
    loginctl enable-linger "$REAL_USER" || true
  fi
  sudo -u "$REAL_USER" systemctl --user enable pipewire pipewire-pulse wireplumber
  sudo -u "$REAL_USER" systemctl --user start  pipewire pipewire-pulse wireplumber
}

main() {
  [[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }
  pacman -Syu --noconfirm
  install_base_pkgs
  bootstrap_yay
  make_scripts_exec
  enable_pipewire
  log "Minimal setup complete. Reboot and start i3 + Polybar + Firefox."
}

main "$@"


