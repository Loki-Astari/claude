# CLAUDE.md

This file provides guidance for AI coding agents (Claude Code, Cursor, etc.) when working with code in this repository.

## Project Overview

This is **AIAgent.nvim**, a Neovim plugin that integrates AI agent CLIs into the editor. It opens an agent CLI in a right-side terminal split with a header showing keybind instructions.

## Development

This is a Neovim plugin with no build step. To apply changes in a running session:
1. Ensure the plugin directory is in your Neovim runtimepath
2. Restart Neovim or run `:lua package.loaded['aiagent'] = nil` followed by `require('aiagent').setup(...)` to reload

All autocmds are registered under the `AIAgent` augroup, so reloading via `setup()` clears and re-registers them cleanly.

## Testing

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)'s busted-compatible runner.

**Run all tests (headless):**
```bash
nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
```

**Override the plenary path** (if not at the default lazy.nvim location):
```bash
PLENARY_DIR=~/.local/share/nvim/lazy/plenary.nvim nvim --headless \
  -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
```

**Run a single spec file:**
```bash
nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedFile tests/aiagent_spec.lua"
```

Test files live in `tests/` and follow the `*_spec.lua` naming convention. The `tests/minimal_init.lua` bootstraps plenary and the plugin runtimepath.

## Architecture

- `plugin/aiagent.lua` - Lua entry point, defines commands (`:AgentOpen`, `:AgentClose`, `:AgentToggle`, `:AgentSendDiagnostics`, `:AgentDiff`, `:AgentChat`, etc.)
- `lua/aiagent/init.lua` - Main Lua module with all plugin logic
- `lua/aiagent/prompthistory.lua` - Prompt-history diff viewer (see [Prompt History](#prompt-history))
- `lua/aiagent/registry.lua` - Cross-instance agent registry and its list viewer (see [Agent Registry](#agent-registry))
- `lua/aiagent/history.lua` - Session history tree popup and node jumping (see [History Tree](#history-tree))
- `lua/aiagent/sessions.lua` - Past-session finder and loader (see [Finding Past Sessions](#finding-past-sessions))
- `lua/aiagent/gitdiff.lua` - Shared git/diff primitives behind every before|after pane
- `lua/aiagent/prreview.lua` - GitHub PR review viewer and submitter (see [PR Review](#pr-review))
- `lua/aiagent/health.lua` - Health check implementation (`:checkhealth aiagent`)
- `hooks/prompt_snapshot.sh` - Claude Code `pre`/`post` hooks that capture per-prompt git tree snapshots
- `hooks/prompt_history_inspect.sh` - Terminal tool to list/dump captured sessions
- `skills/prompt-history/`, `skills/pr-review/` - Bundled Claude skills, installed into `~/.claude/skills/` by `:AgentInstallSkill`
- `doc/aiagent.txt` - Vimdoc help file (`:help aiagent`)

The plugin manages state via module-level variables (`M.agents`, `M.current_agent`, `M.win`, `M.header_buf`, `M.header_win`, `M.prev_win`) and uses autocmds for cleanup on QuitPre/VimLeavePre.

Each agent entry in `M.agents[name]` tracks: `buf`, `job_id`, `scroll_mode`, `scroll_pos`, `agent_type`, `command`, `sent_files`, `color`, `worktree` (path or nil), `git_root` (repo root or nil), `slug` (worktree slug or nil), `task` (explicit label or nil), `started` (epoch seconds).

## Lualine Integration

The following public functions provide lualine.nvim component helpers. All live on the `M` table in `lua/aiagent/init.lua`.

| Function | Returns | Purpose |
|----------|---------|---------|
| `M.lualine_label()` | `string\|nil` | `"Agent: Claude"` or `"Scroll Mode: Claude"` when the agent terminal is focused; `nil` otherwise |
| `M.lualine_color()` | `table\|nil` | `{ bg = '#0891b2' }` (cyan) for input mode, `{ bg = '#7c3aed' }` (purple) for scroll mode; `nil` otherwise |
| `M.lualine_branch()` | `string\|nil` | Actual branch of the agent's worktree (via `git branch --show-current`), or `nil` when not focused on the agent terminal |
| `M.lualine_mcp()` | `string` | Space-separated list of `✓ name` for each connected MCP server |
| `M.lualine_mcp_color()` | `table\|nil` | `{ fg = '#22c55e' }` (green) when results are loaded; grey while pending |
| `M.mcp_refresh()` | — | Clears the MCP cache and triggers an immediate `claude mcp list` refresh |

### MCP status implementation

- `claude mcp list` is run as an async job (`vim.fn.jobstart`) on first use and every 30 seconds thereafter
- Only lines matching `✓ Connected` are kept; `claude.ai` auto-discovered servers are filtered out
- The `claude.ai ` prefix is stripped from display names
- Results are stored in the module-level `_mcp_cache` table (`{ name, connected }` per entry)
- `_mcp_last_read` is set immediately when a refresh starts to prevent concurrent jobs

## LSP Diagnostics

`:AgentSendDiagnostics` collects LSP diagnostics for the current buffer via
`vim.diagnostic.get(bufnr)` and sends a pre-formatted prompt to the active agent.

Key implementation details in `M.send_diagnostics(agent_name, line1, line2)`:

- `line1`/`line2` are optional 1-indexed line numbers (from a visual range); when
  provided, diagnostics outside that range are filtered out before sending.
- Active LSP clients are collected via `vim.lsp.get_clients({ bufnr = bufnr })`.
  `client.config.settings` is preferred for compiler options; `client.config.init_options`
  is used as a fallback.
- Before sending the text, `\x1bi` is sent to the terminal to ensure the agent is
  in insert mode (ESC exits any vim mode, `i` enters insert). This is required when
  the agent uses vim keybindings (e.g. Claude's vim mode).
- The message text does **not** end with `\n` — the text is typed into the prompt
  but not submitted, so the user presses Enter to initiate the analysis.
- The command is registered with `{ range = true }` so it can be invoked as
  `:'<,'>AgentSendDiagnostics` from a visual selection.

## Key Patterns

- Use `pcall` for all window/buffer operations that might fail during cleanup
- Terminal jobs require both `chanclose` and `jobstop` for reliable cleanup
- Window options are set via `nvim_set_option_value` with scope parameters

## Proportional Resize

Unplugging an external monitor shrinks the terminal, and Neovim's own
redistribution leaves the agent column an arbitrary size. `config.auto_resize`
(default on) restores its *share* of the screen instead.

- `M._width_ratio` is the fraction actually in use, not `config.width`: seeded
  from the config when the layout is built, then re-recorded on `WinResized` so
  a split the user dragged wider keeps its new proportion. `VimResized` calls
  `M.resize()`, which re-applies it.
- **`WinResized` must ignore resizes that happen while the screen width is
  changing** — those are Neovim redistributing windows, not the user. Hence
  `M._last_columns`: record only when `vim.o.columns` still matches it.
- `M.resize()` guards its own `nvim_win_set_width` with `applying_resize`,
  released via `vim.schedule` because the `WinResized` it provokes fires after
  the call returns. Without it, rounding feeds back and the ratio drifts on
  every resize.
- `clamp_width()` keeps both the agent column and the rest of the layout at
  `config.min_width`; when the screen is too narrow for both, the floor drops to
  half the screen so the clamp stays satisfiable.
- `hide()` records `M._hidden_columns` alongside the saved width. A resize while
  hidden makes the saved absolute width meaningless, so the restore in
  `create_window_layout` scales it by the screen-width change.
- `close_all` clears the ratio, so a full teardown returns to `config.width`.

## Git Worktree Support

Worktrees are **persistent** — they are not removed when an agent is closed or Neovim exits.

### Naming convention

| Item | Pattern |
|------|---------|
| Branch | `agent/{slug}` |
| Directory | `$TMPDIR/nvim-agent-{repo}-{slug}` (symlinks resolved via `vim.fn.resolve`) |

Where `{slug}` is the `WTName` lowercased with non-alphanumeric characters replaced by `-`. When no `WTName` is given, the agent `Name` is used as the slug source.

### Command syntax

`:AgentOpen [Name [WTName [directory]]]`

- `Name` — agent name (default: `AIAgent`)
- `WTName` — worktree name; `-` is shorthand for using the agent name. The slug (lowercase, non-alphanumeric → `-`) is derived from this and used for the branch and default directory.
- `directory` — explicit directory for a **new** worktree; error if the worktree already exists

### Auto-reconnect logic

Worktrees are found by matching the branch name `agent/{slug}` via `git worktree list --porcelain`. This is more reliable than path comparison (unaffected by symlinks or directory moves).

On `:AgentOpen Name` (no `WTName`), the plugin:
1. Derives a slug from `Name` and calls `git worktree list --porcelain` to scan for a worktree with branch `refs/heads/agent/{slug}`
2. If found, reconnects silently and sets the agent's `cwd` to the worktree path from the porcelain output
3. If not found, opens with the current directory (no worktree)

On `:AgentOpen Name WTName [directory]`:
1. Derives a slug from `WTName` and scans for a worktree with branch `refs/heads/agent/{slug}`
2. If found and no `directory` given, reconnects; if found and `directory` given, errors
3. If not found, creates a new worktree at `vim.fn.expand(directory)` if given, otherwise at `$TMPDIR/nvim-agent-{repo}-{slug}`
4. Handles the edge case where the branch exists but the worktree directory was manually removed (uses `git worktree add <path> <branch>` without `-b`)

### Worktree file redirect

Two autocmds cooperate to redirect file opens to the active agent's worktree:

- **`BufNew`** — fires when a new buffer is created. If the path is inside the git repo but not already in the worktree, the buffer is renamed to the worktree path and tagged with `vim.b[buf].aiagent_name`.
- **`CmdlineLeave` + `BufEnter`** — handles `:e X` when `X` is already open in a non-worktree buffer. `CmdlineLeave` sets a flag when an `:e`/`:edit` command is detected and **clears it** for any other command (including `<Esc>`), so a cancelled `:e` never leaves a stale flag. `BufEnter` only redirects when that flag is set (clears immediately after). This prevents redirect on passive buffer switches (e.g. `<C-\><C-n>`, bufferline clicks).

### Bufferline integration

`M.bufferline_name_formatter(buf)` is a public function for use as bufferline's `name_formatter` option. It reads `vim.b[buf.bufnr].aiagent_name`, looks up `M.agents[name].slug`, and prefixes the filename: `slug: filename`. Returns `nil` (default name) for non-worktree buffers or when the agent has no slug.

### Scroll mode

Press `<C-\><C-s>` in terminal mode to enter scroll mode (normal mode in the terminal buffer).

- **First entry**: cursor jumps to `scroll_start_line` (config option, default `9`), skipping the agent's startup preamble
- **Re-entry**: cursor is restored to `agent.scroll_pos` (saved as a `{ row, col }` copy when exiting scroll mode)

The `scroll_pos` is stored as `{ pos[1], pos[2] }` (an explicit copy), not a reference, to avoid Lua table aliasing bugs with `nvim_win_get_cursor`.

## Prompt History

Captures the code changes produced by each prompt of an agent session and
displays them in a side-by-side diff viewer.

### Capture (`hooks/prompt_snapshot.sh`)

A Claude Code hook wired into user `~/.claude/settings.json`:
`UserPromptSubmit → prompt_snapshot.sh pre`, `Stop → prompt_snapshot.sh post`.

- Records a turn as a pair of git tree SHAs. Trees are built in a **temp index**
  (`read-tree HEAD` + `add -A` excluding `.prompt-history` + `write-tree`), so
  they capture committed + uncommitted + untracked files uniformly, survive
  commits, and never record the history dir itself.
- One JSONL file per session at
  `<repo>/.prompt-history/sessions/<session_id>.jsonl`, anchored on the git
  **common** dir (`git rev-parse --path-format=absolute --git-common-dir`) so all
  worktrees of a repo share one location. Pending turn held in
  `pending-<session>.json`, closed on the next `pre` if interrupted.
- Each record: `session, started, ended, prompt, before_tree, after_tree,
  changed_files, cwd, head, branch`. Zero-change turns are still recorded.
- The hook writes no stdout (it would pollute the prompt context) and always
  exits 0, so capture failures never block a turn.

### Viewer (`lua/aiagent/prompthistory.lua`)

- Opens in a **new tabpage**, leaving the agent terminal in `M.win` untouched.
  Layout: left column (instructions / prompt list / changed-files), right pane
  `before | after` via native `:diffthis`.
- Reconstructs file content with `git show <tree>:<path>` — **never** `git diff`
  for content (a user's external difftool may hijack plain `git diff`; only
  `--no-ext-diff` / `--name-status` / `git show` are safe). `changed_files()`
  parses `git diff --no-ext-diff --name-status -M`.
- `M.state` is `nil` when closed. Opening with no completed turns yet leaves it
  `nil` (nothing to show) — that is expected, not a failure.

### Entry points (`lua/aiagent/init.lua`)

- `current_session()` — resolves the running agent's PID →
  `~/.claude/sessions/<pid>.json` → `{ id, cwd }`.
- `prompt_history_open(session?)` — opens the viewer (default: current session);
  closes any open viewer first to refresh with newly captured prompts.
- `prompt_history_close()` — closes the viewer, back to chat.
- `prompt_history_list(load_context?)` — `vim.ui.select` session picker. Default:
  pick the session to continue capturing into (sets `active-session`). With
  `load_context` true (the `:AgentSessions!` bang): pick a session to load into
  the agent's context instead.
- `prompt_history_load_context(session, agent_name?)` — builds a primer for a
  session (`prompthistory.build_primer`: prompts + per-turn changed files +
  diffs) and **types it into the agent without submitting** (same `\x1bi`
  type-don't-submit path as `send_diagnostics`), so the user reviews and presses
  Enter. A re-orientation aid, not a conversation replay — deliberately not
  "resume" (the assistant side of the conversation is not captured).
- `prompthistory.build_primer(session, dir)` — returns `(text, err)`. Diffs use
  `git diff --no-ext-diff` (the safe form; never plain `git diff`).

Commands `:AgentDiff [session]` / `:AgentChat` / `:AgentSessions[!]` are
registered in `plugin/aiagent.lua`. They can also be driven remotely (e.g. from an agent) via
`nvim --server "$NVIM" --remote-expr "luaeval(\"require('aiagent').prompt_history_open()\")"`.

### Bundled skill (`skills/prompt-history/`, `:AgentInstallSkill`)

A `prompt-history` Claude skill ships in `skills/` so it can be distributed with
the plugin. `M.install_skill({ force, dest })` (command `:AgentInstallSkill[!]`)
copies it into `~/.claude/skills/prompt-history/`:

- The plugin root is resolved from the file's own path via
  `debug.getinfo(1, 'S').source` → `:p:h:h:h` (absolute, then up out of
  `lua/aiagent/`). Exposed for tests as `M._plugin_root`.
- The bundled skill uses a `__AIAGENT_HOOKS_DIR__` placeholder for any hook-path
  reference; the installer substitutes this install's real `<root>/hooks` so the
  inspect-script and hook-setup snippets are copy-pasteable for the target user.
  **When editing the bundled skill, never hard-code an absolute hooks path — use
  the placeholder.**
- Refuses to overwrite an existing skill install unless `force` (the command's
  `!`).
- After copying, offers to wire the capture hooks via `M.install_hooks`
  (`opts.hooks`: `nil` = prompt with `vim.fn.confirm`, `true` = wire silently,
  `false` = skip — tests/headless pass `false`).

`M.install_hooks({ settings })` merges the `UserPromptSubmit`/`Stop` entries
into `~/.claude/settings.json`:

- **Uses `jq`, not a Lua JSON round-trip.** Re-encoding the whole file through
  `vim.fn.json_decode`/`json_encode` would coerce any empty `[]` (e.g.
  `permissions.allow`) into `{}` and corrupt unrelated settings — jq preserves
  the rest of the file and the `[]`/`{}` distinction. Writes a `.bak` first.
- **Idempotent.** An event whose hooks already reference `prompt_snapshot.sh` is
  left untouched; only missing entries are appended. Returns `(changes, wrote)`.
- Does not auto-detect jq absence fatally — if `jq` isn't on PATH it returns a
  change note telling the user to wire manually, rather than failing the skill
  copy.

## Agent Registry

Lists every agent in every running Neovim instance (`:AgentList!`), so a user
with Neovim open in several terminal windows can see what each one is doing and
jump to it.

### Design constraints

- **No IPC and no heartbeat.** Each instance publishes one JSON sidecar per
  agent into `$XDG_STATE_HOME/aiagent/agents/<nvim_pid>-<agent>.json`
  (default `~/.local/state/aiagent/...`, deliberately outside Neovim's own
  state dir so a shell script could read it too). Nothing polls anything.
- **Liveness is verified on read, never trusted from the file.**
  `read_all()` unlinks any sidecar whose `nvim_pid` or `job_pid` is dead
  (`uv.kill(pid, 0)`), and for remote entries also requires the recorded
  `nvim_server` socket to still exist (guards against pid reuse). This is why
  no heartbeat is needed and why a SIGKILLed instance leaves no debris.
- **Anything Claude Code already tracks is read from Claude Code**, merged in at
  read time so it is never stale: `~/.claude/sessions/<job_pid>.json` supplies
  `status` (busy/idle), `statusUpdatedAt`, `sessionId`, `cwd` and Claude's own
  derived `name`. The sidecar carries only what the plugin knows and Claude does
  not (agent name, colour, worktree slug, task label, `v:servername`, terminal
  pane ids).

### Publish points

`M.open` (deferred 200ms, so the job pid and shell cwd have settled),
`M.switch` (keeps the `current` flag accurate), and `M.set_task`. Removal is in
`cleanup_agent`, which covers `:AgentClose`, `:AgentCloseAll` and VimLeavePre.
All publish calls are wrapped in `pcall` — the registry is a convenience and
must never break opening an agent.

### Task label

`entry.label` is `agent.task` when set (`:AgentTask`), else derived from the
session transcript by `registry.last_prompt()`. Two non-obvious details there:

- **Tail reads escalate** (`TAIL_STEPS` = 64KB → 512KB → 4MB). A single turn's
  tool output can run to hundreds of kilobytes, so the newest human prompt is
  often far from EOF — a fixed 64KB tail silently returns nil on busy sessions.
- **`human_text()` filters non-human turns**: entries containing a
  `tool_result` part are rejected outright, and the XML-ish envelopes Claude
  Code injects (`<command-name>`, `<system-reminder>`, `<local-command-stdout>`)
  are stripped before the first non-empty line is taken.

### Focus

`M.focus(entry)` does two independent best-effort steps: `nvim --server
<socket> --remote-expr` to make the owning instance display that agent (the
expression ends in `or 1` because `--remote-expr` errors on a nil result), then
`focus_cmd(entry)` to raise the terminal pane. Detection order is tmux →
iTerm2 → kitty → WezTerm (multiplexer before emulator, since raising the pane
is what actually reveals the agent); `config.focus_cmd` overrides it and may
return nil to fall through. iTerm2 uses `osascript` matching on the GUID half
of `$ITERM_SESSION_ID`, which is iTerm's session `id`.

Both steps go through a local `spawn()` helper rather than `vim.fn.jobstart`
directly: **jobstart raises E475 on a non-executable argv[0]**, which a missing
`tmux`/`kitten`/`wezterm` binary or a hand-written `focus_cmd` easily produces.
`spawn()` checks `executable()` and pcalls, so focusing degrades to a warning.

### Rendering

`M.render(entries)` returns `(lines, highlights)` and is pure, so it is unit
tested without a window. Highlight ranges are **byte** offsets (for extmarks)
while column padding is computed in **display** width — the `▶` marker is three
bytes and one cell, so the two must not be conflated (a test asserts both).

## History Tree

`:AgentTree` / `<C-\><C-t>` shows the current session's transcript as the tree it
actually is, and jumps to any node in it.

### Why there is a tree at all

A Claude Code transcript (`~/.claude/projects/<slug>/<session>.jsonl`) is
append-only JSONL whose entries link by `uuid`/`parentUuid`. `/rewind` does **not**
truncate it — the abandoned turns stay byte-identical and the next prompt is
appended with its `parentUuid` pointing back at the chosen node. One file therefore
holds every branch ever explored in that session.

The active position is a separate entry, and **the last one in the file wins**:

```json
{"type":"last-prompt","lastPrompt":"…","leafUuid":"<uuid>","sessionId":"…"}
```

### Jumping

`M.history_jump(target)` in `init.lua` is the whole mechanism:

1. stop the agent's job (`cleanup_agent`)
2. append a `last-prompt` pointer naming the target entry (`history.set_leaf`)
3. relaunch with `<command> --resume <session>` (`create_agent`'s `cmd_override`)

**Order is not negotiable.** A live session writes its own `last-prompt` at the end
of every turn, so a pointer written underneath a running agent is clobbered — which
is also why the process must restart rather than being repointed in place.

**A pointer is only honoured when it names a LEAF.** Resume picks among the
transcript's leaves; a pointer at a node that still has children is *silently*
ignored and the newest leaf is resumed instead. That is every rewind — so a jump
back up the current path appeared to work and then continued the old conversation
linearly, producing no branch at all. `history.set_leaf` therefore appends a
synthetic anchor entry (a childless `stop_hook_summary` system entry cloned from
the same transcript, so its shape matches the writing version) as a child of the
target and points at that. The target becomes a genuine fork point, the resumed
session reads the path through it, and its new turns hang off the anchor as a real
branch. Anchors are invisible in the tree because only typed prompts are nodes.

One mechanism serves both directions: repointing at an ancestor *is* a rewind, so
on-path and off-path jumps share a code path. `/rewind` is deliberately not used —
it is an interactive dialog with no programmatic entry point, and driving it would
mean sending blind keystrokes into the terminal.

The agent's identity (colour, worktree, git root, slug, task, sent files) is carried
across the restart; only the process changes. `agent.command` is stripped of any
previous `--resume` so repeated jumps do not accumulate flags.

### Forking (`M.history_fork`, `M.fork_here`)

`f` in the tree popup forks a NEW agent from the node under the cursor, leaving the
source agent running. `--fork-session` resumes under a new session id and Claude
Code copies the walked path into the new transcript, rewriting every entry's
`sessionId` — so the fork is a genuinely independent session, not a view into the
source, and the leaf pointer selects which path gets copied.

The one wrinkle: setting the fork point moves the *source's* recorded position,
because the pointer lives in the source transcript. So `history_fork` captures
`history.head()` first and restores it once the fork has started (polling
`~/.claude/sessions/<pid>.json` for the fork's own session id, giving up after
~10s and restoring anyway). The restore is best-effort on purpose — the source's
next turn appends newer entries, and "newest in file order wins" makes any stale
pointer irrelevant.

Unlike a jump, forking from the CURRENT node is meaningful, so `f` has no no-op
case. Sharing the source's tree keeps the inherited context's file paths valid,
while a worktree isolates edits but points that context at the source tree.

The choice is made in `history.menu`, the plugin's own float, and **not** through
`vim.ui.select`/`vim.ui.input`. Both builtins prompt on the cmdline, which is easy
to miss next to a busy agent terminal — the fork read as a dead keybinding, and the
keys typed at the invisible prompt cancelled it. Replacing input with select was no
better: a user's select handler is often a filtering picker (telescope-ui-select
adds a text input above the list, where typing filters instead of choosing and <CR>
on no match cancels silently). A fixed menu with number keys has neither failure
mode. Every cancel path notifies, so an abandoned fork never looks like a no-op.

### Non-obvious details

- **The `last-prompt` pointer is not kept up to date.** A resumed session may never
  write one, so after a jump the newest pointer stays the one the plugin wrote at
  the branch point. `build()` therefore takes whichever is newer in *file order*:
  the pointer when nothing follows it (a jump not yet used), else the last entry in
  the file, which necessarily belongs to the branch in use. `parse()` returns
  `leaf_pos` for exactly this comparison. Trusting the pointer alone marks the
  branch point as "here" and renders the turns just added as an abandoned branch.
- **`parentUuid: null` decodes to `vim.NIL`, which is truthy in Lua.** A plain
  `if parent then` walks off the top of the tree. `parent_of()` normalises it, and
  root entries are keyed under a `ROOT` sentinel because nil cannot be a table key.
- **Nodes are typed prompts only.** `origin.kind == "human"` is authoritative where
  present; older transcripts fall back to the envelope sniffing `registry.human_text()`
  uses. A tree of every assistant and tool message would be unnavigable.
- **A turn's jump target is the end of its reply, not its prompt entry** — selecting
  a turn means "the conversation through the end of this turn".
- **Depth must not indent.** Rendering a linear session with one indent per turn
  walks off the right edge by turn 15. Only forks indent; the active branch always
  continues the trunk, as `git log --graph` does.
- **The token cell counts requests, not entries.** Each row shows tokens *sent*
  answering that prompt: `input + cache_creation + cache_read` summed over the
  turn's API calls (returned tokens are deliberately not shown). The trap is that
  one API response spans several transcript entries — Claude Code writes one per
  content block, `apiBlockIndex`, repeating the *identical* `usage` on each — so
  summing entries inflates the figure ~1.8x (measured: 525 assistant entries, 289
  distinct requests). `sent_tokens()` charges each `requestId` once, falling back
  to `message.id` then the entry uuid. The numbers are exact, not estimated, and
  cost nothing extra: `parse()` already holds the entries and `build()`'s subtree
  walk already visits them.
- **The right-hand block is budgeted at its full width** (`RIGHT_W`), not sized
  from the row's actual string. Sizing from the string right-aligns the block, so
  a turn summarised as `—` shoves the time and token cells 21 columns right. That
  merely looked untidy while the cells were text; a *number* that does not line up
  reads as noise. `show()` caps width at 118 rather than 110 so the token cell
  does not come out of the prompt's budget.
- **Nothing is rolled up.** An earlier version folded long branchless runs into a
  `⋯` row, which made the popup five lines tall on an 18-turn session and hid the
  history the viewer exists to show. Every turn gets a row; the window is sized to
  the content (cap 60 rows, or 80% of `vim.o.lines` when the screen is shorter) and
  scrolls. The cursor opens on the current turn parked at the bottom (`zb`), so
  scrolling up walks into the past.
- `M.render()` is pure and returns `(lines, highlights, rows)` so it is unit tested
  without a window. Highlight columns are **byte** offsets while padding is computed
  in **display** width — and `[●▶]` in a Lua pattern is a *byte* class, not a set of
  two glyphs (a test documents this).
- The transcript is located by globbing `~/.claude/projects/*/<session>.jsonl` rather
  than deriving the slug: session ids are unique, slug escaping is Claude Code's
  business.
- These entry types are undocumented internals. Everything degrades to "no tree
  available" rather than throwing.

## Finding Past Sessions

`:AgentFind` / `<C-\><C-f>` lists every Claude Code session on the machine and
loads a chosen one back into an agent. It exists because closing a terminal
loses the *view* of a conversation, never the conversation — Claude Code keeps
one transcript per session under `~/.claude/projects/` and never deletes them.

### Scanning (`sessions.inspect`, `sessions.scan`)

Each transcript is streamed once, and only lines that can carry what the list
needs are decoded. Two prefilters do the work:

- `"type":"user"` for the prompt count, first prompt and last prompt. Assistant
  and tool entries outnumber prompts by more than 20:1, so decoding everything
  would dominate the scan. `registry._human_text` then rejects the `user`
  entries that are not prompts (tool results, injected envelopes).
- `"ai-title"` for the label. **Claude Code names its own sessions** and appends
  a fresh `{"type":"ai-title","aiTitle":…}` entry as the session goes on, so the
  LAST one wins. This is a far better label than anything derivable.

`cwd` and `gitBranch` are lifted with a string match rather than a decode —
they repeat on nearly every entry, so decoding for them would mean decoding the
whole file. Measured cost: ~50ms for 26 sessions / 14MB.

Sessions with no prompt in them are dropped unless `all`: Claude Code leaves a
stub transcript behind for every start that never got a question, and they
outnumber the real ones. Liveness comes from `registry.read_all({derive=false})`,
so a session still being written to is marked rather than hidden.

### Loading (`M.session_load`)

`--resume <id> --fork-session`, and **no leaf pointer is written**. Two
properties follow, both deliberate:

- The archive is never mutated, so it can be loaded repeatedly, and into two
  agents at once.
- With no pointer, resume takes the session's newest leaf — exactly "carry on
  where I left off". Starting from an *earlier* point is `:AgentTree`'s job
  (`<C-t>` on a row opens the tree for that session, where `f` forks a node).

**Resume is not scoped to a directory.** Verified: `claude --resume <id>` from an
unrelated cwd resumes fine and keeps appending to the session's own project
directory. That is why the finder lists every project's sessions rather than
filtering to the current repo, and why `history.transcript_path` globbing all of
`~/.claude/projects/*/` is the right lookup.

### `relaunch_agent`

The in-place restart — detach bookkeeping, stop the job, optionally write to the
transcript, recreate into the existing panes, restore identity — is shared by
`history_jump` and `session_load`. Its `prepare` callback runs in the only safe
window for touching the transcript (job stopped, new one not yet started); see
the History Tree notes on why that order is not negotiable. `base_command`
strips `--resume`/`--fork-session` so repeated moves do not accumulate flags.

Fixing this up surfaced a latent bug: `ensure_layout` called
`create_window_layout` before it was declared, so the name resolved as a nil
global. Every existing caller happened to hit the `M.is_open()` early return —
`session_load` with no agent running was the first to reach it. There is now a
forward declaration.

### Picker

Telescope when it is installed, with the session's `history.render` tree in the
preview pane (cached per session id — parsing a multi-megabyte transcript on
every cursor move is too slow, and a transcript nobody is writing to cannot
change underneath). `<C-t>` is remapped off telescope's open-in-tab to "open
this session's tree". Without telescope, the plugin's own float, where `/`
searches for free.

`sessions.format` / `sessions.render` are pure and unit tested without a window.
Highlight ranges are **byte** offsets while column padding is computed in
**display** width — the `●` marker is three bytes and one cell.

## PR Review

`:AgentPR 123` brings a GitHub pull request into Neovim — worktree, diff panes,
a local draft of comments — and `:AgentPRSubmit` posts the whole review in one
call.

### Why it is one REST call

`gh pr review` cannot do this. Its only flags are `--approve` /
`--request-changes` / `--comment` / `--body`, so it posts the summary blob and
no inline comments. Those need `gh api`:

```
POST /repos/{owner}/{repo}/pulls/{n}/reviews
{ commit_id, body, event, comments: [ { path, line, side, body }, ... ] }
```

Omitting `event` creates a PENDING review — the draft state the web UI keeps.
The endpoint is **all-or-nothing**: one invalid comment rejects the whole
review. That single fact drives most of the design below.

### The three things that are load-bearing

- **`base_sha` is `git merge-base` output, never the base branch tip.** GitHub's
  PR diff is the three-dot diff. Using the tip instead fails *silently* — the
  comments post fine, they just land on the wrong lines wherever base has moved
  on. Every other failure mode in this feature 422s at you; this one does not,
  which is why it is first.
- **A comment must be on a line inside a hunk**, context lines included — hence
  `-U3`, not `-U0`. `commentable_by_file()` computes the valid set from the hunk
  headers up front and `M.validate` refuses at the cursor. Discovering at submit
  time that half a review is invalid is the failure that would make the feature
  unusable.
- **The head SHA is pinned at checkout and never recomputed.** Reopening a draft
  after the author has pushed keeps you on the head your comments were written
  against; `stale_comments()` reports which ones a newer head would affect and
  the user chooses. Silently repointing `commit_id` puts comments on code they
  were not about.

Two hunk-header details that bite when parsing: a count is **omitted when it is
1** (`@@ -5 +5,3 @@`), and a count of **0** means that side contributes no lines
at all (a pure insertion is `-12,0`), so emitting a one-line range for it offers
a comment on a line that does not exist. Tests cover both.

### Why real file buffers, not a unified patch

The viewer reuses the prompt-history layout: two panes holding actual file
content, paired with `:diffthis`. That makes the coordinate translation nothing
— the cursor's row in the BASE pane *is* the old-file line (`side = "LEFT"`),
and in the HEAD pane *is* the new-file line (`side = "RIGHT"`) — and a visual
range gives `start_line`/`line` with both ends necessarily on the same side,
which is exactly GitHub's constraint. A unified-patch buffer would need
hunk-offset arithmetic for every one of these.

`lua/aiagent/gitdiff.lua` was extracted for this: `show`, `changed_files`,
`unified`, `make_buf`, `show_pair`. `prompthistory.lua` now delegates to it. The
house rule it carries — **never a plain `git diff` for content**, only
`--no-ext-diff` / `--name-status` / `git show` — is the same one recorded in the
prompt-history notes, and now lives in one place.

### The draft

`$XDG_STATE_HOME/aiagent/reviews/<host>-<owner>-<repo>-<n>.json`, alongside the
registry's sidecars and outside the repo (a draft must never reach `git status`)
— but keyed on the **PR**, not on the Neovim pid, because unlike an agent
sidecar it has to survive closing Neovim.

Each comment carries `origin` (`"user"` / `"agent"`) and `accepted`.
`M.submittable` filters to `origin ~= "agent" or accepted`, so **an agent can
propose and only a human can post**. That is the safety property of the whole
feature, not a detail of it: without it, letting an agent write into the draft
would be indistinguishable from letting it post to GitHub.

### The worktree

Branch `agent/pr-<n>` at `$TMPDIR/nvim-agent-<repo>-pr-<n>` — deliberately the
same shape `create_worktree` derives, so `:AgentOpen review pr-123` afterwards
reconnects an agent to that exact tree by branch name. An existing worktree is
reused as-is rather than reset (worktrees are persistent, and an agent may be
working in it); if its HEAD differs from the PR head, that is reported rather
than fixed.

### Non-obvious details

- **The viewer's keys avoid `gc`, and that is not a style choice.** Neovim
  0.10+ maps `gc`/`gcc` as the built-in comment operator, every buffer in the
  viewer is `nomodifiable`, and the operator fails there with E21. A
  buffer-local `gc` does **not** rescue it: `nowait` makes bare `gc` fire, but
  `gcc` still reaches the global mapping. So commenting is `ca` (`config.pr_keys`
  remaps it), and `gc`/`gcc` are mapped to a hint naming the real key, because
  `gc` is the obvious guess and E21 says nothing useful.
- **`]c`/`[c` are left to diff mode**, where they are next/previous change —
  worth more in a review than another binding of ours. Review comments are
  `]r`/`[r`.
- **`a`/`d`/`e` are mapped only off the diff panes.** They are a motion and two
  operators; shadowing them where the user is reading code is worse than not
  having the shortcut there.
- **The submit menu is `history.menu`, not `vim.ui.select`.** Same reasoning as
  the fork menu: a cmdline prompt beside a busy agent terminal is easy to miss,
  and a user's select handler is often a filtering picker that cancels silently
  on no match. Submitting a review is the worst place for a menu that can be
  cancelled without saying so. Comment text uses a float (`compose`) for the
  same reason, plus comments are multi-line.
- **The draft is kept when a submit fails**, and GitHub's error body is shown
  verbatim — a 422 names the offending path and line, which is exactly what is
  needed to fix one comment and retry.
- **`COMMENT` and `REQUEST_CHANGES` require a non-empty body**; the flow asks for
  one rather than collecting a 422 after the round trip.
- **Diff-pane keymaps are re-set on `BufWinEnter`**, because `show_pair` creates
  fresh scratch buffers on every redraw — buffer-local maps set once at open
  would be gone after the first file change.
- **`gC` captures the selection bounds before leaving visual mode.** Opening the
  compose float clears the selection, so reading `'<`/`'>` afterwards is too late.
- Rendering is pure (`M.render` → `lines, hls, rows`) and unit tested without a
  window. Highlight ranges are **byte** offsets while padding is display width —
  `✓` is three bytes and one cell. A test asserts it (and the first version of
  that test got it wrong, which is the point).
- **Reading and resolving existing review threads is deliberately out of scope.**
  That is GraphQL (`reviewThreads`, `resolveReviewThread`), a second integration
  with no overlap with this write path.

## GitHub MCP Setup

### Overview
The GitHub MCP connector for Claude Code requires a workaround because Claude Code only supports
Dynamic Client Registration (DCR) for OAuth, but GitHub's MCP endpoint does not support DCR.
The fix is to use `mcp-remote` as a proxy with a pre-registered GitHub OAuth App.

### Prerequisites
- A GitHub OAuth App with:
  - **Authorization callback URL**: `http://localhost:3334/oauth/callback`
  - A Client ID and Client Secret

To create/manage the OAuth App: https://github.com/settings/developers

### Configuration
The MCP server is configured in `~/.claude.json` via:

```bash
claude mcp add --transport stdio github -- \
  npx mcp-remote https://api.githubcopilot.com/mcp/ \
  --port 3334 \
  --static-oauth-client-info '{"client_id": "YOUR_CLIENT_ID", "client_secret": "YOUR_CLIENT_SECRET"}'
```

Key details:
- **Correct MCP endpoint**: `https://api.githubcopilot.com/mcp/` (trailing slash required)
- **`--port 3334`** is required to pin the callback port — without it, mcp-remote picks a random port each run, breaking the OAuth callback URL match
- **Transport**: stdio (not http), because the remote HTTP transport returns 404

### Re-authenticating
If the connection breaks, run inside Claude Code:
```
/mcp
```
Select `github` and complete the browser OAuth flow.

### Gotchas
- `https://api.github.com/mcp` (wrong) → 404
- `https://api.githubcopilot.com/mcp/` (correct)
- The GitHub OAuth App callback URL must exactly match the port mcp-remote uses — always use `--port 3334` to keep it stable
- Claude.ai's GitHub connector (at claude.ai/settings/connectors) is a **separate system** from Claude Code's MCP config and they do not share state
