# AIAgent.nvim

A Neovim plugin that opens AI agent CLIs in a right-side terminal split, with a header showing keybind instructions.

## Features

- **Seamless window management** - Your agent opens in a right-side terminal split that stays out of your way
- **Auto-insert mode** - Moving into the agent window automatically enters insert mode, so you can start typing immediately without extra keystrokes
- **Live buffer updates** - When your agent modifies files, Neovim automatically detects the changes and reloads the buffers. You'll always see the latest version of your code without manually running `:e` or `:checktime`
- **Easy navigation** - Press `<C-\><C-n>` to exit terminal mode and jump back to your previous editing window
- **Clean exit handling** - The plugin properly cleans up terminal jobs when closing Neovim, preventing "job still running" warnings
- **Buffer context integration** - Automatically send open buffer file paths to the agent, giving it context about what you're working on
- **Visual selection support** - Select code and send it directly to the agent to ask questions about specific snippets

## Requirements

- Neovim 0.8+
- An agent CLI installed and available in your PATH (for example, [Claude Code CLI](https://claude.ai/code), [Cursor](https://cursor.com/cli))

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "Loki-Astari/AIAgent",
  config = function()
    require("aiagent").setup()
  end,
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "Loki-Astari/AIAgent",
  config = function()
    require("aiagent").setup()
  end,
}
```

### [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'Loki-Astari/AIAgent'
```

Then call setup in your init.lua:

```lua
require("aiagent").setup()
```

## Configuration

```lua
require("aiagent").setup({
  width = 0.4,               -- Width as percentage (0-1) or absolute columns (>1)
  default_agent = "claude",  -- Symbolic agent name to use on startup
  auto_send_context = false, -- Auto-send open buffer paths when entering terminal
  agent_startup_delay = 1500, -- ms to wait before sending /color on agent start
  show_header = true,         -- set to false to hide the keybind instruction header
  -- Extend or override the built-in agent → executable mapping
  known_agents = {
    mytool = "my-custom-cli",
  },
})
```

## Usage

### Commands

| Command | Description |
|---------|-------------|
| `:AgentSet {agent}` | Set which agent CLI to use for new agents (e.g. `claude`, `cursor`) |
| `:AgentOpen [Name [WTName [directory]]]` | Open an agent terminal (see below for full syntax) |
| `:AgentClose [name]` | Close an agent (defaults to current) |
| `:AgentToggle [name]` | Toggle an agent terminal |
| `:AgentSwitch {name}` | Switch to an existing agent by name |
| `:AgentList` | Show running agents |
| `:AgentCloseAll` | Close all agents |
| `:AgentSendContext` | Send open buffer file paths to the agent |
| `:AgentResetContext` | Reset tracking to re-send all buffer paths |
| `:'<,'>AgentSendSelection` | Send visual selection to the agent |

### Supported agents

| Name | CLI executable |
|------|---------------|
| `claude` | `claude` (Anthropic Claude Code) |
| `cursor` | `cursor-agent` (Cursor AI) |
| `aider` | `aider` |
| `gemini` | `gemini` (Google Gemini CLI) |
| `codex` | `codex` (OpenAI Codex CLI) |
| `goose` | `goose` (Block's Goose) |
| `plandex` | `plandex` |
| `cody` | `cody` (Sourcegraph Cody) |
| `amp` | `amp` |

Examples:

```
:AgentSet cursor                          " switch to Cursor for new agents
:AgentOpen                                " opens a Cursor agent named 'AIAgent'
:AgentSet claude                          " switch back to Claude
:AgentOpen Review                         " opens a Claude agent named 'Review'
:AgentOpen Feature -                      " opens a Claude agent in a worktree named 'feature'
:AgentOpen Feature MyWT                   " opens a Claude agent named 'Feature' in a worktree named 'MyWT'
:AgentOpen Feature MyWT ~/trees/myWT      " same, but creates the worktree at a specific directory
```

### Keybindings

When in the agent terminal:

| Keybinding | Description |
|------------|-------------|
| `<C-\><C-n>` | Exit terminal mode and return to your previous window |
| `<C-\><C-s>` | Enter scroll mode (press `i` to resume terminal interaction) |
| `<C-\><C-a>` | Cycle to the next agent |
| `<C-\><C-c>` | Send open buffer file paths as context |

### Suggested Mappings

```lua
vim.keymap.set("n", "<leader>ao", "<cmd>AgentOpen<cr>", { desc = "Open agent (default)" })
vim.keymap.set("n", "<leader>ac", "<cmd>AgentOpen Cursor<cr>", { desc = "Open Cursor agent" })
vim.keymap.set("n", "<leader>ax", "<cmd>AgentClose<cr>", { desc = "Close current agent" })
vim.keymap.set("n", "<leader>at", "<cmd>AgentToggle<cr>", { desc = "Toggle current agent" })
vim.keymap.set("v", "<leader>as", "<cmd>AgentSendSelection<cr>", { desc = "Send selection to agent" })
```

## Buffer Context Integration

The plugin can send file paths of your open buffers to the AI agent, giving it context about what you're working on. This uses the `@file` syntax that Claude Code understands (Not tested for Cursor yet).

### How it works

1. Open the files you want the agent to have context on
2. Switch to the agent terminal
3. Press `<C-\><C-c>` or run `:AgentSendContext`
4. The plugin types `@file1 @file2 ...` into the terminal
5. Type your question and press Enter

The plugin tracks which files have been sent to each agent, so subsequent calls only send newly opened files. Use `:AgentResetContext` to clear the tracking and re-send all files.

### Auto-send mode

Enable `auto_send_context = true` in your setup to automatically send new buffer paths whenever you enter the agent terminal:

```lua
require("aiagent").setup({
  auto_send_context = true,
})
```

## Visual Selection

Select code in visual mode and send it to the agent to ask questions about specific snippets.

### How it works

1. Select code using visual mode (`v`, `V`, or `<C-v>`)
2. Run `:'<,'>AgentSendSelection` or use your mapped key (e.g., `<leader>as`)
3. The selected code is sent to the agent wrapped in a markdown code block with the filetype
4. The agent terminal is focused so you can type your question

If no agent is running, one will be started automatically.

## Git Worktree Support

When starting a new agent on a separate task it can be useful to isolate it in its own git worktree, so its changes don't interfere with your current working tree.

### AgentOpen syntax

```
:AgentOpen [Name [WTName [directory]]]
```

| Argument | Description |
|----------|-------------|
| `Name` | Agent name shown in the tab (default: `AIAgent`) |
| `WTName` | Worktree name. `-` is shorthand for using the agent `Name`. Determines the branch (`agent/<slug>`) and default directory. |
| `directory` | Explicit path for a **new** worktree. Error if the worktree already exists. |

### Creating a worktree agent

Pass a `WTName` as the second argument. Use `-` as shorthand when you want the worktree named after the agent:

```
:AgentOpen Feature -          " worktree name = 'Feature' (branch: agent/feature)
:AgentOpen Feature MyWT       " agent named 'Feature', worktree named 'MyWT' (branch: agent/mywt)
:AgentOpen Feature - ~/trees  " worktree named 'Feature' created at ~/trees
```

This will:
1. Create a branch `agent/<slug>` from the current `HEAD` (or reuse it if it already exists)
2. Check it out into a consistent path under the system temp directory (e.g. `/tmp/nvim-agent-feature`), or the explicit `directory` if given
3. Start the agent with that directory as its working directory

### Persistent worktrees

Worktrees are **persistent** — they are not removed when you close the agent or exit Neovim. The branch and directory use a fixed, deterministic naming convention based on the `WTName`, so the plugin can find them again across sessions.

When you reopen an agent by the same `Name`, the plugin automatically detects any existing worktree (matched by the slug derived from `Name`) and reconnects — no need to pass `WTName` again:

```
" Session 1: create the worktree
:AgentOpen Feature -

" Session 2: auto-detected from git, no WTName needed
:AgentOpen Feature
```

To permanently remove a worktree when you are done with it:

```bash
git worktree remove /tmp/nvim-agent-feature
git branch -d agent/feature
```

### Opening files in the worktree

While a worktree agent is active (i.e. it is the current agent), opening a file with `:e` will automatically redirect to the worktree version of that file. For example, if the worktree is at `/tmp/nvim-agent-feature` and you run:

```
:e src/main.cpp
```

The plugin opens `/tmp/nvim-agent-feature/src/main.cpp` instead of the working-tree copy. The bufferline tab will be prefixed with the agent name (e.g. `Feature: main.cpp`) to make it clear which version you are editing.

If the worktree version of the file is already open in another buffer, that buffer is reused rather than opening a duplicate.

Switching to an existing buffer directly (e.g. via bufferline or `<C-^>`) does **not** trigger a redirect — only an explicit `:e` command does.

## License

MIT
