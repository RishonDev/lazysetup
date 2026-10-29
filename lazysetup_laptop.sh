#!/usr/bin/env bash
# CachyOS post-install setup (laptop)
# Run: chmod +x lazysetup_laptop.sh && ./lazysetup_laptop.sh

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$HOME/cachyos-setup-$(date +%F-%H%M%S).log"
FAILED=()
AUR_PACKAGES=(
  jetbrains-toolbox
  android-studio
  hopper4
  howdy
  jdk25-graalvm-ce-bin
  liberica-nik-23-full-bin
)

# Colours only on a real terminal; respect NO_COLOR (https://no-color.org).
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  BOLD=$'\033[1m' DIM=$'\033[2m' RESET=$'\033[0m'
  RED=$'\033[1;31m' GREEN=$'\033[1;32m' YELLOW=$'\033[1;33m'
  BLUE=$'\033[1;34m' CYAN=$'\033[1;36m'
else
  BOLD='' DIM='' RESET='' RED='' GREEN='' YELLOW='' BLUE='' CYAN=''
fi

# Screen gets colour; the log gets the same text with escape codes stripped.
exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >>"$LOG")) 2>&1

# Top-level steps are the `step` calls at column 0 of this file.
TOTAL_STEPS=$(grep -c '^step ' "${BASH_SOURCE[0]}")
STEP=0
START_TIME=$SECONDS
STEP_START=$SECONDS

step() {
  local elapsed=$((SECONDS - STEP_START))
  ((STEP > 0)) && printf '%s   done in %ds%s\n' "$DIM" "$elapsed" "$RESET"
  STEP=$((STEP + 1))
  STEP_START=$SECONDS
  local pct=$((STEP * 100 / TOTAL_STEPS)) width=24
  local filled=$((pct * width / 100)) bar rest
  printf -v bar '%*s' "$filled" ''
  printf -v rest '%*s' $((width - filled)) ''
  printf '\n%s[%d/%d]%s %s%s%s\n' "$BLUE" "$STEP" "$TOTAL_STEPS" "$RESET" "$BOLD$CYAN" "$*" "$RESET"
  printf '%s%s%s%s %3d%%\n' "$GREEN" "${bar// /█}" "$DIM${rest// /░}" "$RESET" "$pct"
}

info() { printf '%s  •%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s  !%s %s\n' "$YELLOW" "$RESET" "$*"; }
fail() { printf '%s  ✗%s %s\n' "$RED" "$RESET" "$1"; FAILED+=("${2:-$1}"); }

ask() {
  local answer
  read -r -p "${YELLOW}  ?${RESET} $1 " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

install_repo() {
  local pkg i=0
  for pkg in "$@"; do
    i=$((i + 1))
    printf '%s  (%d/%d)%s installing %s%s%s\n' "$DIM" "$i" "$#" "$RESET" "$BOLD" "$pkg" "$RESET"
    if sudo pacman -S --needed --noconfirm "$pkg"; then
      ok "$pkg"
    else
      fail "$pkg"
    fi
  done
}

install_aur() {
  local pkg i=0
  for pkg in "$@"; do
    i=$((i + 1))
    printf '%s  (%d/%d)%s installing %s%s%s from AUR\n' "$DIM" "$i" "$#" "$RESET" "$BOLD" "$pkg" "$RESET"
    if "$AUR_HELPER" -S --needed "$pkg"; then
      ok "$pkg"
    else
      fail "$pkg (failed or unavailable in AUR)" "$pkg"
    fi
  done
}

online() {
  if command -v nmcli >/dev/null 2>&1 &&
     [[ "$(nmcli -t networking connectivity check 2>/dev/null)" == full ]]; then
    return 0
  fi
  curl -fsI --max-time 5 https://archlinux.org >/dev/null 2>&1
}

wait_online() {
  local i
  for ((i = 0; i < 15; i++)); do
    online && return 0
    sleep 1
  done
  return 1
}

# Interactive Wi-Fi picker via NetworkManager. Returns 0 once online.
wifi_setup() {
  if ! command -v nmcli >/dev/null 2>&1; then
    warn "nmcli not found. Connect with 'iwctl' or 'nmtui', then rerun this script."
    return 1
  fi
  systemctl is-active --quiet NetworkManager || sudo systemctl enable --now NetworkManager
  nmcli radio wifi on 2>/dev/null

  local attempt=0 choice ssid sec sig pw i
  local -a ssids secs sigs
  local -A seen
  # Only failed connections count; rescans and typos do not.
  while ((attempt < 3)); do
    info "Scanning for Wi-Fi networks..."
    ssids=() secs=() sigs=() seen=()
    # SSID last so names containing ':' survive the split; strongest first, deduped.
    while IFS=: read -r sig sec ssid; do
      [[ -z "$ssid" ]] && continue
      [[ -n "${seen[$ssid]-}" ]] && continue
      seen[$ssid]=1
      ssids+=("$ssid") secs+=("$sec") sigs+=("$sig")
    done < <(nmcli -e no -t -f SIGNAL,SECURITY,SSID device wifi list --rescan yes 2>/dev/null | sort -t: -k1,1nr)

    if ((${#ssids[@]} == 0)); then
      warn "No networks found."
    else
      for i in "${!ssids[@]}"; do
        printf '  %s%2d)%s %-32s %s%3s%%%s  %s\n' "$BOLD" $((i + 1)) "$RESET" "${ssids[i]}" \
          "$GREEN" "${sigs[i]}" "$RESET" "${secs[i]:-open}"
      done
    fi
    printf '  %s h)%s hidden network   %s r)%s rescan   %s q)%s quit\n' \
      "$BOLD" "$RESET" "$BOLD" "$RESET" "$BOLD" "$RESET"
    read -r -p "${YELLOW}  ?${RESET} Network: " choice || return 1

    case "$choice" in
      q) return 1 ;;
      r) continue ;;
      h)
        read -r -p "${YELLOW}  ?${RESET} SSID: " ssid || return 1
        sec=hidden
        ;;
      *)
        if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#ssids[@]})); then
          ssid="${ssids[choice - 1]}" sec="${secs[choice - 1]}"
        else
          warn "Invalid choice"
          continue
        fi
        ;;
    esac

    local -a cmd=(nmcli device wifi connect "$ssid")
    [[ "$sec" == hidden ]] && cmd+=(hidden yes)
    if [[ -n "$sec" && "$sec" != "--" ]]; then
      # Blank password = use a saved profile for this network.
      read -r -s -p "${YELLOW}  ?${RESET} Password for $ssid (blank if saved): " pw
      echo
      [[ -n "$pw" ]] && cmd+=(password "$pw")
    fi

    info "Connecting to $ssid..."
    if "${cmd[@]}" >/dev/null && wait_online; then
      ok "Connected to $ssid"
      return 0
    fi
    attempt=$((attempt + 1))
    warn "Could not connect to $ssid (attempt $attempt/3)"
  done
  return 1
}

if [[ ! -f /etc/arch-release ]]; then
  echo "${RED}This script is intended for CachyOS/Arch Linux.${RESET}"
  exit 1
fi

if [[ $EUID -eq 0 ]]; then
  echo "${RED}Run this script as your normal user, not with sudo.${RESET}"
  exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
  echo "${RED}sudo is required.${RESET}"
  exit 1
fi

printf '%s%slazysetup%s — CachyOS laptop bootstrap\n' "$BOLD" "$CYAN" "$RESET"
info "Log file: $LOG"
info "$TOTAL_STEPS steps. This can install large packages and update your system."
ask "Continue? [y/N]" || exit 0

step "Network connection"
if online; then
  ok "Online"
else
  warn "No internet connection. Let's get on Wi-Fi first."
  wifi_setup || {
    echo "${RED}No internet connection. Connect, then rerun this script.${RESET}"
    exit 1
  }
fi

step "Update system"
sudo pacman -Syu || {
  echo "${RED}System update failed. Resolve that before continuing.${RESET}"
  exit 1
}

step "Development essentials and shell"
install_repo \
  base-devel git curl wget unzip zip p7zip \
  openssh github-cli \
  zsh neovim fastfetch \
  tk nodejs npm python python-pip \
  ripgrep fd fzf wl-clipboard xclip \
  flatpak

step "Wine and Windows compatibility"
install_repo wine wine-mono wine-gecko winetricks

step "Virtualization: QEMU and libvirt"
install_repo \
  qemu-desktop virt-manager virt-viewer \
  dnsmasq vde2 edk2-ovmf swtpm

step "HP printing support"
install_repo \
  hplip cups system-config-printer \
  print-manager avahi usbutils

step "Graphics, gaming and desktop apps"
install_repo krita prismlauncher ollama intel-npu-driver

step "Enable Flatpak and Flathub"
if sudo flatpak remote-add --system --if-not-exists flathub \
  https://flathub.org/repo/flathub.flatpakrepo; then
  ok "Flathub configured"
else
  fail "Flathub setup" flathub-setup
fi

step "Install Bottles and ZapZap from Flathub"
for app in com.usebottles.bottles com.rtosta.zapzap; do
  if flatpak install --system --noninteractive flathub "$app"; then
    ok "$app"
  else
    fail "$app"
  fi
done

step "Enable services"
for svc in sshd cups avahi-daemon libvirtd; do
  if sudo systemctl enable --now "$svc.service"; then
    ok "$svc"
  else
    fail "$svc service" "$svc-service"
  fi
done

step "Add current user to virtualization group"
if getent group libvirt >/dev/null && sudo usermod -aG libvirt "$USER"; then
  ok "$USER added to libvirt"
else
  warn "libvirt group not available; skipped"
fi

step "ASUS webcam enhancer (camfix)"
# Vivobook FHD webcam (Sonix 3277:0018): camfix reads the raw camera and serves
# a face-exposed, BT.709-corrected "ASUS Webcam (Enhanced)" virtual camera.
# python-opencv/python-numpy are not in a stock CachyOS install.
if lsusb -d 3277:0018 >/dev/null 2>&1; then
  read -r -p "${YELLOW}  ?${RESET} Install camfix and make the enhanced webcam the default? [Y/n] " answer
  if [[ ! "$answer" =~ ^[Nn]$ ]]; then
    install_repo python-opencv python-numpy ffmpeg v4l-utils
    modinfo v4l2loopback >/dev/null 2>&1 || install_repo v4l2loopback-dkms

    mkdir -p "$HOME/.local/share/camfix" "$HOME/.config/wireplumber/wireplumber.conf.d"
    install -m 755 "$SCRIPT_DIR/camfix/camfix.py" "$HOME/.local/share/camfix/camfix.py"
    install -m 644 "$SCRIPT_DIR/camfix/50-camfix.conf" "$HOME/.config/wireplumber/wireplumber.conf.d/"

    getent group camraw >/dev/null || sudo groupadd -r camraw
    sudo install -m 644 "$SCRIPT_DIR/camfix/v4l2loopback.conf" /etc/modprobe.d/camfix.conf
    echo v4l2loopback | sudo tee /etc/modules-load.d/camfix.conf >/dev/null
    sudo install -m 644 "$SCRIPT_DIR/camfix/99-asus-webcam.rules" "$SCRIPT_DIR/camfix/71-camfix-hide.rules" /etc/udev/rules.d/
    sed -e "s#@USER@#$USER#" -e "s#@HOME@#$HOME#" "$SCRIPT_DIR/camfix/camfix.service" |
      sudo tee /etc/systemd/system/camfix.service >/dev/null

    if sudo modprobe v4l2loopback &&
       sudo systemctl daemon-reload &&
       sudo systemctl enable --now camfix.service; then
      sudo udevadm control --reload
      sudo udevadm trigger --subsystem-match=video4linux --subsystem-match=media
      # Drop the seat ACL the user already holds on the raw camera nodes.
      for dev in /dev/video* /dev/media*; do
        udevadm info -q property "$dev" 2>/dev/null | grep -q '^ID_VENDOR_ID=3277' &&
          sudo setfacl -b "$dev"
      done
      systemctl --user restart wireplumber 2>/dev/null || true
      ok "camfix installed: pick 'ASUS Webcam (Enhanced)' if an app doesn't default to it"
    else
      fail "camfix service" camfix
    fi
  else
    warn "camfix skipped"
  fi
else
  info "ASUS FHD webcam not found. Skipping camfix."
fi

step "Install or locate AUR helper"
if command -v paru >/dev/null 2>&1; then
  AUR_HELPER=paru
elif command -v yay >/dev/null 2>&1; then
  AUR_HELPER=yay
else
  info "Building paru from the AUR"
  tmpdir="$(mktemp -d)"
  if git clone https://aur.archlinux.org/paru.git "$tmpdir/paru"; then
    (
      cd "$tmpdir/paru"
      makepkg -si
    ) || fail "paru build" paru-bootstrap
  else
    fail "paru clone" paru-clone
  fi
  rm -rf "$tmpdir"
  command -v paru >/dev/null 2>&1 && AUR_HELPER=paru
fi
if [[ -n "${AUR_HELPER:-}" ]]; then
  ok "Using $AUR_HELPER"
fi

step "Install AUR applications"
if [[ -n "${AUR_HELPER:-}" ]]; then
  install_aur "${AUR_PACKAGES[@]}"
else
  fail "No AUR helper available; skipped AUR packages" aur-packages-skipped
fi

step "Zsh configuration (bundled manjaro-zsh-config)"
# manjaro-zsh-config was removed from the AUR. zsh/manjaro-zsh-config.zip is a
# snapshot of github.com/RishonDev/manjaro-zsh-config; its install.sh builds
# the font, powerlevel10k theme and config from their PKGBUILDs, in order.
install_repo \
  zsh-autosuggestions zsh-syntax-highlighting \
  zsh-history-substring-search pkgfile
if pacman -Q manjaro-zsh-config >/dev/null 2>&1; then
  ok "manjaro-zsh-config package already installed"
else
  tmpdir="$(mktemp -d)"
  if bsdtar -xf "$SCRIPT_DIR/zsh/manjaro-zsh-config.zip" -C "$tmpdir" &&
     bash "$tmpdir/install.sh"; then
    ok "manjaro-zsh-config installed"
  else
    fail "manjaro-zsh-config installer" zsh-config
  fi
  rm -rf "$tmpdir"
fi
if [[ -e "$HOME/.zshrc" ]] && ! cmp -s "$SCRIPT_DIR/zsh/.zshrc" "$HOME/.zshrc"; then
  backup="$HOME/.zshrc.backup-$(date +%F-%H%M%S)"
  cp "$HOME/.zshrc" "$backup" && info "Existing ~/.zshrc backed up to $backup"
fi
install -m 644 "$SCRIPT_DIR/zsh/.zshrc" "$HOME/.zshrc" && ok "Installed bundled ~/.zshrc"

step "Install Claude Code"
if command -v claude >/dev/null 2>&1; then
  ok "Claude Code already installed"
else
  tmpfile="$(mktemp)"
  if curl -fsSL https://claude.ai/install.sh -o "$tmpfile" &&
     bash "$tmpfile"; then
    ok "Claude Code installed"
  else
    fail "Claude Code installation" claude-code
  fi
  rm -f "$tmpfile"
fi

step "Install OpenAI Codex CLI"
if command -v codex >/dev/null 2>&1; then
  ok "Codex already installed"
elif sudo pacman -S --needed --noconfirm npm &&
     sudo npm install -g @openai/codex; then
  ok "Codex CLI installed"
else
  fail "Codex installation" codex-cli
fi

step "Gemini CLI, agent skills and REA"
install_repo gemini-cli
if bash "$SCRIPT_DIR/agents/install.sh"; then
  ok "Agent skills ready for Claude Code, Codex and Gemini CLI"
else
  fail "Agent skills / REA (see above)" agent-skills
fi

step "LazyVim setup"
if [[ -d "$HOME/.config/nvim" ]]; then
  backup="$HOME/.config/nvim.backup-$(date +%F-%H%M%S)"
  warn "Existing Neovim config found"
  if ask "Back it up and install LazyVim? [y/N]"; then
    mv "$HOME/.config/nvim" "$backup"
    [[ ! -d "$HOME/.local/share/nvim" ]] ||
      mv "$HOME/.local/share/nvim" "$backup-data"
    if git clone https://github.com/LazyVim/starter "$HOME/.config/nvim"; then
      rm -rf "$HOME/.config/nvim/.git"
      ok "LazyVim installed"
    else
      fail "LazyVim clone" lazyvim
    fi
    info "Config backup: $backup"
  else
    info "Skipping LazyVim to preserve your configuration"
  fi
elif git clone https://github.com/LazyVim/starter "$HOME/.config/nvim"; then
  rm -rf "$HOME/.config/nvim/.git"
  ok "LazyVim installed"
else
  fail "LazyVim clone" lazyvim
fi

step "Ollama service"
if ask "Enable Ollama on boot and start it now? [y/N]"; then
  if sudo systemctl enable --now ollama.service; then
    ok "Ollama enabled"
  else
    fail "Ollama service" ollama-service
  fi
else
  info "Ollama left disabled"
fi

step "Final report"
total=$((SECONDS - START_TIME))
printf '  Finished in %dm %02ds\n' $((total / 60)) $((total % 60))
if ((${#FAILED[@]})); then
  printf '%s  %d item(s) failed or need manual attention:%s\n' "$RED" "${#FAILED[@]}" "$RESET"
  printf "${RED}   - %s${RESET}\n" "${FAILED[@]}"
  info "Check the log: $LOG"
else
  printf '%s  All requested installation steps completed.%s\n' "$GREEN" "$RESET"
fi

echo
printf '%sNext steps:%s\n' "$BOLD" "$RESET"
echo "1. Reboot or log out and back in."
echo "2. Run 'hp-setup -u' to configure your HP printer."
echo "3. Open JetBrains Toolbox and install your IDEs."
echo "4. Open Android Studio to download the Android SDK."
echo "5. Run 'ollama pull <model>' to download an AI model."
echo "6. Check Intel NPU compatibility for your CPU and kernel."
echo "7. Authenticate Claude Code and Codex when prompted."
echo
info "Log saved to: $LOG"
