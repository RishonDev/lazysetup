# lazysetup

Post-install setup script for CachyOS/Arch Linux.

## What it does

`lazysetup.sh` automates a full workstation bootstrap, including:

- System update (`pacman -Syu`)
- Development tools and shell setup
- Wine + winetricks
- QEMU/libvirt virtualization stack
- HP printing stack
- Flatpak + Flathub apps (Bottles and ZapZap)
- AUR app install with `paru`/`yay` fallback
- Claude Code and OpenAI Codex CLI install
- Optional LazyVim replacement flow
- Optional Ollama service enablement

## Usage

```bash
chmod +x lazysetup.sh
./lazysetup.sh
```

## Notes

- Run as a normal user (not root).
- The script uses `sudo` when required.
- It is intended for CachyOS/Arch Linux (`/etc/arch-release` check).
- A timestamped log is written to `$HOME/cachyos-setup-YYYY-MM-DD-HHMMSS.log`.
