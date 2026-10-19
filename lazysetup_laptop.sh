#!/usr/bin/env bash
# CachyOS post-install setup
# Save as: cachyos-setup.sh
# Run: chmod +x cachyos-setup.sh && ./cachyos-setup.sh

set -u
LOG="$HOME/cachyos-setup-$(date +%F-%H%M%S).log"
FAILED=()
AUR_PACKAGES=(
  jetbrains-toolbox
  android-studio
  intel-npu-driver
  manjaro-zsh-config
)

exec > >(tee -a "$LOG") 2>&1

section() {
  printf '\n\033[1;36m==> %s\033[0m\n' "$*"
}

install_repo() {
  local pkg
  for pkg in "$@"; do
    section "Installing repository package: $pkg"
    if sudo pacman -S --needed --noconfirm "$pkg"; then
      echo "OK: $pkg"
    else
      echo "FAILED: $pkg"
      FAILED+=("$pkg")
    fi
  done
}

install_aur() {
  local pkg
  for pkg in "$@"; do
    section "Installing AUR package: $pkg"
    if paru -S --needed "$pkg"; then
      echo "OK: $pkg"
    else
      echo "FAILED: $pkg"
      FAILED+=("$pkg")
    fi
  done
}

if [[ ! -f /etc/arch-release ]]; then
  echo "This script is intended for CachyOS/Arch Linux."
  exit 1
fi

if [[ $EUID -eq 0 ]]; then
  echo "Run this script as your normal user, not with sudo."
  exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
  echo "sudo is required."
  exit 1
fi

echo "Log file: $LOG"
echo "This setup can install large packages and update your system."
read -r -p "Continue? [y/N] " answer
[[ "$answer" =~ ^[Yy]$ ]] || exit 0

section "Update system"
sudo pacman -Syu || {
  echo "System update failed. Resolve that before continuing."
  exit 1
}

section "Development essentials and shell"
install_repo \
  base-devel git curl wget unzip zip p7zip \
  openssh github-cli \
  zsh neovim fastfetch \
  tk nodejs npm python python-pip \
  ripgrep fd fzf wl-clipboard xclip \
  flatpak

section "Wine and Windows compatibility"
install_repo wine wine-mono wine-gecko winetricks

section "Virtualization: QEMU and libvirt"
install_repo \
  qemu-desktop virt-manager virt-viewer \
  dnsmasq vde2 edk2-ovmf swtpm

section "HP printing support"
install_repo \
  hplip cups system-config-printer \
  print-manager avahi usbutils

section "Graphics, gaming and desktop apps"
install_repo krita prismlauncher ollama

section "Enable Flatpak and Flathub"
if sudo flatpak remote-add --system --if-not-exists flathub \
  https://flathub.org/repo/flathub.flatpakrepo; then
  echo "Flathub configured."
else
  FAILED+=(flathub-setup)
fi

section "Install Bottles and ZapZap from Flathub"
for app in com.usebottles.bottles com.rtosta.zapzap; do
  if flatpak install --system --noninteractive flathub "$app"; then
    echo "OK: $app"
  else
    echo "FAILED: $app"
    FAILED+=("$app")
  fi
done

section "Enable services"
sudo systemctl enable --now sshd.service || FAILED+=(sshd-service)
sudo systemctl enable --now cups.service || FAILED+=(cups-service)
sudo systemctl enable --now avahi-daemon.service || FAILED+=(avahi-service)
sudo systemctl enable --now libvirtd.service || FAILED+=(libvirtd-service)

section "Add current user to virtualization group"
if getent group libvirt >/dev/null; then
  sudo usermod -aG libvirt "$USER"
fi

section "Install or locate paru (AUR helper)"
if ! command -v paru >/dev/null 2>&1; then
  if command -v yay >/dev/null 2>&1; then
    echo "yay is available; using it instead of paru."
    AUR_HELPER=yay
  else
    echo "Building paru from the AUR."
    tmpdir="$(mktemp -d)"
    if git clone https://aur.archlinux.org/paru.git "$tmpdir/paru"; then
      (
        cd "$tmpdir/paru"
        makepkg -si
      ) || FAILED+=(paru-bootstrap)
    else
      FAILED+=(paru-clone)
    fi
    rm -rf "$tmpdir"
  fi
fi

if command -v paru >/dev/null 2>&1; then
  AUR_HELPER=paru
elif command -v yay >/dev/null 2>&1; then
  AUR_HELPER=yay
fi

if [[ -n "${AUR_HELPER:-}" ]]; then
  section "Install AUR applications"
  for pkg in "${AUR_PACKAGES[@]}"; do
    if "$AUR_HELPER" -S --needed "$pkg"; then
      echo "OK: $pkg"
    else
      echo "FAILED or unavailable in AUR: $pkg"
      FAILED+=("$pkg")
    fi
  done
else
  echo "No AUR helper available. Skipping AUR packages."
  FAILED+=(aur-packages-skipped)
fi

section "Install Claude Code"
if command -v claude >/dev/null 2>&1; then
  echo "Claude Code already installed."
else
  tmpfile="$(mktemp)"
  if curl -fsSL https://claude.ai/install.sh -o "$tmpfile" &&
     bash "$tmpfile"; then
    echo "Claude Code installer completed."
  else
    echo "Claude Code installation failed."
    FAILED+=(claude-code)
  fi
  rm -f "$tmpfile"
fi

section "Install OpenAI Codex CLI"
if command -v codex >/dev/null 2>&1; then
  echo "Codex already installed."
elif sudo pacman -S --needed --noconfirm npm &&
     sudo npm install -g @openai/codex; then
  echo "Codex CLI installed."
else
  echo "Codex installation failed."
  FAILED+=(codex-cli)
fi

section "LazyVim setup"
if [[ -d "$HOME/.config/nvim" ]]; then
  backup="$HOME/.config/nvim.backup-$(date +%F-%H%M%S)"
  echo "Existing Neovim config found."
  read -r -p "Back it up and install LazyVim? [y/N] " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    mv "$HOME/.config/nvim" "$backup"
    [[ ! -d "$HOME/.local/share/nvim" ]] ||
      mv "$HOME/.local/share/nvim" "$backup-data"
    git clone https://github.com/LazyVim/starter "$HOME/.config/nvim" ||
      FAILED+=(lazyvim)
    rm -rf "$HOME/.config/nvim/.git"
    echo "Config backup: $backup"
  else
    echo "Skipping LazyVim to preserve your configuration."
  fi
else
  git clone https://github.com/LazyVim/starter "$HOME/.config/nvim" &&
    rm -rf "$HOME/.config/nvim/.git" || FAILED+=(lazyvim)
fi

section "Ollama service"
read -r -p "Enable Ollama on boot and start it now? [y/N] " answer
if [[ "$answer" =~ ^[Yy]$ ]]; then
  sudo systemctl enable --now ollama.service || FAILED+=(ollama-service)
fi

section "Final report"
if ((${#FAILED[@]})); then
  echo "Some items failed or need manual attention:"
  printf ' - %s\n' "${FAILED[@]}"
  echo "Check the log: $LOG"
else
  echo "All requested installation steps completed."
fi

echo
echo "Next steps:"
echo "1. Reboot or log out and back in."
echo "2. Run 'hp-setup -u' to configure your HP printer."
echo "3. Open JetBrains Toolbox and install your IDEs."
echo "4. Open Android Studio to download the Android SDK."
echo "5. Run 'ollama pull <model>' to download an AI model."
echo "6. Check Intel NPU compatibility for your CPU and kernel."
echo "7. Authenticate Claude Code and Codex when prompted."
echo
echo "Log saved to: $LOG"
