---@diagnostic disable: undefined-global
local M = {}

function M.check()
  local health = vim.health

  health.start("AIAgent.nvim")

  -- Neovim version check
  if vim.fn.has("nvim-0.9") == 1 then
    health.ok("Neovim >= 0.9")
  else
    health.error("Neovim >= 0.9 is required")
  end

  -- Check known agent CLIs
  local aiagent = require("aiagent")
  local known = aiagent.config and aiagent.config.known_agents or {
    claude  = "claude",
    aider   = "aider",
    gemini  = "gemini",
    codex   = "codex",
    goose   = "goose",
    plandex = "plandex",
    cody    = "cody",
    amp     = "amp",
  }

  health.start("Agent CLIs")
  local found_any = false
  for name, cmd in pairs(known) do
    if vim.fn.executable(cmd) == 1 then
      health.ok(name .. " (" .. cmd .. ") found in PATH")
      found_any = true
    else
      health.warn(name .. " (" .. cmd .. ") not found in PATH")
    end
  end
  if not found_any then
    health.error("No agent CLIs found in PATH — install at least one (e.g. claude, aider, gemini)")
  end

  -- GitHub CLI, for :AgentPR.  An invalid token is the failure most likely to
  -- waste a review: everything works until the submit POST comes back 401.
  health.start("Pull request review (:AgentPR)")
  if vim.fn.executable("gh") == 1 then
    local ver = vim.fn.systemlist({ "gh", "--version" })[1] or "gh"
    health.ok(ver)
    local out = vim.fn.system({ "gh", "auth", "status" })
    if vim.v.shell_error == 0 then
      health.ok("gh is authenticated")
    else
      health.error("gh is not authenticated — run: gh auth login\n" .. (out or ""))
    end
  else
    health.warn("gh not found in PATH — :AgentPR needs it (https://cli.github.com)")
  end
  if vim.fn.executable("git") == 1 then
    health.ok("git found in PATH")
  else
    health.error("git not found in PATH")
  end

  -- Check plenary is available (for tests)
  health.start("Optional dependencies")
  if pcall(require, "plenary") then
    health.ok("plenary.nvim found (used for tests)")
  else
    health.info("plenary.nvim not found — only needed to run tests")
  end
end

return M
