" claude.nvim - Claude Code integration for Neovim
" Maintainer: Your Name
" License: MIT

if exists('g:loaded_claude')
  finish
endif
let g:loaded_claude = 1

command! ClaudeOpen lua require('claude').open()
command! ClaudeClose lua require('claude').close()
command! ClaudeToggle lua require('claude').toggle()
