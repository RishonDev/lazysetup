
#!/usr/bin/env bash
# CachyOS desktop setup
# Ryzen 7 9700X + Radeon RX 9060 XT
#
# Run as your normal user:
# chmod +x cachyos-desktop-setup.sh
# ./cachyos-desktop-setup.sh

set -uo pipefail

LOG="$HOME/cachyos-desktop-setup-$(date +%F-%H%M%S).log"
FAILED=()
SKIPPED=()

exec > >(tee -a "$LOG") 2>&1

section() {
    printf '\n\033[1;36m==> %s\033[0m\n' "$*"
}

fail() {
    FAILED+=("$*")
    printf 'FAILED: %s\n' "$*"
}

skip() {
    SKIPPED+=("$*")
    printf 'SKIPPED: %s\n' "$*"
}

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

echo "Log: $LOG"
echo "This will update the system and install software."
echo "ROCm and Android Studio can require substantial downloads."
read -r -p "Continue? [y/N] " answer
[[ "$answer" =~ ^[Yy]$ ]] || exit 0

section "Update system"
sudo pacman -Syu || {
    echo "System update failed. Resolve it before continuing."
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
        sudo pacman -S --needed "${available[@]}" ||
            fail "Repository package batch: ${available[*]}"
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
    echo "Flathub configured for this user."
else
    fail "Flathub configuration"
fi

install_flatpak() {
    local app="$1"
    if flatpak install --user --noninteractive flathub "$app"; then
        echo "Installed Flatpak: $app"
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
    read -r -p "Build paru from its official AUR recipe? [y/N] " answer

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
    for pkg in jetbrains-toolbox android-studio manjaro-zsh-config; do
        if "$AUR" -S --needed "$pkg"; then
            echo "Installed or already present: $pkg"
        else
            fail "AUR package $pkg"
        fi
    done
else
    skip "AUR applications; install paru/yay and retry manually"
fi

section "Claude Code"
if command -v claude >/dev/null 2>&1; then
    echo "Claude Code already installed."
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
    echo "Codex already installed."
else
    npm install --global @openai/codex || fail "Codex CLI"
fi

section "LazyVim"
if [[ -d "$HOME/.config/nvim" ]]; then
    echo "Existing Neovim configuration found."
    read -r -p "Back it up and replace it with LazyVim starter? [y/N] " answer

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
read -r -p "Enable Ollama at boot and start it now? [y/N] " answer
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
echo "Log saved to: $LOG"

if ((${#FAILED[@]})); then
    echo
    echo "Failed steps:"
    printf ' - %s\n' "${FAILED[@]}"
fi

if ((${#SKIPPED[@]})); then
    echo
    echo "Skipped or unavailable:"
    printf ' - %s\n' "${SKIPPED[@]}"
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
