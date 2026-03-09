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
  width = 0.4,              -- Width as percentage (0-1) or absolute columns (>1)
  command = "claude",       -- Command to run (default: "claude")
  auto_send_context = false, -- Auto-send open buffer paths when entering terminal
  named_commands = {
    Cursor = "cursor-agent", -- allows :AgentOpen Cursor with no 2nd argument
  },
})
```

## Usage

### Commands

| Command | Description |
|---------|-------------|
| `:AgentOpen [name] [command]` | Open an agent terminal (name defaults to `AIAgent`) |
| `:AgentClose [name]` | Close an agent (defaults to current) |
| `:AgentToggle [name] [command]` | Toggle an agent terminal |
| `:AgentSwitch {name}` | Switch to an existing agent by name |
| `:AgentList` | Show running agents |
| `:AgentCloseAll` | Close all agents |
| `:AgentSendContext` | Send open buffer file paths to the agent |
| `:AgentResetContext` | Reset tracking to re-send all buffer paths |
| `:'<,'>AgentSendSelection` | Send visual selection to the agent |

Examples:

- `:AgentOpen` (runs `claude` by default; configure `command` to change it)
- `:AgentOpen Cursor` (runs `cursor-agent` if available)

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

## License

MIT
