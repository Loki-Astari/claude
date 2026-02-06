# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is **claude.nvim**, a Neovim plugin that integrates Claude Code CLI into the editor. It opens Claude in a right-side terminal split with a header showing keybind instructions.

## Development

This is a Neovim plugin with no build step. To test changes:
1. Ensure the plugin directory is in your Neovim runtimepath
2. Restart Neovim or run `:lua package.loaded['claude'] = nil` to reload

No test framework is currently configured.

## Architecture

- `plugin/claude.vim` - VimScript entry point, defines commands (ClaudeOpen, ClaudeClose, ClaudeToggle)
- `lua/claude/init.lua` - Main Lua module with all plugin logic

The plugin manages state via module-level variables (`M.buf`, `M.win`, `M.header_buf`, `M.header_win`, `M.job_id`, `M.prev_win`) and uses autocmds for cleanup on QuitPre/VimLeavePre.

## Key Patterns

- Use `pcall` for all window/buffer operations that might fail during cleanup
- Terminal jobs require both `chanclose` and `jobstop` for reliable cleanup
- Window options are set via `nvim_set_option_value` with scope parameters
