# AIAgent.nvim

A Neovim plugin that opens AI agent CLIs in a right-side terminal split, with a header showing keybind instructions.

## Features

- **Seamless window management** - Your agent opens in a right-side terminal split that stays out of your way
- **Auto-insert mode** - Moving into the agent window automatically enters insert mode, so you can start typing immediately without extra keystrokes
- **Live buffer updates** - When your agent modifies files, Neovim automatically detects the changes and reloads the buffers. You'll always see the latest version of your code without manually running `:e` or `:checktime`
- **Easy navigation** - Press `<C-\><C-n>` to exit terminal mode and jump back to your previous editing window
- **Clean exit handling** - The plugin properly cleans up terminal jobs when closing Neovim, preventing "job still running" warnings

## Requirements

- Neovim 0.8+
- An agent CLI installed and available in your PATH (for example, [Claude Code CLI](https://claude.ai/code))

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
  width = 0.4,        -- Width as percentage (0-1) or absolute columns (>1)
  command = "claude", -- Command to run (default: "claude")
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

Examples:

- `:AgentOpen` (runs `claude` by default; configure `command` to change it)
- `:AgentOpen Cursor` (runs `cursor-agent` if available)

### Keybindings

When in the agent terminal:

- `<C-\><C-n>` - Exit terminal mode and return to your previous window

### Suggested Mappings

```lua
vim.keymap.set("n", "<leader>ao", "<cmd>AgentOpen<cr>", { desc = "Open agent (default)" })
vim.keymap.set("n", "<leader>ac", "<cmd>AgentOpen Cursor<cr>", { desc = "Open Cursor agent" })
vim.keymap.set("n", "<leader>ax", "<cmd>AgentClose<cr>", { desc = "Close current agent" })
vim.keymap.set("n", "<leader>at", "<cmd>AgentToggle<cr>", { desc = "Toggle current agent" })
```

## License

MIT
