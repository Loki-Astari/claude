" aiagent.nvim - AI agent integration for Neovim
" Maintainer: Your Name
" License: MIT

if exists('g:loaded_aiagent')
  finish
endif
let g:loaded_aiagent = 1

command! -nargs=* AgentOpen lua require('aiagent').open(<f-args>)
command! -nargs=? AgentClose lua require('aiagent').close(<f-args>)
command! -nargs=* AgentToggle lua require('aiagent').toggle(<f-args>)
command! -nargs=1 AgentSwitch lua require('aiagent').switch(<q-args>)
command! AgentList lua require('aiagent').print_list()
command! AgentCloseAll lua require('aiagent').close_all()
