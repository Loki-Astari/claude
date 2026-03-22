---@diagnostic disable: undefined-global
-- aiagent.nvim - AI agent integration for Neovim
-- Maintainer: Loki-Astari
-- License: MIT

if vim.g.loaded_aiagent then
  return
end
vim.g.loaded_aiagent = true

vim.api.nvim_create_user_command("AgentOpen",  function(o) require("aiagent").open(unpack(o.fargs)) end, { nargs = "*" })
vim.api.nvim_create_user_command("AgentClose",  function(o) require("aiagent").close(o.args ~= "" and o.args or nil) end, { nargs = "?" })
vim.api.nvim_create_user_command("AgentToggle", function(o) require("aiagent").toggle(o.args ~= "" and o.args or nil) end, { nargs = "?" })
vim.api.nvim_create_user_command("AgentSwitch", function(o) require("aiagent").switch(o.args) end, { nargs = 1 })
vim.api.nvim_create_user_command("AgentSet",    function(o) require("aiagent").set(o.args) end, { nargs = 1 })
vim.api.nvim_create_user_command("AgentSetColor", function(o) require("aiagent").set_color(o.args) end, { nargs = 1 })
vim.api.nvim_create_user_command("AgentList",   function() require("aiagent").print_list() end, { nargs = 0 })
vim.api.nvim_create_user_command("AgentCloseAll", function() require("aiagent").close_all() end, { nargs = 0 })
vim.api.nvim_create_user_command("AgentSendContext",   function() require("aiagent").send_context() end, { nargs = 0 })
vim.api.nvim_create_user_command("AgentResetContext",  function() require("aiagent").reset_context() end, { nargs = 0 })
vim.api.nvim_create_user_command("AgentSendSelection",    function() require("aiagent").send_selection() end, { range = true })
vim.api.nvim_create_user_command("AgentSendDiagnostics", function(o)
  local line1 = o.range > 0 and o.line1 or nil
  local line2 = o.range > 0 and o.line2 or nil
  require("aiagent").send_diagnostics(nil, line1, line2)
end, { nargs = 0, range = true })
