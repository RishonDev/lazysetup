
#!/usr/bin/env bash
# CachyOS desktop setup
# Ryzen 7 9700X + Radeon RX 9060 XT
#
# Run as your normal user:
# chmod +x cachyos-desktop-setup.sh
# ./cachyos-desktop-setup.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOG="$HOME/cachyos-desktop-setup-$(date +%F-%H%M%S).log"
FAILED=()
SKIPPED=()

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

# Progress counts the `section` calls at column 0 of this file.
TOTAL_STEPS=$(grep -c '^section ' "${BASH_SOURCE[0]}")
STEP=0
START_TIME=$SECONDS
STEP_START=$SECONDS

section() {
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

ok() {
    printf '%s  ✓%s %s\n' "$GREEN" "$RESET" "$*"
}

fail() {
    FAILED+=("$*")
    printf '%s  ✗ FAILED:%s %s\n' "$RED" "$RESET" "$*"
}

skip() {
    SKIPPED+=("$*")
    printf '%s  ! SKIPPED:%s %s\n' "$YELLOW" "$RESET" "$*"
}

PROMPT="${YELLOW}  ?${RESET}"

if [[ $EUID -eq 0 ]]; then
    echo "Run as your normal user, NOT with sudo."
    exit 1
fi

if [[ ! -f /etc/arch-release ]]; then
    echo "This script requires CachyOS or another Arch-based system."
    exit 1
fi

for cmd in sudo pacman; do
    command -v "$cmd" >/dev/null || {
        echo "Required command missing: $cmd"
        exit 1
    }
done

printf '%s%slazysetup%s — CachyOS desktop bootstrap\n' "$BOLD" "$CYAN" "$RESET"
echo "Log: $LOG"
echo "$TOTAL_STEPS steps. This will update the system and install software."
echo "${YELLOW}ROCm and Android Studio can require substantial downloads.${RESET}"
read -r -p "$PROMPT Continue? [y/N] " answer
[[ "$answer" =~ ^[Yy]$ ]] || exit 0

section "Update system"
sudo pacman -Syu || {
    echo "${RED}System update failed. Resolve it before continuing.${RESET}"
    exit 1
}

# Install available official-repository packages in one transaction.
install_repo() {
    local available=()
    local pkg

    for pkg in "$@"; do
        if pacman -Si "$pkg" >/dev/null 2>&1; then
            available+=("$pkg")
        else
            skip "Repository package unavailable: $pkg"
        fi
    done

    if ((${#available[@]})); then
        printf '%s  installing %d packages:%s %s\n' "$DIM" "${#available[@]}" "$RESET" "${available[*]}"
        if sudo pacman -S --needed "${available[@]}"; then
            ok "${#available[@]} packages installed or already present"
        else
            fail "Repository package batch: ${available[*]}"
        fi
    fi
}

section "Development tools and utilities"
install_repo \
    base-devel git github-cli openssh \
    curl wget rsync unzip zip p7zip \
    neovim zsh fastfetch tk \
    python python-pip nodejs npm \
    ripgrep fd fzf \
    wl-clipboard xclip \
    flatpak man-db man-pages \
    htop btop lsof tree jq \
    usbutils pciutils

section "AMD graphics and ROCm compute"
# Normal graphics: kernel amdgpu + Mesa.
# ROCm: GPU compute libraries and diagnostic tools.
install_repo \
    mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon \
    libva-mesa-driver mesa-vdpau \
    rocm-core rocm-hip-runtime hip-runtime-amd \
    rocminfo rocm-smi-lib \
    hipblas miopen-hip

section "Wine and compatibility"
install_repo \
    wine wine-mono wine-gecko winetricks \
    gamemode lib32-gamemode

section "QEMU / KVM virtualization"
install_repo \
    qemu-desktop virt-manager virt-viewer \
    libvirt dnsmasq vde2 edk2-ovmf swtpm

section "HP printer support"
install_repo \
    hplip cups system-config-printer \
    avahi nss-mdns

section "Gaming, graphics and local AI"
install_repo krita prismlauncher ollama

section "Configure Flatpak and Flathub"
if flatpak remote-add --user --if-not-exists flathub \
    https://flathub.org/repo/flathub.flatpakrepo; then
    ok "Flathub configured for this user."
else
    fail "Flathub configuration"
fi

install_flatpak() {
    local app="$1"
    if flatpak install --user --noninteractive flathub "$app"; then
        ok "Installed Flatpak: $app"
    else
        fail "Flatpak $app"
    fi
}

section "Install Bottles and ZapZap"
install_flatpak com.usebottles.bottles
install_flatpak com.rtosta.zapzap

section "Enable system services"
for svc in sshd cups libvirtd; do
    if systemctl list-unit-files "${svc}.service" --no-legend |
        grep -q "${svc}.service"; then
        sudo systemctl enable --now "${svc}.service" ||
            fail "Service $svc"
    else
        skip "Service not found: $svc"
    fi
done

section "Virtualization group permissions"
for group in libvirt kvm; do
    if getent group "$group" >/dev/null; then
        sudo usermod -aG "$group" "$USER" ||
            fail "Adding user to $group"
    fi
done

section "AUR helper"
if command -v paru >/dev/null 2>&1; then
    AUR=paru
elif command -v yay >/dev/null 2>&1; then
    AUR=yay
else
    AUR=""
    echo "No AUR helper found."
    read -r -p "$PROMPT Build paru from its official AUR recipe? [y/N] " answer

    if [[ "$answer" =~ ^[Yy]$ ]]; then
        tmp="$(mktemp -d)"
        if git clone https://aur.archlinux.org/paru.git "$tmp/paru"; then
            (
                cd "$tmp/paru"
                makepkg -si
            ) || fail "Building paru"
        else
            fail "Downloading paru recipe"
        fi
        rm -rf "$tmp"

        if command -v paru >/dev/null 2>&1; then
            AUR=paru
        fi
    fi
fi

section "AUR applications"
if [[ -n "$AUR" ]]; then
    for pkg in jetbrains-toolbox android-studio; do
        if "$AUR" -S --needed "$pkg"; then
            ok "Installed or already present: $pkg"
        else
            fail "AUR package $pkg"
        fi
    done
else
    skip "AUR applications; install paru/yay and retry manually"
fi

section "Zsh configuration (bundled manjaro-zsh-config)"
# manjaro-zsh-config was removed from the AUR. zsh/manjaro-zsh-config.zip is a
# snapshot of github.com/RishonDev/manjaro-zsh-config; its install.sh builds
# the font, powerlevel10k theme and config from their PKGBUILDs, in order.
install_repo \
    zsh-autosuggestions zsh-syntax-highlighting \
    zsh-history-substring-search pkgfile
if pacman -Q manjaro-zsh-config >/dev/null 2>&1; then
    ok "manjaro-zsh-config package already installed"
else
    tmp="$(mktemp -d)"
    if bsdtar -xf "$SCRIPT_DIR/zsh/manjaro-zsh-config.zip" -C "$tmp" &&
        bash "$tmp/install.sh"; then
        ok "manjaro-zsh-config installed"
    else
        fail "manjaro-zsh-config installer"
    fi
    rm -rf "$tmp"
fi
if [[ ! -e "$HOME/.zshrc" ]]; then
    cp /etc/skel/.zshrc "$HOME/.zshrc" && ok "Created ~/.zshrc"
fi

section "Claude Code"
if command -v claude >/dev/null 2>&1; then
    ok "Claude Code already installed."
else
    tmp="$(mktemp)"
    if curl -fsSL https://claude.ai/install.sh -o "$tmp"; then
        bash "$tmp" || fail "Claude Code installer"
    else
        fail "Downloading Claude Code installer"
    fi
    rm -f "$tmp"
fi

section "OpenAI Codex CLI"
if command -v codex >/dev/null 2>&1; then
    ok "Codex already installed."
else
    npm install --global @openai/codex || fail "Codex CLI"
fi

section "Gemini CLI, agent skills and REA"
install_repo gemini-cli
if bash "$SCRIPT_DIR/agents/install.sh"; then
    ok "Agent skills ready for Claude Code, Codex and Gemini CLI"
else
    fail "Agent skills / REA (see above)"
fi

section "LazyVim"
if [[ -d "$HOME/.config/nvim" ]]; then
    echo "Existing Neovim configuration found."
    read -r -p "$PROMPT Back it up and replace it with LazyVim starter? [y/N] " answer

    if [[ "$answer" =~ ^[Yy]$ ]]; then
        backup="$HOME/nvim-backup-$(date +%F-%H%M%S)"
        mkdir -p "$backup"
        mv "$HOME/.config/nvim" "$backup/nvim"
        for item in "$HOME/.local/share/nvim" \
                    "$HOME/.local/state/nvim" \
                    "$HOME/.cache/nvim"; do
            if [[ -e "$item" ]]; then
                mv "$item" "$backup/"
            fi
        done

        git clone https://github.com/LazyVim/starter \
            "$HOME/.config/nvim" &&
            rm -rf "$HOME/.config/nvim/.git" ||
            fail "LazyVim starter"
        echo "Backup saved at: $backup"
    else
        skip "LazyVim; existing config preserved"
    fi
else
    git clone https://github.com/LazyVim/starter \
        "$HOME/.config/nvim" &&
        rm -rf "$HOME/.config/nvim/.git" ||
        fail "LazyVim starter"
fi

section "Ollama service"
read -r -p "$PROMPT Enable Ollama at boot and start it now? [y/N] " answer
if [[ "$answer" =~ ^[Yy]$ ]]; then
    sudo systemctl enable --now ollama.service ||
        fail "Ollama service"
fi

section "Hardware and ROCm diagnostics"
echo "GPU:"
lspci | grep -Ei 'VGA|3D|Display' || true

echo
echo "Kernel:"
uname -r

echo
if command -v rocminfo >/dev/null 2>&1; then
    rocminfo 2>&1 | grep -Ei 'Name:.*gfx|Marketing Name|Agent' |
        head -30 || true
else
    echo "rocminfo not installed; check package availability."
fi

echo
echo "Verify GPU access:"
ls -l /dev/kfd /dev/dri/renderD* 2>/dev/null || true

section "Finish"
total=$((SECONDS - START_TIME))
printf '  Finished in %dm %02ds\n' $((total / 60)) $((total % 60))
echo "Log saved to: $LOG"

if ((${#FAILED[@]})); then
    echo
    echo "${RED}Failed steps:${RESET}"
    printf "${RED} - %s${RESET}\n" "${FAILED[@]}"
fi

if ((${#SKIPPED[@]})); then
    echo
    echo "${YELLOW}Skipped or unavailable:${RESET}"
    printf "${YELLOW} - %s${RESET}\n" "${SKIPPED[@]}"
fi

if ((${#FAILED[@]} == 0)); then
    echo
    echo "${GREEN}All steps completed.${RESET}"
fi

cat <<'EOF'

Manual follow-up:
1. Reboot after installation.
2. Check ROCm with: rocminfo
3. Check Ollama with: ollama list
4. Configure your HP printer with: hp-setup
5. Open Android Studio and install its SDK/emulator components.
6. Authenticate Claude Code and Codex when prompted.
7. Test QEMU/virt-manager after logging in again.
8. Check printer and VM functionality before relying on them.
EOF
