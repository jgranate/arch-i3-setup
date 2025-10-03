#!/usr/bin/env bash
# setup.sh — Post-install script for Arch on 2018 Mac mini (T2)
# Use with archinstall (User Scripts → Post-Install). Run as root.
set -euo pipefail

# --- Config: adjust if your layout differs ---
PKG_FILE="${PKG_FILE:-packages.txt}"
DOTFILES_DIR="${DOTFILES_DIR:-dotfiles}"

# Figure out the real user (archinstall usually created it already)
REAL_USER="${SUDO_USER:-${REAL_USER:-$(awk -F: '$3>=1000 && $1!="nobody"{print $1; exit}' /etc/passwd)}}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6 || echo "/home/$REAL_USER")"

log() { printf "\n==> %s\n" "$*"; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "This script must run as root (archinstall post-install)." >&2
    exit 1
  fi
}

enable_ntp() {
  log "Enabling NTP time sync…"
  timedatectl set-ntp true || true
}

sync_upgrade() {
  log "Refreshing package databases & upgrading…"
  pacman -Syu --noconfirm
}

install_base_pkgs() {
  log "Installing Arch packages from ${PKG_FILE}…"
  if [[ ! -f "$PKG_FILE" ]]; then
    echo "Missing $PKG_FILE next to setup.sh" >&2
    exit 2
  fi
  # Filter comments/blank lines and defer 'yay' to separate step
  grep -v -E '^\s*(#|$)' "$PKG_FILE" | grep -v -E '^yay$' \
    | xargs -r pacman -S --needed --noconfirm
}

bootstrap_yay() {
  if command -v yay >/dev/null 2>&1; then
    log "yay already installed."
    return
  fi
  log "Bootstrapping yay (AUR helper)…"
  pacman -S --needed --noconfirm git base-devel
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  sudo -u "$REAL_USER" git clone https://aur.archlinux.org/yay.git "$tmpdir/yay"
  pushd "$tmpdir/yay" >/dev/null
  sudo -u "$REAL_USER" makepkg -si --noconfirm
  popd >/dev/null
}

install_t2_kernel_and_audio() {
  log "Installing linux-t2 kernel + headers + Apple T2 firmware/config (AUR)…"
  sudo -u "$REAL_USER" yay -S --needed --noconfirm \
    linux-t2 linux-t2-headers \
    apple-bcm-firmware \
    apple-t2-audio-config

  # Optional: ensure useful modules are loaded early
  install -Dm0644 /dev/stdin /etc/modules-load.d/t2-audio.conf <<'EOF'
apple_bce
snd_hda_intel
snd_soc_avs
snd_sof_pci_intel_cnl
EOF

  # Remove stock kernel to avoid confusion (keep system bootable because linux-t2 is now installed)
  if pacman -Qi linux >/dev/null 2>&1; then
    log "Removing stock 'linux' kernel…"
    pacman -Rns --noconfirm linux || true
  fi
  if pacman -Qi linux-headers >/dev/null 2>&1; then
    pacman -Rns --noconfirm linux-headers || true
  fi

  # Make sure initramfs exists for linux-t2 (normally created by the package hook)
  if command -v mkinitcpio >/dev/null 2>&1; then
    log "Running mkinitcpio -P (safety)…"
    mkinitcpio -P || true
  fi
}

fix_bootloader_entry() {
  # Handle systemd-boot or GRUB automatically
  if [[ -f /boot/loader/loader.conf || -d /boot/loader/entries ]]; then
    log "Patching systemd-boot entries to use linux-t2…"
    shopt -s nullglob
    for entry in /boot/loader/entries/*.conf; do
      # Replace linux and initrd paths to the -t2 variants
      sed -i \
        -e 's#^\s*linux\s\+/vmlinuz-linux\b#linux   /vmlinuz-linux-t2#' \
        -e 's#^\s*initrd\s\+/initramfs-linux\.img\b#initrd  /initramfs-linux-t2.img#' \
        -e 's#^\s*initrd\s\+/initramfs-linux-fallback\.img\b#initrd  /initramfs-linux-t2-fallback.img#' \
        "$entry" || true

      # Ensure intel-ucode is first if present
      if [[ -f /intel-ucode.img ]] && ! grep -q 'initrd.*/intel-ucode.img' "$entry"; then
        sed -i '0,/^initrd/s//initrd  /intel-ucode.img\n&/' "$entry"
      fi
    done
  elif command -v grub-mkconfig >/dev/null 2>&1; then
    log "Regenerating GRUB config…"
    grub-mkconfig -o /boot/grub/grub.cfg
  else
    log "Bootloader not detected; skip patching. Verify manually."
  fi
}

copy_dotfiles_and_make_scripts_exec() {
  log "Copying dotfiles to ${REAL_HOME}…"
  install -d -m 0755 "$REAL_HOME/.config"
  if [[ -d "$DOTFILES_DIR/.config" ]]; then
    cp -rT "$DOTFILES_DIR/.config" "$REAL_HOME/.config"
    chown -R "$REAL_USER":"$REAL_USER" "$REAL_HOME/.config"
  fi
  if [[ -f "$DOTFILES_DIR/.xinitrc" ]]; then
    cp -f "$DOTFILES_DIR/.xinitrc" "$REAL_HOME/.xinitrc"
    chown "$REAL_USER":"$REAL_USER" "$REAL_HOME/.xinitrc"
  fi

  # Make your scripts executable if present
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

enable_services_and_hardening() {
  log "Enabling services: NetworkManager, sshd, ufw, fail2ban…"
  systemctl enable NetworkManager || true
  systemctl enable sshd || true
  systemctl enable ufw || true
  systemctl enable fail2ban || true

  # UFW sane defaults
  if command -v ufw >/dev/null 2>&1; then
    ufw --force default deny incoming
    ufw --force default allow outgoing
    ufw --force allow OpenSSH || ufw --force allow 22/tcp
    ufw --force enable
  fi

  # PipeWire stack for the user (enable + start now); keep running across logouts
  if command -v loginctl >/dev/null 2>&1; then
    loginctl enable-linger "$REAL_USER" || true
  fi
  sudo -u "$REAL_USER" systemctl --user enable pipewire pipewire-pulse wireplumber || true
  sudo -u "$REAL_USER" systemctl --user start  pipewire pipewire-pulse wireplumber  || true
}

post_summary() {
  log "Setup complete."
  echo "Next: reboot to use the linux-t2 kernel."
  echo
  echo "Quick checks after reboot:"
  echo "  uname -r                                   # should show *-t2"
  echo "  aplay -l                                   # AppleT2x1 + HDA Intel PCH"
  echo "  systemctl --user status pipewire-pulse     # running"
  echo "  pactl info                                 # Server: PulseAudio (on PipeWire …)"
  echo "  ufw status                                 # active"
}

main() {
  require_root
  enable_ntp
  sync_upgrade
  install_base_pkgs
  bootstrap_yay
  install_t2_kernel_and_audio
  fix_bootloader_entry
  copy_dotfiles_and_make_scripts_exec
  enable_services_and_hardening
  post_summary
}
main "$@"

