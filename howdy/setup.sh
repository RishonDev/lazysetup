#!/usr/bin/env bash
# Face unlock with howdy (Howdy 3 / howdy-git, native pam_howdy.so) for sudo
# and the KDE lock screen. Adapted from
# https://gist.github.com/pastleo/76597c6ae8f95bb02982fea6df3a3ade and the Arch
# Wiki Howdy page. The login screen is left alone (SDDM-style greeters freeze on
# a failed attempt and KWallet would no longer unlock at login). Safe to rerun.

set -u
CONFIG=/etc/howdy/config.ini
PAM_LINE="auth       sufficient                  pam_howdy.so"
FAILED=()

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RESET=$'\033[0m' RED=$'\033[1;31m' GREEN=$'\033[1;32m' YELLOW=$'\033[1;33m' BLUE=$'\033[1;34m'
else
  RESET='' RED='' GREEN='' YELLOW='' BLUE=''
fi
info() { printf '%s  •%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$GREEN" "$RESET" "$*"; }
fail() { printf '%s  ✗%s %s\n' "$RED" "$RESET" "$*"; FAILED+=("$*"); }

if [[ ! -f /usr/lib/security/pam_howdy.so ]] || ! sudo test -f "$CONFIG"; then
  fail "howdy-git is not installed (pam_howdy.so or $CONFIG missing); PAM left untouched"
  exit 1
fi

# The IR sensor is the capture device that only offers greyscale frames.
# by-path names survive reboots and replugging, unlike /dev/videoN.
ir_device=""
for dev in /dev/v4l/by-path/*-video-index0; do
  [[ -e "$dev" ]] || continue
  formats="$(sudo v4l2-ctl -d "$dev" --list-formats 2>/dev/null)"
  if grep -q "'GREY'" <<<"$formats" && ! grep -qE "'(MJPG|YUYV)'" <<<"$formats"; then
    ir_device="$dev"
    break
  fi
done
if [[ -z "$ir_device" ]]; then
  fail "No IR camera found; howdy needs one"
  exit 1
fi
ok "IR camera: $ir_device"

info "Configuring $CONFIG"
if sudo sed -i -E \
  -e "s|^(device_path[[:space:]]*=).*|\1 $ir_device|" \
  -e "s|^(detection_notice[[:space:]]*=).*|\1 true|" \
  -e "s|^(certainty[[:space:]]*=).*|\1 4.5|" \
  -e "s|^(dark_threshold[[:space:]]*=).*|\1 100|" \
  -e "s|^(save_failed[[:space:]]*=).*|\1 false|" \
  -e "s|^(save_successful[[:space:]]*=).*|\1 false|" \
  "$CONFIG"; then
  ok "device_path, detection_notice, certainty 4.5, dark_threshold 100, snapshots off"
else
  fail "Editing $CONFIG"
fi

# sudo: face first, password (system-auth) as the fallback.
if sudo grep -q pam_howdy /etc/pam.d/sudo; then
  ok "sudo already uses howdy"
elif sudo sed -i "0,/^auth[[:space:]]\+include[[:space:]]\+system-auth/s//$PAM_LINE\n&/" /etc/pam.d/sudo &&
     sudo grep -q pam_howdy /etc/pam.d/sudo; then
  ok "sudo: face unlock enabled"
else
  fail "Adding howdy to /etc/pam.d/sudo"
fi

# KDE lock screen: kscreenlocker ships /usr/lib/pam.d/kde; /etc/pam.d/kde overrides it.
kde_base=/etc/pam.d/kde
[[ -f "$kde_base" ]] || kde_base=/usr/lib/pam.d/kde
if [[ ! -f "$kde_base" ]]; then
  info "KDE lock screen PAM file not found; skipped"
elif grep -q pam_howdy "$kde_base"; then
  ok "KDE lock screen already uses howdy"
elif { echo '#%PAM-1.0'; echo "$PAM_LINE"; grep -v '^#%PAM-1.0' "$kde_base"; } |
     sudo tee /etc/pam.d/kde.new >/dev/null && sudo mv /etc/pam.d/kde.new /etc/pam.d/kde; then
  ok "KDE lock screen: face unlock enabled (leave the password empty and press Enter)"
else
  fail "Writing /etc/pam.d/kde"
fi

# The lock screen authenticates as the user, so howdy's files must be readable.
sudo chmod -R a+rX /etc/howdy /usr/lib/howdy 2>/dev/null &&
  ok "howdy files readable by the lock screen" || fail "chmod howdy files"

# Silence OpenCV/GStreamer warnings (Plasma Wayland reads environment.d, not ~/.xprofile).
mkdir -p "$HOME/.config/environment.d"
echo 'OPENCV_LOG_LEVEL=ERROR' >"$HOME/.config/environment.d/howdy.conf" &&
  ok "OPENCV_LOG_LEVEL=ERROR set for your session"

read -r -p "${YELLOW}  ?${RESET} Register your face now with 'sudo howdy add'? [Y/n] " answer
if [[ ! "$answer" =~ ^[Nn]$ ]]; then
  sudo howdy add || fail "howdy add (run 'sudo howdy add' later)"
else
  info "Run 'sudo howdy add' later to register your face"
fi

if ((${#FAILED[@]})); then
  printf '%s  Howdy: %d item(s) failed:%s\n' "$RED" "${#FAILED[@]}" "$RESET"
  printf '   - %s\n' "${FAILED[@]}"
  exit 1
fi
ok "Face unlock ready for sudo and the lock screen (log out and back in once)"
