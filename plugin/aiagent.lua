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
vim.api.nvim_create_user_command("AgentHide",   function() require("aiagent").hide() end, { nargs = 0 })
vim.api.nvim_create_user_command("AgentSwitch", function(o) require("aiagent").switch(o.args) end, { nargs = 1 })
vim.api.nvim_create_user_command("AgentSet",    function(o) require("aiagent").set(o.args) end, { nargs = 1 })
vim.api.nvim_create_user_command("AgentSetColor", function(o) require("aiagent").set_color(o.args) end, { nargs = 1 })
-- Plain `:AgentList` lists this instance's agents; `:AgentList!` opens the
-- machine-wide list of every agent in every Neovim instance.
vim.api.nvim_create_user_command("AgentList", function(o)
  if o.bang then require("aiagent").show_all() else require("aiagent").print_list() end
end, { nargs = 0, bang = true })
vim.api.nvim_create_user_command("AgentTask", function(o)
  require("aiagent").set_task(o.args)
end, { nargs = "*" })
vim.api.nvim_create_user_command("AgentCloseAll", function() require("aiagent").close_all() end, { nargs = 0 })
vim.api.nvim_create_user_command("AgentSendContext",   function() require("aiagent").send_context() end, { nargs = 0 })
vim.api.nvim_create_user_command("AgentResetContext",  function() require("aiagent").reset_context() end, { nargs = 0 })
vim.api.nvim_create_user_command("AgentSendSelection",    function() require("aiagent").send_selection() end, { range = true })
vim.api.nvim_create_user_command("AgentDiff", function(o)
  require("aiagent").prompt_history_open(o.args ~= "" and o.args or nil)
end, { nargs = "?" })
vim.api.nvim_create_user_command("AgentChat", function() require("aiagent").prompt_history_close() end, { nargs = 0 })
-- The session history tree: every branch of the current session, jumpable.
vim.api.nvim_create_user_command("AgentTree", function(o)
  require("aiagent").history_open(o.args ~= "" and o.args or nil)
end, { nargs = "?" })
-- Fork a new agent from the current agent's position.  Pick another point to
-- fork from with `f` in the |AgentTree| popup.
vim.api.nvim_create_user_command("AgentFork", function(o)
  require("aiagent").fork_here(o.fargs[1], o.fargs[2])
end, { nargs = "*" })
-- Find any past Claude session on this machine and load it back into an agent.
-- `!` also lists the promptless stubs Claude Code leaves behind.
vim.api.nvim_create_user_command("AgentFind", function(o)
  require("aiagent").find_session({ all = o.bang })
end, { nargs = 0, bang = true })
vim.api.nvim_create_user_command("AgentSessions", function(o)
  -- Plain `:AgentSessions` picks the session to continue capturing into;
  -- `:AgentSessions!` loads the chosen session's prompt history into the agent.
  require("aiagent").prompt_history_list(o.bang)
end, { nargs = 0, bang = true })
-- `:AgentInstallSkill` with no argument installs every bundled skill; name one
-- to install just that.  `!` overwrites an existing install.
vim.api.nvim_create_user_command("AgentInstallSkill", function(o)
  local aiagent = require("aiagent")
  local names = o.args ~= "" and { o.args } or aiagent.bundled_skills()
  for _, name in ipairs(names) do
    aiagent.install_skill({ name = name, force = o.bang })
  end
end, {
  nargs = "?",
  bang = true,
  complete = function() return require("aiagent").bundled_skills() end,
})
vim.api.nvim_create_user_command("AgentSendDiagnostics", function(o)
  local line1 = o.range > 0 and o.line1 or nil
  local line2 = o.range > 0 and o.line2 or nil
  require("aiagent").send_diagnostics(nil, line1, line2)
end, { nargs = 0, range = true })
-- Review a GitHub pull request locally.  `:AgentPR` with no argument picks from
-- the open PRs; `:AgentPR 123` opens that one.
vim.api.nvim_create_user_command("AgentPR", function(o)
  require("aiagent").pr_open(o.args ~= "" and o.args or nil)
end, { nargs = "?" })
vim.api.nvim_create_user_command("AgentPRClose", function() require("aiagent").pr_close() end, { nargs = 0 })
-- Brief the agent on the PR under review and let it propose comments.  Nothing
-- it proposes is posted until you accept it and submit.
vim.api.nvim_create_user_command("AgentPRReview", function(o)
  require("aiagent").pr_review(o.fargs[1], o.fargs[2])
end, { nargs = "*" })
vim.api.nvim_create_user_command("AgentPRSubmit", function() require("aiagent").pr_submit() end, { nargs = 0 })
vim.api.nvim_create_user_command("AgentPRDiscard", function() require("aiagent").pr_discard() end, { nargs = 0 })
