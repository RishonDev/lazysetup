#!/usr/bin/env bash
# Install agent skills, the memory skill and REA for Claude Code, Codex and
# Gemini CLI. Called by lazysetup_laptop.sh and lazyvim_desktop.sh; safe to rerun.
#
# Skills install globally through the skills CLI (github.com/vercel-labs/skills):
#   claude-code -> ~/.claude/skills   codex -> ~/.agents/skills   gemini-cli -> ~/.gemini/skills

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS=(claude-code codex gemini-cli)
FAILED=()

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  BOLD=$'\033[1m' RESET=$'\033[0m' RED=$'\033[1;31m' GREEN=$'\033[1;32m'
  YELLOW=$'\033[1;33m' BLUE=$'\033[1;34m'
else
  BOLD='' RESET='' RED='' GREEN='' YELLOW='' BLUE=''
fi

info() { printf '%s  •%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s  !%s %s\n' "$YELLOW" "$RESET" "$*"; }
fail() { printf '%s  ✗%s %s\n' "$RED" "$RESET" "$*"; FAILED+=("$*"); }

# skills_add <github-repo> <skill names... | '*'>
skills_add() {
  local repo="$1"
  shift
  info "Skills from ${BOLD}$repo${RESET}: $*"
  if npx -y skills add "$repo" --global --yes --skill "$@" --agent "${AGENTS[@]}"; then
    ok "$repo"
  else
    fail "skills from $repo"
  fi
}

if ! command -v npx >/dev/null 2>&1; then
  fail "npx not found; install nodejs and npm first"
  exit 1
fi

# taste-skill was split in 2.1.3: image-to-code and the imagegen skills moved
# to imagegen-skills, the classic styles to taste-skill-classics.
skills_add Leonxlnx/taste-skill '*'
skills_add Leonxlnx/taste-skill-classics '*'
skills_add Leonxlnx/imagegen-skills '*'
skills_add vercel-labs/agent-skills web-design-guidelines
skills_add FuturizeRush/awesome-design-skill awesome-design
skills_add microsoft/playwright-cli playwright-cli

info "playwright-cli command"
if command -v playwright-cli >/dev/null 2>&1; then
  ok "playwright-cli already installed"
elif sudo npm install --global @playwright/cli@latest; then
  ok "playwright-cli installed"
else
  fail "playwright-cli (npm install -g @playwright/cli)"
fi

# Memory skill: one shared store at ~/.claude/memory for all three agents.
if [[ -f "$HERE/mem/SKILL.md" ]]; then
  info "Memory skill (mem)"
  for dir in "$HOME/.claude/skills" "$HOME/.agents/skills" "$HOME/.gemini/skills"; do
    # Claude Code may already have it as a /mem command.
    [[ "$dir" == "$HOME/.claude/skills" && -e "$HOME/.claude/commands/mem.md" ]] && continue
    mkdir -p "$dir/mem" && install -m 644 "$HERE/mem/SKILL.md" "$dir/mem/SKILL.md"
  done
  mkdir -p "$HOME/.claude/memory/topics" "$HOME/.claude/memory/projects"
  cp -n "$HERE/memory-template/core.md" "$HERE/memory-template/me.md" "$HOME/.claude/memory/"
  for f in "$HOME/.claude/CLAUDE.md" "$HOME/.codex/AGENTS.md" "$HOME/.gemini/GEMINI.md"; do
    mkdir -p "$(dirname "$f")"
    grep -qs '\.claude/memory' "$f" || cat "$HERE/memory-instructions.md" >>"$f"
  done
  ok "mem skill and ~/.claude/memory ready"
else
  warn "agents/mem/SKILL.md not bundled; skipping memory skill"
fi

# REA's own setup registers the MCP server and its skill per agent. It is an
# interactive picker, so give it the terminal directly rather than the log pipe.
info "REA (reverse engineering MCP server)"
if ! { : </dev/tty; } 2>/dev/null; then
  fail "REA setup needs an interactive terminal (rerun: npx rea-agents@latest setup)"
elif npx -y rea-agents@latest setup </dev/tty >/dev/tty 2>&1; then
  ok "REA setup finished; restart your agents to load it"
else
  fail "REA setup (rerun: npx rea-agents@latest setup)"
fi

if ((${#FAILED[@]})); then
  printf '%s  Agent setup: %d item(s) failed:%s\n' "$RED" "${#FAILED[@]}" "$RESET"
  printf '   - %s\n' "${FAILED[@]}"
  exit 1
fi
ok "Agent skills, memory and REA installed for Claude Code, Codex and Gemini CLI"
