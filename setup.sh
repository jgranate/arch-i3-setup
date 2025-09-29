#!/bin/bash
set -e

echo "==> Syncing time and updating system..."
sudo timedatectl set-ntp true
sudo pacman -Syu --noconfirm

echo "==> Installing base packages from packages.txt..."
# Make sure yay is not in the package list
grep -v '^yay$' packages.txt | xargs sudo pacman -S --needed --noconfirm

# === Install yay if not present ===
if ! command -v yay &>/dev/null; then
  echo "==> Installing yay from AUR..."
  sudo pacman -S --needed --noconfirm git base-devel

  tmpdir=$(mktemp -d)
  git clone https://aur.archlinux.org/yay.git "$tmpdir/yay"
  cd "$tmpdir/yay"
  makepkg -si --noconfirm
  cd -
  rm -rf "$tmpdir"
fi

echo "==> Copying dotfiles..."
mkdir -p ~/.config
cp -r dotfiles/.config/* ~/.config/
cp dotfiles/.xinitrc ~/

echo "==> Setting GTK theme..."
mkdir -p ~/.config/gtk-3.0 ~/.config/gtk-4.0
cp -r dotfiles/.config/gtk-3.0/* ~/.config/gtk-3.0/
cp -r dotfiles/.config/gtk-4.0/* ~/.config/gtk-4.0/

# (Removed VM/display-resolution script section)

echo "==> Installing Rofi themes..."
git clone https://github.com/lr-tech/rofi-themes-collection.git /tmp/rofi-themes-collection
mkdir -p ~/.local/share/rofi/themes
cp /tmp/rofi-themes-collection/themes/*.rasi ~/.local/share/rofi/themes/

echo "==> Applying default Rofi theme..."
mkdir -p ~/.config/rofi
echo '@import "~/.local/share/rofi/themes/nord.rasi"' > ~/.config/rofi/config.rasi
rm -rf /tmp/rofi-themes-collection

# (Removed VMware tools enable, LightDM enable, and WirePlumber stutter fix)

echo "==> Setup complete. Run 'startx' to enter i3."

