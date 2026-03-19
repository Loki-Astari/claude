" aiagent.nvim - AI agent integration for Neovim
" Maintainer: Your Name
" License: MIT

if exists('g:loaded_aiagent')
  finish
endif
let g:loaded_aiagent = 1

command! -nargs=* AgentOpen lua require('aiagent').open(<f-args>)
command! -nargs=? AgentClose lua require('aiagent').close(<f-args>)
command! -nargs=? AgentToggle lua require('aiagent').toggle(<f-args>)
command! -nargs=1 AgentSwitch lua require('aiagent').switch(<q-args>)
command! -nargs=1 AgentSet lua require('aiagent').set(<q-args>)
command! -nargs=1 AgentSetColor lua require('aiagent').set_color(<q-args>)
command! AgentList lua require('aiagent').print_list()
command! AgentCloseAll lua require('aiagent').close_all()
command! AgentSendContext lua require('aiagent').send_context()
command! AgentResetContext lua require('aiagent').reset_context()
command! -range AgentSendSelection lua require('aiagent').send_selection()
