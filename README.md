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
- Gemini CLI, plus agent skills for Claude Code, Codex and Gemini CLI via
  `agents/install.sh` (both scripts): taste-skill (+ classics), imagegen-skills
  (image-to-code), Vercel web-design-guidelines, awesome-design, playwright-cli,
  the `mem` memory skill, and REA (`rea-agents setup`)
- ASUS Vivobook webcam enhancer (camfix), when the ASUS FHD webcam is detected
- Zsh setup from `zsh/manjaro-zsh-config.zip`, a snapshot of
  [RishonDev/manjaro-zsh-config](https://github.com/RishonDev/manjaro-zsh-config)
  (PKGBUILDs + installer), since `manjaro-zsh-config` was removed from the AUR

## camfix (laptop)

The Vivobook X1607CA webcam looks noticeably worse on Linux than on Windows,
where Microsoft's camera pipeline does face-based exposure and the Realtek
extension tags the stream as BT.709. `camfix/` reproduces that:

- `camfix.py` reads the raw camera and serves "ASUS Webcam (Enhanced)" on
  `/dev/video10` (v4l2loopback): BT.709 colour fix, face-based exposure,
  portrait fill light, local contrast. The raw camera is only opened while an
  app is using the virtual one.
- `99-asus-webcam.rules` sets hardware tuning (backlight compensation, gamma,
  locked 30 fps).
- `71-camfix-hide.rules` and `50-camfix.conf` hide the raw camera and IR sensor
  from apps so the enhanced camera is the default.

Tune with flags in `/etc/systemd/system/camfix.service`, e.g.
`--target 145 --light 0.3`. Logs: `journalctl -u camfix`.

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
