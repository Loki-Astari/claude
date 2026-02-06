# claude.nvim

A Neovim plugin that integrates [Claude Code CLI](https://claude.ai/code) into your editor. Opens Claude in a right-side terminal split with a header showing keybind instructions.

## Requirements

- Neovim 0.8+
- [Claude Code CLI](https://claude.ai/code) installed and available in your PATH

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "Loki-Astari/claude",
  config = function()
    require("claude").setup()
  end,
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "Loki-Astari/claude",
  config = function()
    require("claude").setup()
  end,
}
```

### [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'Loki-Astari/claude'
```

Then call setup in your init.lua:

```lua
require("claude").setup()
```

## Configuration

```lua
require("claude").setup({
  width = 0.4,        -- Width as percentage (0-1) or absolute columns (>1)
  command = "claude", -- Command to run (default: "claude")
})
```

## Usage

### Commands

| Command | Description |
|---------|-------------|
| `:ClaudeOpen` | Open Claude in a right-side split |
| `:ClaudeClose` | Close the Claude window |
| `:ClaudeToggle` | Toggle the Claude window |

### Keybindings

When in the Claude terminal:

- `<C-\><C-n>` - Exit terminal mode and return to your previous window

### Suggested Mappings

```lua
vim.keymap.set("n", "<leader>co", "<cmd>ClaudeOpen<cr>", { desc = "Open Claude" })
vim.keymap.set("n", "<leader>cc", "<cmd>ClaudeClose<cr>", { desc = "Close Claude" })
vim.keymap.set("n", "<leader>ct", "<cmd>ClaudeToggle<cr>", { desc = "Toggle Claude" })
```

## License

MIT
