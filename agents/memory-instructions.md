
## Memory

A hierarchical memory system lives at `~/.claude/memory/`, shared by Claude Code,
Codex and Gemini CLI. The `mem` skill describes how to use it.

**Session start:** run `mem load` in the background to load context.
**During session:** run `mem save <observation>` in the background when you learn something worth keeping.
**When stuck:** run `mem recall <query>` to retrieve relevant past learnings.

Memory structure: `core.md` (summaries + pointers) → `topics/<topic>.md` (details)
