---@diagnostic disable: undefined-global
local M = {}

-- Default configuration
M.config = {
  width = 0.4,      -- Width as percentage (0-1) or columns (>1)
  command = "claude", -- Command to run
}

-- Track the Claude buffer and windows
M.buf = nil
M.win = nil
M.header_buf = nil
M.header_win = nil
M.job_id = nil
M.prev_win = nil  -- Window to return to when exiting terminal mode

--- Force cleanup of the terminal job and buffers
local function force_cleanup()
  -- Stop the job first
  if M.job_id ~= nil then
    local job = M.job_id
    M.job_id = nil  -- Clear first to prevent on_exit callback issues
    -- Close the channel (more reliable than jobstop for terminals)
    pcall(vim.fn.chanclose, job)
    pcall(vim.fn.jobstop, job)
    -- Wait for the job to actually terminate
    pcall(vim.fn.jobwait, {job}, 500)
  end
  -- Close windows first (before deleting buffers)
  if M.win ~= nil and vim.api.nvim_win_is_valid(M.win) then
    pcall(vim.api.nvim_win_close, M.win, true)
    M.win = nil
  end
  if M.header_win ~= nil and vim.api.nvim_win_is_valid(M.header_win) then
    pcall(vim.api.nvim_win_close, M.header_win, true)
    M.header_win = nil
  end
  -- Now delete buffers with force
  if M.buf ~= nil and vim.api.nvim_buf_is_valid(M.buf) then
    pcall(vim.api.nvim_buf_delete, M.buf, { force = true, unload = false })
    M.buf = nil
  end
  if M.header_buf ~= nil and vim.api.nvim_buf_is_valid(M.header_buf) then
    pcall(vim.api.nvim_buf_delete, M.header_buf, { force = true, unload = false })
    M.header_buf = nil
  end
end

--- Setup the plugin with user options
---@param opts table|nil Configuration options
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- Handle quit commands - clean up before Neovim checks for running jobs
  vim.api.nvim_create_autocmd("QuitPre", {
    callback = function()
      if M.job_id ~= nil then
        force_cleanup()
      end
    end,
    desc = "Close Claude terminal before quit check",
  })

  -- Also handle VimLeavePre as a fallback
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      force_cleanup()
    end,
    desc = "Close Claude terminal before exiting Neovim",
  })
end

--- Calculate the window width based on config
---@return number
local function get_width()
  local width = M.config.width
  if width > 0 and width <= 1 then
    -- Percentage of total width
    return math.floor(vim.o.columns * width)
  else
    -- Absolute column count
    return math.floor(width)
  end
end

--- Check if the Claude window is currently open
---@return boolean
function M.is_open()
  return M.win ~= nil and vim.api.nvim_win_is_valid(M.win)
end

--- Open Claude Code in a right-side split
function M.open()
  -- If already open, focus it
  if M.is_open() then
    vim.api.nvim_set_current_win(M.win)
    vim.cmd("startinsert")
    return
  end

  -- Remember the current window to return to later
  M.prev_win = vim.api.nvim_get_current_win()

  -- Create a vertical split on the right
  vim.cmd("botright vsplit")
  local main_win = vim.api.nvim_get_current_win()

  -- Set the width
  vim.api.nvim_win_set_width(main_win, get_width())

  -- Create the header buffer with instructions
  M.header_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(M.header_buf, 0, -1, false, { "Press <C-\\><C-n> to return to editor" })
  vim.api.nvim_set_option_value("modifiable", false, { buf = M.header_buf })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = M.header_buf })
  vim.api.nvim_win_set_buf(main_win, M.header_buf)
  M.header_win = main_win

  -- Set header window options
  vim.api.nvim_set_option_value("number", false, { win = M.header_win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = M.header_win })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = M.header_win })
  vim.api.nvim_set_option_value("winfixheight", true, { win = M.header_win })

  -- Create a horizontal split below for the terminal
  vim.cmd("belowright split")
  M.win = vim.api.nvim_get_current_win()

  -- Resize header to 1 line
  vim.api.nvim_win_set_height(M.header_win, 1)

  -- Create a new buffer for the terminal
  M.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(M.win, M.buf)

  -- Set terminal window options
  vim.api.nvim_set_option_value("number", false, { win = M.win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = M.win })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = M.win })

  -- Set buffer options before starting terminal
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = M.buf })

  -- Start the terminal with claude
  M.job_id = vim.fn.termopen(M.config.command, {
    on_exit = function()
      M.job_id = nil
      M.close()
    end,
  })

  -- Set buffer name for identification
  vim.api.nvim_buf_set_name(M.buf, "claude")

  -- Add keymap to exit terminal mode and return to previous window
  vim.api.nvim_buf_set_keymap(M.buf, "t", "<C-\\><C-n>", "", {
    noremap = true,
    callback = function()
      -- Exit terminal mode
      vim.cmd("stopinsert")
      -- Return to previous window if it's still valid
      if M.prev_win and vim.api.nvim_win_is_valid(M.prev_win) then
        vim.api.nvim_set_current_win(M.prev_win)
      end
    end,
  })

  -- Enter insert mode for immediate interaction
  vim.cmd("startinsert")
end

--- Close the Claude window
function M.close()
  force_cleanup()
end

--- Toggle the Claude window
function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

return M
