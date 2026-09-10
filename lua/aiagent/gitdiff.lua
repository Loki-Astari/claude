---@diagnostic disable: undefined-global
-- aiagent.gitdiff — the git and buffer primitives behind every before|after
-- diff pane in this plugin.
--
-- Extracted from prompthistory.lua so the prompt-history viewer and the PR
-- review viewer share one implementation.  They differ in what they put in the
-- left column, not in how a diff is reconstructed, and reconstructing a diff
-- has enough sharp edges (see below) that having two copies means fixing every
-- bug twice.
--
-- THE HOUSE RULE, inherited and non-negotiable: never shell out to a plain
-- `git diff` for content.  A user with an external difftool configured
-- (`diff.external`, `diff.tool`) gets that tool invoked instead of git's own
-- diff, and the output is whatever that tool prints.  Only these forms are
-- safe, and they are the only ones used here:
--
--   git show <tree-ish>:<path>         -- content
--   git diff --no-ext-diff --name-status   -- which files
--   git diff --no-ext-diff -U<n>           -- the patch itself
--
-- Content is reconstructed from both sides and handed to Neovim's own
-- `:diffthis`, so what the user reads is Neovim's diff, not git's.

local M = {}

-- ---------------------------------------------------------------------------
-- git
-- ---------------------------------------------------------------------------

--- File contents at a tree-ish, as lines.  Empty list if the path is absent on
--- that side (added/deleted) or the tree-ish does not resolve — both are normal
--- and neither is an error worth reporting.
---@param root string  repo root to run in
---@param tree string  tree-ish (tree SHA, commit SHA, ref)
---@param path string|nil
---@return string[]
function M.show(root, tree, path)
  if not path or path == "" or not tree or tree == "" then return {} end
  local out = vim.fn.systemlist({ "git", "-C", root, "show", tree .. ":" .. path })
  if vim.v.shell_error ~= 0 then return {} end
  return out
end

--- Changed files between two tree-ishes, with the path on each side resolved so
--- content can be reconstructed across renames.
---@param root string
---@param before string
---@param after string
---@return table[]  { status, path, before_path, after_path }
function M.changed_files(root, before, after)
  if not before or not after then return {} end
  local out = vim.fn.systemlist(
    { "git", "-C", root, "diff", "--no-ext-diff", "--name-status", "-M", before, after })
  if vim.v.shell_error ~= 0 then return {} end
  return M.parse_name_status(out)
end

--- Parse `git diff --name-status -M` output.  Pure, so the rename handling is
--- unit testable without a repo.
---@param out string[]
---@return table[]  { status, path, before_path, after_path }
function M.parse_name_status(out)
  local files = {}
  for _, line in ipairs(out) do
    local parts = vim.split(line, "\t", { plain = true })
    local status = parts[1] or ""
    if status:sub(1, 1) == "R" then
      table.insert(files, { status = "R", path = parts[3],
        before_path = parts[2], after_path = parts[3] })
    elseif status == "A" then
      table.insert(files, { status = "A", path = parts[2],
        before_path = nil, after_path = parts[2] })
    elseif status == "D" then
      table.insert(files, { status = "D", path = parts[2],
        before_path = parts[2], after_path = nil })
    elseif parts[2] then
      table.insert(files, { status = status, path = parts[2],
        before_path = parts[2], after_path = parts[2] })
    end
  end
  return files
end

--- Unified diff between two tree-ishes.  `--no-ext-diff` is the safety rule
--- above; `context` selects the hunk padding (GitHub renders and accepts
--- comments on three lines of context, so PR work wants 3, not 0).
---@param root string
---@param before string|nil
---@param after string|nil
---@param path string|nil  limit to one path (nil = whole diff)
---@param context number|nil  defaults to 3
---@return string[]
function M.unified(root, before, after, path, context)
  if not before or not after then return {} end
  local cmd = { "git", "-C", root, "diff", "--no-ext-diff", "-M",
                "-U" .. tostring(context or 3), before, after }
  if path and path ~= "" then
    table.insert(cmd, "--")
    table.insert(cmd, path)
  end
  local out = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then return {} end
  return out
end

-- ---------------------------------------------------------------------------
-- buffers and panes
-- ---------------------------------------------------------------------------

--- A fresh scratch buffer holding lines, with the filetype inferred from path
--- so syntax highlighting works in the diff panes.
---@param lines string[]
---@param path string|nil
---@return integer buf
function M.make_buf(lines, path)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local ft = path and vim.filetype.match({ filename = path }) or nil
  if ft then vim.bo[buf].filetype = ft end
  return buf
end

--- Put a before/after pair of buffers into two windows and turn diff mode on,
--- restoring the caller's window afterwards.
---
--- `:diffthis` acts on the CURRENT window, so both panes have to be entered in
--- turn; the caller's focus is saved and restored around that so this can be
--- driven from a list pane without stealing the cursor.
---@param wins table  { before: integer, after: integer }
---@param before table { lines: string[], path: string|nil }
---@param after table  { lines: string[], path: string|nil }
---@return integer|nil before_buf, integer|nil after_buf
function M.show_pair(wins, before, after)
  if not vim.api.nvim_win_is_valid(wins.before)
    or not vim.api.nvim_win_is_valid(wins.after) then return nil, nil end

  local bbuf = M.make_buf(before.lines, before.path)
  local abuf = M.make_buf(after.lines, after.path)
  vim.api.nvim_win_set_buf(wins.before, bbuf)
  vim.api.nvim_win_set_buf(wins.after, abuf)

  local cur = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(wins.before); vim.cmd("diffthis")
  vim.api.nvim_set_current_win(wins.after);  vim.cmd("diffthis")
  if vim.api.nvim_win_is_valid(cur) then vim.api.nvim_set_current_win(cur) end

  return bbuf, abuf
end

return M
