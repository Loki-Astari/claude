---@diagnostic disable: undefined-global
-- aiagent.prreview — review a GitHub pull request locally and submit the whole
-- review in one API call.
--
-- The GitHub review UI collects comments one at a time into a PENDING review
-- and posts them on submit.  The same thing is one REST call:
--
--   POST /repos/{owner}/{repo}/pulls/{n}/reviews
--   { commit_id, body, event, comments: [ { path, line, side, body }, ... ] }
--
-- `gh pr review` cannot do this — its only flags are --approve /
-- --request-changes / --comment / --body, so it posts the summary blob and
-- nothing else.  Inline comments require `gh api`.
--
-- So the flow is: check the PR head out into a worktree, read it in the
-- before|after diff panes (shared with the prompt-history viewer via
-- aiagent.gitdiff), collect comments as a LOCAL draft file, and submit once.
--
-- Three things are load-bearing and easy to get wrong:
--
-- 1. THE DIFF IS THREE-DOT.  GitHub compares the head against the MERGE BASE,
--    not against the base branch's current tip.  `base_sha` in the draft is
--    always `git merge-base` output.  Getting this wrong fails SILENTLY: the
--    comments post fine, they just land on the wrong lines.
--
-- 2. A COMMENT MUST BE ON A LINE IN THE DIFF, or GitHub answers 422 and
--    rejects the ENTIRE review — there is no partial success.  So the set of
--    commentable lines is computed from the hunk headers up front and a
--    comment is refused at the cursor, where it costs nothing, rather than
--    after half an hour of reading.
--
-- 3. THE HEAD SHA IS PINNED at checkout.  If the author pushes mid-review,
--    unpinned comments either 422 or land on code that has since changed.  The
--    submit path re-reads the head and reports affected comments rather than
--    silently retargeting.
--
-- Comments carry `origin` ("user" or "agent") and `accepted`.  An agent driving
-- this module through |M.pr_comment| can only ever propose: nothing it wrote
-- reaches the payload until a human accepts it.  That separation is the point
-- of the feature, not a detail of it.

local M = {}

local gitdiff = require('aiagent.gitdiff')

local ns = vim.api.nvim_create_namespace('AIAgentReview')

M.state = nil   -- nil when the viewer is closed; a table while it is open

-- ---------------------------------------------------------------------------
-- Shell helpers
-- ---------------------------------------------------------------------------
--
-- These block, like create_worktree() in init.lua does.  A PR review starts
-- from an explicit user action (`:AgentPR 123`) that cannot proceed until the
-- fetch lands, so there is nothing useful to do with the time; an async chain
-- here would buy nothing and cost a lot of callback plumbing.

--- Run git in a directory, returning its output lines.
---@param root string
---@param ... string  git arguments
---@return string[] lines, boolean ok
local function git(root, ...)
  local out = vim.fn.systemlist({ 'git', '-C', root, ... })
  return out, vim.v.shell_error == 0
end

--- First line of git output, trimmed — the common case for rev-parse and friends.
---@return string|nil
local function git1(root, ...)
  local out, ok = git(root, ...)
  if not ok or not out[1] then return nil end
  local s = out[1]:gsub('%s+$', '')
  return s ~= '' and s or nil
end

--- Run `gh` with arguments, optionally writing stdin.  Returns the raw stdout,
--- whether it succeeded, and stderr — gh puts API error bodies on stdout and
--- transport/auth failures on stderr, and both are worth surfacing.
---@param args string[]
---@param stdin string|nil
---@return string out, boolean ok, string err
function M.gh(args, stdin)
  if vim.fn.executable('gh') ~= 1 then
    return '', false, "gh is not installed or not on PATH (https://cli.github.com)"
  end
  local cmd = { 'gh' }
  for _, a in ipairs(args) do table.insert(cmd, a) end
  local out
  if stdin then
    out = vim.fn.system(cmd, stdin)
  else
    out = vim.fn.system(cmd)
  end
  return out or '', vim.v.shell_error == 0, out or ''
end

-- ---------------------------------------------------------------------------
-- Pure: remote parsing
-- ---------------------------------------------------------------------------

--- Split a git remote URL into host / owner / repo.
--- Handles the three shapes git accepts for GitHub remotes:
---   https://github.com/owner/repo.git
---   ssh://git@github.com/owner/repo.git
---   git@github.com:owner/repo.git          (scp-like, no scheme)
---@param url string|nil
---@return table|nil  { host, owner, repo }
function M.parse_remote(url)
  if type(url) ~= 'string' then return nil end
  url = url:gsub('^%s+', ''):gsub('%s+$', '')
  if url == '' then return nil end

  local hostpart, path
  local rest = url:match('^%a[%w+.%-]*://(.+)$')
  if rest then
    rest = (rest:gsub('^[^@/]*@', ''))            -- drop any user@ prefix
    hostpart, path = rest:match('^([^/]+)/(.+)$')
  else
    local scp = (url:gsub('^[^@/]*@', ''))        -- git@host:owner/repo
    hostpart, path = scp:match('^([^:/]+):(.+)$')
  end
  if not hostpart or not path then return nil end

  local host = hostpart:match('^([^:]+)')         -- strip :port
  path = (path:gsub('%.git$', ''):gsub('^/+', ''):gsub('/+$', ''))
  local owner, repo = path:match('^([^/]+)/([^/]+)$')
  if not host or not owner or not repo then return nil end
  return { host = host, owner = owner, repo = repo }
end

--- The remote to talk to for a repo: `origin` when it parses, else the first
--- remote that does.  Returns the remote name alongside the parsed identity so
--- fetches can name it.
---@param root string
---@return table|nil  { remote, host, owner, repo }
function M.remote_for(root)
  local names = git(root, 'remote')
  local ordered = {}
  for _, n in ipairs(names) do
    if n == 'origin' then table.insert(ordered, 1, n) else table.insert(ordered, n) end
  end
  for _, name in ipairs(ordered) do
    local url = git1(root, 'remote', 'get-url', name)
    local parsed = M.parse_remote(url)
    if parsed then
      parsed.remote = name
      return parsed
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Pure: which lines GitHub will accept a comment on
-- ---------------------------------------------------------------------------

--- Parse hunk headers into the set of lines that are part of the diff, per side.
---
--- A hunk header is `@@ -old_start,old_count +new_start,new_count @@`, and two
--- details of that format bite:
---   * a count is OMITTED when it is 1 (`@@ -5 +5,3 @@` is legal), and
---   * a count of 0 means that side contributes no lines at all — a pure
---     insertion has `-12,0`, and emitting a one-line range at 12 for it would
---     offer a LEFT comment on a line that does not exist.
---
--- Context lines inside a hunk are commentable on GitHub, so the caller should
--- feed this a diff generated with the same context GitHub renders (-U3), not
--- -U0 — the latter yields only changed lines and refuses valid comments.
---@param diff_lines string[]  output of `git diff --no-ext-diff -U3 ...`
---@return table  { LEFT = { [line] = true }, RIGHT = { [line] = true } }
function M.commentable(diff_lines)
  local sets = { LEFT = {}, RIGHT = {} }

  local function fill(set, start, count)
    start = tonumber(start)
    count = (count == nil or count == '') and 1 or tonumber(count)
    if not start or not count or count <= 0 then return end
    for n = start, start + count - 1 do set[n] = true end
  end

  for _, line in ipairs(diff_lines or {}) do
    local os_, oc, ns_, nc = line:match('^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@')
    if os_ then
      fill(sets.LEFT, os_, oc)
      fill(sets.RIGHT, ns_, nc)
    end
  end
  return sets
end

--- Check a comment against a file's commentable-line sets.
---@param c table  comment
---@param sets table  from M.commentable
---@return boolean ok, string|nil err
function M.validate(c, sets)
  if not c or not c.path or c.path == '' then return false, 'comment has no path' end
  if not c.body or c.body:gsub('%s', '') == '' then return false, 'comment is empty' end
  if c.subject_type == 'file' then return true, nil end

  local side = c.side
  if side ~= 'LEFT' and side ~= 'RIGHT' then return false, 'side must be LEFT or RIGHT' end
  sets = sets or { LEFT = {}, RIGHT = {} }
  local set = sets[side] or {}

  if type(c.line) ~= 'number' then return false, 'comment has no line' end
  if not set[c.line] then
    return false, string.format('line %d of %s is not part of this PR\'s diff', c.line, c.path)
  end

  if c.start_line then
    if (c.start_side or side) ~= side then
      return false, 'a multi-line comment cannot span both sides of the diff'
    end
    if c.start_line > c.line then
      return false, 'the range starts after it ends'
    end
    if not set[c.start_line] then
      return false, string.format('line %d of %s is not part of this PR\'s diff',
        c.start_line, c.path)
    end
  end
  return true, nil
end

-- ---------------------------------------------------------------------------
-- Pure: the submit payload
-- ---------------------------------------------------------------------------

--- The comments that may actually be posted: everything the user wrote, plus
--- the agent's proposals a human has explicitly accepted.  Local-only fields
--- (id, origin, accepted) are stripped — the API rejects unknown keys.
---@param draft table
---@return table[]
function M.submittable(draft)
  local out = {}
  for _, c in ipairs((draft or {}).comments or {}) do
    if c.origin ~= 'agent' or c.accepted then
      local e = { path = c.path, body = c.body }
      if c.subject_type == 'file' then
        e.subject_type = 'file'
      else
        e.line = c.line
        e.side = c.side
        if c.start_line and c.start_line ~= c.line then
          e.start_line = c.start_line
          e.start_side = c.start_side or c.side
        end
      end
      table.insert(out, e)
    end
  end
  return out
end

--- Build the POST body.
--- `event` nil leaves the review PENDING on GitHub — a draft only the author of
--- the review can see, which is a deliberate option, not an oversight.
---@param draft table
---@param event string|nil  APPROVE | REQUEST_CHANGES | COMMENT | nil
---@return table
function M.payload(draft, event)
  local p = {
    commit_id = draft.head_sha,
    body      = draft.body or '',
    comments  = M.submittable(draft),
  }
  if event and event ~= '' then p.event = event end
  return p
end

-- ---------------------------------------------------------------------------
-- Draft state on disk
-- ---------------------------------------------------------------------------

--- Directory holding review drafts.  Alongside the agent registry's sidecars
--- and, like them, deliberately outside both the repo and Neovim's own state
--- dir: a draft must never show up in `git status` or get committed, and it
--- must survive closing Neovim — that is the whole point of drafting locally.
---@return string
function M.reviews_dir()
  local state = os.getenv('XDG_STATE_HOME')
  if not state or state == '' then
    state = vim.fn.expand('~/.local/state')
  end
  return state .. '/aiagent/reviews'
end

local function slug(s)
  return (tostring(s or ''):gsub('[^%w%.%-_]', '-'))
end

--- Draft file path for a PR.  Keyed by the PR itself, not by Neovim pid — two
--- instances reviewing the same PR share one draft, which is what you want.
---@param pr table  { host, owner, repo, number }
---@return string
function M.draft_path(pr)
  return string.format('%s/%s-%s-%s-%s.json', M.reviews_dir(),
    slug(pr.host), slug(pr.owner), slug(pr.repo), slug(pr.number))
end

--- Read a draft, or nil when none exists.
---@param pr table
---@return table|nil
function M.load(pr)
  local path = M.draft_path(pr)
  local f = io.open(path, 'r')
  if not f then return nil end
  local text = f:read('*a')
  f:close()
  local ok, draft = pcall(vim.fn.json_decode, text)
  if not ok or type(draft) ~= 'table' then return nil end
  draft.comments = draft.comments or {}
  return draft
end

--- Write a draft.  Failures warn rather than throw: losing a comment is bad,
--- but taking down the viewer mid-review is worse.
---@param draft table
---@return boolean ok
function M.save(draft)
  draft.updated = os.time()
  if vim.fn.isdirectory(M.reviews_dir()) == 0 then
    pcall(vim.fn.mkdir, M.reviews_dir(), 'p')
  end
  local ok = pcall(vim.fn.writefile,
    { vim.fn.json_encode(draft) }, M.draft_path(draft))
  if not ok then
    vim.notify('AgentPR: could not save the review draft', vim.log.levels.WARN)
  end
  return ok == true
end

--- Delete a draft.
---@param draft table
function M.discard(draft)
  pcall(os.remove, M.draft_path(draft))
end

--- A fresh draft for a fetched PR.
---@param pr table
---@return table
function M.new_draft(pr)
  return {
    schema   = 1,
    host     = pr.host,
    owner    = pr.owner,
    repo     = pr.repo,
    number   = pr.number,
    title    = pr.title,
    url      = pr.url,
    head_sha = pr.head_sha,
    base_sha = pr.base_sha,
    worktree = pr.worktree,
    git_root = pr.git_root,
    created  = os.time(),
    updated  = os.time(),
    body     = '',
    next_id  = 1,
    comments = {},
  }
end

-- ---------------------------------------------------------------------------
-- Draft mutation
-- ---------------------------------------------------------------------------

--- Append a comment.  Assigns a stable local id; does NOT validate — callers
--- validate against M.commentable first so the error lands at the cursor.
---@param draft table
---@param comment table
---@return table comment  (the stored one, with its id)
function M.add(draft, comment)
  draft.next_id = draft.next_id or (#draft.comments + 1)
  comment.id = 'c' .. tostring(draft.next_id)
  draft.next_id = draft.next_id + 1
  comment.origin = comment.origin or 'user'
  if comment.origin == 'agent' and comment.accepted == nil then
    comment.accepted = false
  end
  table.insert(draft.comments, comment)
  return comment
end

--- Remove a comment by id.
---@return boolean removed
function M.remove(draft, id)
  for i, c in ipairs(draft.comments or {}) do
    if c.id == id then
      table.remove(draft.comments, i)
      return true
    end
  end
  return false
end

--- Accept or un-accept an agent proposal.  A user-written comment is always
--- submittable, so toggling it is a no-op rather than an error.
---@return boolean changed
function M.accept(draft, id, value)
  for _, c in ipairs(draft.comments or {}) do
    if c.id == id then
      if c.origin ~= 'agent' then return false end
      c.accepted = (value == nil) and true or (value and true or false)
      return true
    end
  end
  return false
end

--- Count of comments that would be posted, and of proposals still awaiting a
--- decision.
---@return integer submittable, integer pending
function M.counts(draft)
  local sub, pending = 0, 0
  for _, c in ipairs((draft or {}).comments or {}) do
    if c.origin == 'agent' and not c.accepted then
      pending = pending + 1
    else
      sub = sub + 1
    end
  end
  return sub, pending
end

-- ---------------------------------------------------------------------------
-- Pure: per-file commentable sets
-- ---------------------------------------------------------------------------

--- Split a whole-PR unified diff into per-file commentable sets.
---
--- One git call for every file, rather than one per file, and it gets renames
--- right for free: the key is the path on the NEW side, which is the path the
--- GitHub API expects even for a comment on the LEFT (pre-change) side.  A
--- deleted file has no new side, so it falls back to the old path.
---@param diff_lines string[]  output of `git diff --no-ext-diff -U3 base head`
---@return table  { [path] = { LEFT = {...}, RIGHT = {...} } }
function M.commentable_by_file(diff_lines)
  local out = {}
  local key, chunk, pending_old = nil, nil, nil

  local function flush()
    if key and chunk then out[key] = M.commentable(chunk) end
    key, chunk = nil, nil
  end

  for _, line in ipairs(diff_lines or {}) do
    if line:match('^diff %-%-git ') then
      flush()
      pending_old = nil
    elseif line:match('^%-%-%- ') then
      pending_old = line:match('^%-%-%- a/(.+)$')
    elseif line:match('^%+%+%+ ') then
      key = line:match('^%+%+%+ b/(.+)$') or pending_old
      chunk = {}
    elseif chunk then
      table.insert(chunk, line)
    end
  end
  flush()
  return out
end

-- ---------------------------------------------------------------------------
-- Pure: rendering the comment list
-- ---------------------------------------------------------------------------

local LOC_W, PATH_W = 11, 28

local function truncate(s, w)
  s = tostring(s or ''):gsub('[\r\n\t]+', ' ')
  if vim.fn.strdisplaywidth(s) <= w then return s end
  local out = s
  while vim.fn.strdisplaywidth(out) > math.max(1, w - 1) do
    out = vim.fn.strcharpart(out, 0, math.max(0, vim.fn.strchars(out) - 1))
  end
  return out .. '…'
end

local function pad(s, w)
  local d = w - vim.fn.strdisplaywidth(s)
  return d > 0 and (s .. string.rep(' ', d)) or s
end

--- Where a comment points, as a short cell: `R412`, `L88`, `R400-412`, `FILE`.
---@param c table
---@return string
function M.locator(c)
  if c.subject_type == 'file' then return 'FILE' end
  local s = (c.side == 'LEFT') and 'L' or 'R'
  if c.start_line and c.start_line ~= c.line then
    return string.format('%s%d-%d', s, c.start_line, c.line)
  end
  return string.format('%s%s', s, tostring(c.line or '?'))
end

--- The state marker.  Only agent proposals carry one: `?` awaiting a decision,
--- `✓` accepted.  A comment the user wrote needs no marker — it is going.
---@param c table
---@return string marker, string group
function M.marker(c)
  if c.origin ~= 'agent' then return ' ', 'AIAgentReviewMine' end
  if c.accepted then return '✓', 'AIAgentReviewAccepted' end
  return '?', 'AIAgentReviewProposed'
end

--- One row of the comment list.
--- Highlight ranges are BYTE offsets (extmarks want bytes) while the column
--- padding is computed in DISPLAY width — `✓` is three bytes and one cell, so
--- conflating the two slides every highlight after it.
---@param c table
---@param width integer
---@return string line, table[] hls  { col, end_col, group }
function M.format(c, width)
  local parts, hls, col = {}, {}, 0
  local function add(text, group)
    if group then
      table.insert(hls, { col = col, end_col = col + #text, group = group })
    end
    col = col + #text
    table.insert(parts, text)
  end

  local mark, mark_group = M.marker(c)
  add(mark .. ' ', mark_group)
  add(pad(truncate(M.locator(c), LOC_W), LOC_W) .. ' ', 'AIAgentReviewLoc')
  add(pad(truncate(c.path or '', PATH_W), PATH_W) .. ' ', 'AIAgentReviewPath')
  local avail = math.max(10, width - LOC_W - PATH_W - 5)
  add(truncate(c.body or '', avail), 'AIAgentReviewBody')

  return table.concat(parts), hls
end

--- Render a draft's comments.  Pure: returns lines, highlights and the row →
--- comment mapping, so it is unit tested without a window.
---@param draft table
---@param opts table|nil  { width: integer }
---@return string[] lines, table[] hls, table[] rows
function M.render(draft, opts)
  opts = opts or {}
  local width = opts.width or 80
  local lines, hls, rows = {}, {}, {}
  for i, c in ipairs((draft or {}).comments or {}) do
    local line, row_hls = M.format(c, width)
    lines[i] = line
    rows[i] = { comment = c }
    for _, h in ipairs(row_hls) do
      table.insert(hls, { line = i - 1, col = h.col, end_col = h.end_col, group = h.group })
    end
  end
  if #lines == 0 then
    lines = { '(no comments yet — gc on a line in the diff)' }
  end
  return lines, hls, rows
end

local function define_highlights()
  vim.api.nvim_set_hl(0, 'AIAgentReviewMine',     { link = 'Normal' })
  vim.api.nvim_set_hl(0, 'AIAgentReviewProposed', { link = 'WarningMsg' })
  vim.api.nvim_set_hl(0, 'AIAgentReviewAccepted', { link = 'DiffAdd' })
  vim.api.nvim_set_hl(0, 'AIAgentReviewLoc',      { link = 'Number' })
  vim.api.nvim_set_hl(0, 'AIAgentReviewPath',     { link = 'Identifier' })
  vim.api.nvim_set_hl(0, 'AIAgentReviewBody',     { link = 'Normal' })
  vim.api.nvim_set_hl(0, 'AIAgentReviewSign',     { link = 'Todo' })
end

-- ---------------------------------------------------------------------------
-- Fetching and checking out a PR
-- ---------------------------------------------------------------------------

--- Repo argument for gh: `owner/repo`, or `host/owner/repo` off github.com.
local function repo_arg(rem)
  if rem.host and rem.host ~= 'github.com' then
    return rem.host .. '/' .. rem.owner .. '/' .. rem.repo
  end
  return rem.owner .. '/' .. rem.repo
end

--- The worktree path for a PR review, following the plugin's existing
--- convention ($TMPDIR/nvim-agent-<repo>-<slug>) so it sits alongside agent
--- worktrees rather than inventing a second scheme.
---@param root string
---@param number integer|string
---@return string
function M.worktree_path(root, number)
  local tmp = (os.getenv('TMPDIR') or '/tmp'):gsub('/+$', '')
  local repo_name = (vim.fn.fnamemodify(root, ':t'):lower():gsub('[^%w]', '-'))
  return vim.fn.resolve(tmp) .. '/nvim-agent-' .. repo_name .. '-pr-' .. tostring(number)
end

--- Existing worktree checked out on a branch, by parsing `git worktree list
--- --porcelain`.  Matching on the branch rather than the path is the same
--- choice create_worktree() makes, and for the same reason: it is unaffected by
--- symlinks and directory moves.
---@return string|nil path
local function worktree_for_branch(root, branch)
  local out = git(root, 'worktree', 'list', '--porcelain')
  local cur = nil
  for _, l in ipairs(out) do
    local p = l:match('^worktree (.+)$')
    if p then cur = p end
    local b = l:match('^branch (.+)$')
    if b and b == 'refs/heads/' .. branch then return cur end
  end
  return nil
end

--- Read a PR's metadata from GitHub.
---@param number integer|string
---@param root string  a path inside the repo
---@return table|nil pr, string|nil err
function M.fetch(number, root)
  local rem = M.remote_for(root)
  if not rem then
    return nil, 'no GitHub remote found for ' .. root
  end

  local fields = table.concat({
    'number', 'title', 'body', 'url', 'state', 'isDraft', 'author',
    'headRefName', 'headRefOid', 'baseRefName', 'baseRefOid',
  }, ',')

  local out, ok, err = M.gh({ 'pr', 'view', tostring(number),
    '--repo', repo_arg(rem), '--json', fields })
  if not ok then
    local msg = (err ~= '' and err or out):gsub('%s+$', '')
    return nil, (msg ~= '' and msg or ('gh pr view failed for #' .. tostring(number)))
  end

  local decoded, data = pcall(vim.fn.json_decode, out)
  if not decoded or type(data) ~= 'table' or not data.number then
    return nil, 'could not read the PR metadata gh returned'
  end

  return {
    host      = rem.host,
    owner     = rem.owner,
    repo      = rem.repo,
    remote    = rem.remote,
    number    = data.number,
    title     = data.title or '',
    body      = data.body or '',
    url       = data.url,
    state     = data.state,
    is_draft  = data.isDraft,
    author    = (type(data.author) == 'table' and data.author.login) or nil,
    head_ref  = data.headRefName,
    head_sha  = data.headRefOid,
    base_ref  = data.baseRefName,
    git_root  = root,
  }, nil
end

--- Fetch the PR head and its base into local refs, resolve the merge base, and
--- put a worktree on the head.
---
--- `base_sha` is `git merge-base` output and NOT the base branch tip: GitHub's
--- PR diff is the three-dot diff, and using the tip instead makes every line
--- number wrong wherever base has moved on — silently, because the comments
--- still post.
---@param pr table  from M.fetch (mutated: base_sha, worktree, branch)
---@return boolean ok, string|nil err
function M.checkout(pr)
  local root = pr.git_root
  local refs = 'refs/aiagent/pr-' .. tostring(pr.number)

  -- `gh` being authenticated does NOT mean git is: gh talks to the API with its
  -- own token, while these fetches go through git's credentials for the remote
  -- URL.  An https remote on a private repo with no credential helper fails
  -- here even though everything above worked, so git's own message is passed
  -- through with the fix rather than swallowed behind "could not fetch".
  local function fetch_failed(what, out)
    local detail = table.concat(out or {}, '\n'):gsub('%s+$', '')
    local hint = ''
    if detail:match('could not read Username')
      or detail:match('Authentication failed')
      or detail:match('Permission denied') then
      hint = '\n\ngit cannot authenticate to the remote (gh being logged in is '
        .. 'separate). Fix it with one of:\n'
        .. '  gh auth setup-git          # use gh as git\'s credential helper\n'
        .. '  git remote set-url ' .. tostring(pr.remote) .. ' <ssh url>   # switch to ssh'
    end
    return false, 'could not fetch ' .. what
      .. (detail ~= '' and ('\n' .. detail) or '') .. hint
  end

  local out1, ok1 = git(root, 'fetch', '--no-tags', '--force', pr.remote,
    string.format('refs/pull/%s/head:%s/head', tostring(pr.number), refs))
  if not ok1 then
    return fetch_failed('refs/pull/' .. tostring(pr.number) .. '/head', out1)
  end

  local out2, ok2 = git(root, 'fetch', '--no-tags', '--force', pr.remote,
    string.format('%s:%s/base', pr.base_ref, refs))
  if not ok2 then
    return fetch_failed('the base branch ' .. tostring(pr.base_ref), out2)
  end

  local mb = git1(root, 'merge-base', refs .. '/base', refs .. '/head')
  if not mb then
    return false, 'could not resolve the merge base of ' .. tostring(pr.base_ref)
      .. ' and #' .. tostring(pr.number)
  end
  pr.base_sha = mb

  local branch = 'agent/pr-' .. tostring(pr.number)
  pr.branch = branch

  local existing = worktree_for_branch(root, branch)
  if existing then
    -- Worktrees are persistent in this plugin and may have an agent working in
    -- them, so an existing one is reused as-is rather than reset.  If it is
    -- behind, say so instead of quietly reviewing the wrong code.
    pr.worktree = existing
    local at = git1(existing, 'rev-parse', 'HEAD')
    if at and pr.head_sha and at ~= pr.head_sha then
      vim.notify(string.format(
        'AgentPR: worktree %s is at %s but the PR head is %s — reviewing the '
        .. 'checked-out code. Reset it with: git -C %s reset --hard %s/head',
        existing, at:sub(1, 8), pr.head_sha:sub(1, 8), existing, refs),
        vim.log.levels.WARN)
      pr.head_sha = at
    end
    return true, nil
  end

  local path = M.worktree_path(root, pr.number)
  local _, ok3 = git(root, 'worktree', 'add', '-B', branch, path, refs .. '/head')
  if not ok3 then
    return false, 'could not create the review worktree at ' .. path
  end
  pr.worktree = path
  return true, nil
end

--- Has the PR moved (or closed) since the draft pinned its head?
---@param draft table
---@return string|nil new_head, string|nil state, string|nil err
function M.head_moved(draft)
  local out, ok, err = M.gh({ 'pr', 'view', tostring(draft.number),
    '--repo', repo_arg(draft), '--json', 'headRefOid,state' })
  if not ok then
    return nil, nil, (err ~= '' and err or out):gsub('%s+$', '')
  end
  local decoded, data = pcall(vim.fn.json_decode, out)
  if not decoded or type(data) ~= 'table' then return nil, nil, 'unreadable gh output' end
  local moved = (data.headRefOid and data.headRefOid ~= draft.head_sha)
    and data.headRefOid or nil
  return moved, data.state, nil
end

--- Which of the draft's comments sit on lines that changed between the pinned
--- head and a newer one.  Reported at submit time so the user decides, rather
--- than silently retargeting commit_id at code the comment was not about.
---@param draft table
---@param new_head string
---@return table[] stale  the affected comments
function M.stale_comments(draft, new_head)
  local root = draft.worktree or draft.git_root
  local diff = gitdiff.unified(root, draft.head_sha, new_head, nil, 0)
  local touched = M.commentable_by_file(diff)
  local stale = {}
  for _, c in ipairs(draft.comments or {}) do
    local sets = touched[c.path]
    if sets then
      if c.subject_type == 'file' then
        table.insert(stale, c)
      else
        -- The comment's line is expressed against the pinned head, which is the
        -- OLD side of this head-to-head diff.
        for n = (c.start_line or c.line), c.line do
          if sets.LEFT[n] then table.insert(stale, c); break end
        end
      end
    end
  end
  return stale
end

-- ---------------------------------------------------------------------------
-- Submitting
-- ---------------------------------------------------------------------------

--- POST the review.  One call, all comments, no partial success — which is why
--- the draft is kept on failure and GitHub's error body is surfaced verbatim:
--- a 422 names the offending path and line, and that is exactly what is needed
--- to fix the one bad comment and retry.
---@param draft table
---@param event string|nil  APPROVE | REQUEST_CHANGES | COMMENT | nil (pending)
---@return boolean ok, string message, string|nil url
function M.submit(draft, event)
  local body = vim.fn.json_encode(M.payload(draft, event))
  local endpoint = string.format('repos/%s/%s/pulls/%s/reviews',
    draft.owner, draft.repo, tostring(draft.number))

  local args = { 'api', '--method', 'POST', endpoint, '--input', '-' }
  if draft.host and draft.host ~= 'github.com' then
    table.insert(args, 2, '--hostname')
    table.insert(args, 3, draft.host)
  end

  local out, ok = M.gh(args, body)
  if not ok then
    return false, (out or ''):gsub('%s+$', ''), nil
  end
  local decoded, data = pcall(vim.fn.json_decode, out)
  local url = (decoded and type(data) == 'table') and data.html_url or nil
  return true, 'review submitted', url
end

-- ---------------------------------------------------------------------------
-- Viewer
-- ---------------------------------------------------------------------------

-- The return-to-chat key comes first: it is the one a human most needs and
-- most easily forgets.  Same ordering rule as the prompt-history viewer.
local INSTRUCTIONS = {
  'PR REVIEW',
  'q        back to chat (draft is kept)',
  'gc / gC  comment on line / selection',
  'gf       comment on the whole file',
  'gb       edit the review summary',
  ']f / [f  next / prev changed file',
  ']c / [c  next / prev comment',
  'a / d    accept / delete a comment',
  'e        edit a comment',
  'gs       submit the review',
}

--- A modal text box.  Used instead of `vim.ui.input` for the same reason the
--- history tree uses its own menu: a cmdline prompt beside a busy agent
--- terminal is easy to miss, and a review comment is multi-line anyway.
---@param opts table  { title: string, text: string|nil }
---@param cb fun(text: string|nil)  nil on cancel
local function compose(opts, cb)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'markdown'
  local text = opts.text or ''
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, '\n', { plain = true }))

  local width  = math.min(92, math.max(40, vim.o.columns - 8))
  local height = math.min(16, math.max(6, math.floor(vim.o.lines * 0.4)))
  local title = ' ' .. (opts.title or 'Comment') .. '  (<C-s> save · <C-c> cancel) '

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    title = title,
    title_pos = 'center',
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  -- One-shot: the WinClosed fallback must not fire after a real answer.
  local done = false
  local function finish(val)
    if done then return end
    done = true
    if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
    vim.schedule(function() cb(val) end)
  end

  local function map(lhs, modes, fn)
    vim.keymap.set(modes, lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map('<C-s>', { 'n', 'i' }, function()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    finish(table.concat(lines, '\n'))
  end)
  map('<C-c>', { 'n', 'i' }, function() finish(nil) end)
  map('q', { 'n' }, function() finish(nil) end)

  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win),
    once = true,
    callback = function() finish(nil) end,
  })

  if text == '' then vim.cmd('startinsert') end
end

M._compose = compose

--- The file currently selected in the files pane.
local function current_file()
  local s = M.state
  return s and s.files[s.file_idx] or nil
end

--- Commentable-line sets for a path, computed once per draft and cached.
--- The SHAs are pinned, so the map cannot change underneath us — the same
--- reasoning that lets the session finder cache a rendered tree per session id.
local function allowed_for(path)
  local s = M.state
  if not s then return { LEFT = {}, RIGHT = {} } end
  if not s.allowed then
    local root = s.draft.worktree or s.draft.git_root
    local diff = gitdiff.unified(root, s.draft.base_sha, s.draft.head_sha, nil, 3)
    s.allowed = M.commentable_by_file(diff)
  end
  return s.allowed[path] or { LEFT = {}, RIGHT = {} }
end

local function render_instructions()
  local s = M.state
  local buf = vim.api.nvim_win_get_buf(s.wins.instructions)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, INSTRUCTIONS)
  vim.bo[buf].modifiable = false
end

local function render_files()
  local s = M.state
  if not vim.api.nvim_win_is_valid(s.wins.files) then return end
  local buf = vim.api.nvim_win_get_buf(s.wins.files)

  -- A count of the comments already on each file, so the list doubles as
  -- progress through the review.
  local counts = {}
  for _, c in ipairs(s.draft.comments) do
    counts[c.path] = (counts[c.path] or 0) + 1
  end

  local lines = {}
  if #s.files == 0 then
    lines = { '(no files changed)' }
  else
    for _, f in ipairs(s.files) do
      local n = counts[f.path]
      table.insert(lines, string.format('%s %s%s', f.status, f.path,
        n and string.format('  (%d)', n) or ''))
    end
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  if #s.files > 0 then
    pcall(vim.api.nvim_win_set_cursor, s.wins.files, { s.file_idx, 0 })
  end
end

local function render_comments()
  local s = M.state
  if not vim.api.nvim_win_is_valid(s.wins.comments) then return end
  local buf = vim.api.nvim_win_get_buf(s.wins.comments)
  local width = vim.api.nvim_win_get_width(s.wins.comments)
  local lines, hls, rows = M.render(s.draft, { width = width })
  s.rows = rows

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, h.line, h.col,
      { end_col = h.end_col, hl_group = h.group })
  end
end

--- Put a marker in the diff panes for every comment on the visible file, so
--- re-reading a file shows what you already said about it.
local function place_marks(bbuf, abuf)
  local s = M.state
  local file = current_file()
  if not file then return end
  for _, c in ipairs(s.draft.comments) do
    if c.path == file.path and c.subject_type ~= 'file' and c.line then
      local buf = (c.side == 'LEFT') and bbuf or abuf
      local mark = M.marker(c)
      if buf then
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, c.line - 1, 0, {
          virt_text = { { '  ' .. mark .. ' ' .. truncate(c.body, 58),
                          'AIAgentReviewSign' } },
          virt_text_pos = 'eol',
          sign_text = (c.origin == 'agent' and mark or '▌'),
          sign_hl_group = 'AIAgentReviewSign',
        })
      end
    end
  end
end

local function render_diff()
  local s = M.state
  local file = current_file()

  local before_lines, after_lines, bpath, apath
  if file then
    before_lines = gitdiff.show(s.draft.worktree, s.draft.base_sha, file.before_path)
    after_lines  = gitdiff.show(s.draft.worktree, s.draft.head_sha, file.after_path)
    bpath, apath = file.before_path, file.after_path
  else
    before_lines = { '(no files changed in this PR)' }
    after_lines  = { '(no files changed in this PR)' }
  end

  local bbuf, abuf = gitdiff.show_pair(s.wins,
    { lines = before_lines, path = bpath },
    { lines = after_lines,  path = apath })
  if not bbuf then return end

  for _, w in ipairs({ s.wins.before, s.wins.after }) do
    vim.wo[w].number = true
    vim.wo[w].signcolumn = 'yes'
  end
  local pos = file and string.format(' (%d/%d)', s.file_idx, #s.files) or ''
  vim.wo[s.wins.before].winbar = 'BASE  ' .. (bpath or '—') .. '   [LEFT]'
  vim.wo[s.wins.after].winbar  = 'HEAD  ' .. (apath or '—') .. '   [RIGHT]' .. pos

  place_marks(bbuf, abuf)
end

local function render_detail()
  local s = M.state
  if not vim.api.nvim_win_is_valid(s.wins.detail) then return end
  local buf = vim.api.nvim_win_get_buf(s.wins.detail)
  local d = s.draft
  local sub, pending = M.counts(d)

  local lines
  local c = s.sel_comment
  if c then
    lines = { string.format('%s  %s   [%s%s]',
      M.locator(c), c.path, c.origin,
      c.origin == 'agent' and (c.accepted and ', accepted' or ', proposed') or '') }
    vim.list_extend(lines, vim.split(c.body or '', '\n', { plain = true }))
  else
    lines = {
      string.format('#%s  %s', tostring(d.number), d.title or ''),
      string.format('%s  →  base %s   head %s',
        d.url or '', (d.base_sha or ''):sub(1, 8), (d.head_sha or ''):sub(1, 8)),
      string.format('%d comment(s) will be posted; %d proposal(s) awaiting a decision',
        sub, pending),
      '',
      'Review summary (gb to edit):',
    }
    vim.list_extend(lines, vim.split(d.body ~= '' and d.body or '(empty)', '\n',
      { plain = true }))
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

--- Redraw everything that depends on the draft.
local function refresh()
  if not M.state then return end
  render_files()
  render_comments()
  render_diff()
  render_detail()
end

M._refresh = refresh

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

--- The comment the cursor is on, or the one last selected.
local function comment_under_cursor()
  local s = M.state
  if not s then return nil end
  local w = vim.api.nvim_get_current_win()
  if w == s.wins.comments and s.rows then
    local row = vim.api.nvim_win_get_cursor(w)[1]
    return s.rows[row] and s.rows[row].comment or nil
  end
  return s.sel_comment
end

--- Add a comment at the cursor (or over a visual range) in a diff pane.
---@param range table|nil  { first_line, last_line } from a visual selection
function M.comment_here(range)
  local s = M.state
  if not s then return end
  local w = vim.api.nvim_get_current_win()
  local side
  if w == s.wins.before then side = 'LEFT'
  elseif w == s.wins.after then side = 'RIGHT'
  else
    vim.notify('AgentPR: put the cursor in a diff pane to comment on a line',
      vim.log.levels.WARN)
    return
  end

  local file = current_file()
  if not file then return end

  local last = range and range[2] or vim.api.nvim_win_get_cursor(w)[1]
  local first = range and range[1] or last

  local c = {
    path       = file.path,
    side       = side,
    line       = last,
    start_line = (first ~= last) and first or nil,
    start_side = (first ~= last) and side or nil,
    body       = 'x',   -- placeholder so validation checks the position first
  }

  -- Validate the POSITION before asking for text: refusing after the user has
  -- typed a paragraph is the rude version of the same error.
  local ok, err = M.validate(c, allowed_for(file.path))
  if not ok then
    vim.notify('AgentPR: ' .. err, vim.log.levels.WARN)
    return
  end

  compose({ title = string.format('Comment on %s %s', file.path, M.locator(c)) },
    function(text)
      if not text or text:gsub('%s', '') == '' then
        vim.notify('AgentPR: comment discarded', vim.log.levels.INFO)
        return
      end
      c.body = text
      M.add(s.draft, c)
      M.save(s.draft)
      refresh()
    end)
end

--- Add a file-level comment on the current file (no line).
function M.comment_file()
  local s = M.state
  if not s then return end
  local file = current_file()
  if not file then return end
  compose({ title = 'Comment on the whole file: ' .. file.path }, function(text)
    if not text or text:gsub('%s', '') == '' then return end
    M.add(s.draft, { path = file.path, subject_type = 'file', body = text })
    M.save(s.draft)
    refresh()
  end)
end

--- Edit the review summary — the `body` of the review itself.
function M.edit_body()
  local s = M.state
  if not s then return end
  compose({ title = 'Review summary', text = s.draft.body or '' }, function(text)
    if text == nil then return end
    s.draft.body = text
    M.save(s.draft)
    refresh()
  end)
end

--- Edit the comment under the cursor.
function M.edit_comment()
  local s = M.state
  local c = comment_under_cursor()
  if not s or not c then return end
  compose({ title = 'Edit ' .. M.locator(c) .. '  ' .. c.path, text = c.body },
    function(text)
      if text == nil then return end
      if text:gsub('%s', '') == '' then
        M.remove(s.draft, c.id)
      else
        c.body = text
      end
      M.save(s.draft)
      refresh()
    end)
end

--- Accept the agent proposal under the cursor.
function M.accept_here()
  local s = M.state
  local c = comment_under_cursor()
  if not s or not c then return end
  if c.origin ~= 'agent' then
    vim.notify('AgentPR: that comment is yours — it is already going',
      vim.log.levels.INFO)
    return
  end
  M.accept(s.draft, c.id, not c.accepted)
  M.save(s.draft)
  refresh()
end

--- Delete the comment under the cursor.
function M.delete_here()
  local s = M.state
  local c = comment_under_cursor()
  if not s or not c then return end
  M.remove(s.draft, c.id)
  if s.sel_comment == c then s.sel_comment = nil end
  M.save(s.draft)
  refresh()
end

--- Move to the next/previous comment, selecting its file and parking the diff
--- cursor on its line.
---@param delta integer  +1 or -1
function M.goto_comment(delta)
  local s = M.state
  if not s then return end
  local n = #s.draft.comments
  if n == 0 then
    vim.notify('AgentPR: no comments yet', vim.log.levels.INFO)
    return
  end
  local i = (s.comment_idx or 0) + delta
  if i < 1 then i = n elseif i > n then i = 1 end
  s.comment_idx = i

  local c = s.draft.comments[i]
  s.sel_comment = c
  for fi, f in ipairs(s.files) do
    if f.path == c.path then s.file_idx = fi break end
  end

  s.guard = true
  refresh()
  pcall(vim.api.nvim_win_set_cursor, s.wins.comments, { i, 0 })
  if c.line and c.subject_type ~= 'file' then
    local w = (c.side == 'LEFT') and s.wins.before or s.wins.after
    pcall(vim.api.nvim_win_set_cursor, w, { c.line, 0 })
  end
  s.guard = false
end

function M.next_file()
  local s = M.state
  if not s or #s.files == 0 then return end
  s.file_idx = math.min(s.file_idx + 1, #s.files)
  s.sel_comment = nil
  refresh()
end

function M.prev_file()
  local s = M.state
  if not s or #s.files == 0 then return end
  s.file_idx = math.max(s.file_idx - 1, 1)
  s.sel_comment = nil
  refresh()
end

-- ---------------------------------------------------------------------------
-- Submit flow
-- ---------------------------------------------------------------------------

local EVENTS = {
  { label = 'Comment  (post the review with no verdict)', event = 'COMMENT' },
  { label = 'Request changes',                            event = 'REQUEST_CHANGES' },
  { label = 'Approve',                                    event = 'APPROVE' },
  { label = 'Leave PENDING on GitHub (draft, only you see it)', event = nil },
}

--- GitHub rejects a blank body on these two, so ask for one rather than
--- collecting a 422 after the round trip.
local function needs_body(event)
  return event == 'COMMENT' or event == 'REQUEST_CHANGES'
end

local function do_submit(draft, event)
  local ok, msg, url = M.submit(draft, event)
  if not ok then
    vim.notify('AgentPR: the review was NOT posted — your draft is kept.\n' .. msg,
      vim.log.levels.ERROR)
    return
  end
  M.discard(draft)
  local where = url or (draft.url or '')
  vim.notify('AgentPR: ' .. msg .. (where ~= '' and ('\n' .. where) or ''),
    vim.log.levels.INFO)
  M.close()
end

--- Submit the open draft: staleness check, verdict, body, one POST.
function M.submit_flow()
  local s = M.state
  if not s then
    vim.notify('AgentPR: no review open', vim.log.levels.WARN)
    return
  end
  local draft = s.draft
  local menu = require('aiagent.history').menu

  local sub, pending = M.counts(draft)
  if sub == 0 and (draft.body or '') == '' then
    vim.notify('AgentPR: nothing to submit — no comments and no summary',
      vim.log.levels.WARN)
    return
  end

  local function choose_event()
    local items = {}
    for _, e in ipairs(EVENTS) do table.insert(items, e.label) end
    menu(items, {
      title = string.format('Submit review of #%s — %d comment(s)',
        tostring(draft.number), sub),
    }, function(idx)
      if not idx then
        vim.notify('AgentPR: submit cancelled — draft kept', vim.log.levels.INFO)
        return
      end
      local event = EVENTS[idx].event
      if needs_body(event) and (draft.body or ''):gsub('%s', '') == '' then
        compose({ title = 'Review summary (required for this verdict)' }, function(text)
          if not text or text:gsub('%s', '') == '' then
            vim.notify('AgentPR: submit cancelled — a summary is required',
              vim.log.levels.WARN)
            return
          end
          draft.body = text
          M.save(draft)
          do_submit(draft, event)
        end)
      else
        do_submit(draft, event)
      end
    end)
  end

  local function after_pending()
    local moved, state, err = M.head_moved(draft)
    if err then
      vim.notify('AgentPR: could not check whether the PR moved (' .. err ..
        ') — submitting against the pinned head', vim.log.levels.WARN)
      return choose_event()
    end
    if state and state ~= 'OPEN' then
      vim.notify('AgentPR: PR #' .. tostring(draft.number) .. ' is ' ..
        tostring(state) .. ' — a review cannot be posted', vim.log.levels.ERROR)
      return
    end
    if not moved then return choose_event() end

    local stale = M.stale_comments(draft, moved)
    menu({
      'Submit anyway (comments post against the head you reviewed)',
      'Cancel and keep the draft',
    }, {
      title = string.format('#%s has moved: %d of %d comment(s) touch changed lines',
        tostring(draft.number), #stale, #draft.comments),
    }, function(idx)
      if idx == 1 then choose_event()
      else vim.notify('AgentPR: submit cancelled — draft kept', vim.log.levels.INFO) end
    end)
  end

  if pending > 0 then
    menu({
      string.format('Submit %d comment(s), leaving %d proposal(s) behind', sub, pending),
      'Cancel — go and triage the proposals (a accepts, d deletes)',
    }, { title = pending .. ' agent proposal(s) not yet accepted' }, function(idx)
      if idx == 1 then after_pending()
      else vim.notify('AgentPR: submit cancelled', vim.log.levels.INFO) end
    end)
  else
    after_pending()
  end
end

-- ---------------------------------------------------------------------------
-- Window construction
-- ---------------------------------------------------------------------------

local function make_panel_buf(name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, name)
  return buf
end

--- Build the layout in a new tabpage, so the agent terminal in aiagent.M.win is
--- never disturbed and closing the tab returns to chat:
---
---   +----------+---------------------+---------------------+
---   | help     |  BASE  (LEFT)       |  HEAD  (RIGHT)      |
---   +----------+                     |                     |
---   | files    |     :diffthis pair  |                     |
---   +----------+                     |                     |
---   | comments |                     |                     |
---   +----------+---------------------+---------------------+
---   | detail: the selected comment, else the PR + summary   |
---   +-------------------------------------------------------+
local function build_layout()
  vim.cmd('tabnew')
  local tab = vim.api.nvim_get_current_tabpage()

  local diff_area = vim.api.nvim_get_current_win()
  vim.cmd('topleft vsplit')
  local instructions = vim.api.nvim_get_current_win()
  vim.cmd('belowright split')
  local files = vim.api.nvim_get_current_win()
  vim.cmd('belowright split')
  local comments = vim.api.nvim_get_current_win()

  vim.api.nvim_set_current_win(diff_area)
  vim.cmd('belowright split')
  local detail = vim.api.nvim_get_current_win()

  vim.api.nvim_set_current_win(diff_area)
  local before = diff_area
  vim.cmd('rightbelow vsplit')
  local after = vim.api.nvim_get_current_win()

  vim.api.nvim_win_set_buf(instructions, make_panel_buf('pr-review://help'))
  vim.api.nvim_win_set_buf(files,        make_panel_buf('pr-review://files'))
  vim.api.nvim_win_set_buf(comments,     make_panel_buf('pr-review://comments'))
  vim.api.nvim_win_set_buf(detail,       make_panel_buf('pr-review://detail'))

  for _, w in ipairs({ instructions, files, comments }) do
    vim.wo[w].number = false
    vim.wo[w].relativenumber = false
    vim.wo[w].winfixwidth = true
  end
  vim.wo[files].cursorline = true
  vim.wo[files].winbar = 'CHANGED FILES'
  vim.wo[comments].cursorline = true
  vim.wo[comments].winbar = 'REVIEW COMMENTS'
  vim.wo[detail].number = false
  vim.wo[detail].relativenumber = false
  vim.wo[detail].wrap = true
  vim.wo[detail].linebreak = true
  vim.wo[detail].winbar = 'DETAIL'

  -- Left column at 32%; help and files fixed so the comment list absorbs the
  -- slack, detail fixed at 8 lines.
  vim.api.nvim_win_set_width(instructions, math.floor(vim.o.columns * 0.32))
  vim.api.nvim_win_set_height(instructions, #INSTRUCTIONS)
  vim.wo[instructions].winfixheight = true
  vim.api.nvim_win_set_height(files, 10)
  vim.wo[files].winfixheight = true
  vim.api.nvim_win_set_height(detail, 8)
  vim.wo[detail].winfixheight = true
  vim.cmd('wincmd =')

  return { tab = tab, instructions = instructions, files = files,
           comments = comments, before = before, after = after, detail = detail }
end

local function set_keymaps(buf, is_diff_pane)
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set('n', 'q',  function() M.close() end, opts)
  vim.keymap.set('n', ']f', function() M.next_file() end, opts)
  vim.keymap.set('n', '[f', function() M.prev_file() end, opts)
  vim.keymap.set('n', ']c', function() M.goto_comment(1) end, opts)
  vim.keymap.set('n', '[c', function() M.goto_comment(-1) end, opts)
  vim.keymap.set('n', 'gb', function() M.edit_body() end, opts)
  vim.keymap.set('n', 'gs', function() M.submit_flow() end, opts)
  vim.keymap.set('n', 'gf', function() M.comment_file() end, opts)
  vim.keymap.set('n', 'a',  function() M.accept_here() end, opts)
  vim.keymap.set('n', 'd',  function() M.delete_here() end, opts)
  vim.keymap.set('n', 'e',  function() M.edit_comment() end, opts)
  vim.keymap.set('n', '<CR>', function() M.edit_comment() end, opts)

  if is_diff_pane then
    vim.keymap.set('n', 'gc', function() M.comment_here() end, opts)
    -- Capture the selection's bounds BEFORE leaving visual mode; opening the
    -- compose float would clear it.
    vim.keymap.set('x', 'gC', function()
      local a, b = vim.fn.line('v'), vim.fn.line('.')
      vim.cmd('normal! \27')
      M.comment_here({ math.min(a, b), math.max(a, b) })
    end, opts)
  end
end

-- ---------------------------------------------------------------------------
-- Open / close
-- ---------------------------------------------------------------------------

--- Repo root containing dir, or nil.
---@param dir string|nil
---@return string|nil
function M.git_root(dir)
  return git1(dir or vim.fn.getcwd(), 'rev-parse', '--show-toplevel')
end

--- Open the review viewer on a PR.  Fetches metadata, puts a worktree on the
--- head, loads or creates the draft, and builds the layout.
---
--- When a draft already exists and the PR has moved on since, the review stays
--- PINNED to the head the draft was written against: the stored comment lines
--- refer to that head, and reviewing at a newer one would show the user
--- different code from the one their comments point at.
---@param number integer|string
---@param opts table|nil  { dir: string|nil }
---@return boolean ok
function M.open(number, opts)
  opts = opts or {}
  local root = M.git_root(opts.dir)
  if not root then
    vim.notify('AgentPR: not in a git repository', vim.log.levels.ERROR)
    return false
  end

  vim.notify('AgentPR: fetching #' .. tostring(number) .. ' …', vim.log.levels.INFO)
  local pr, err = M.fetch(number, root)
  if not pr then
    vim.notify('AgentPR: ' .. tostring(err), vim.log.levels.ERROR)
    return false
  end

  local existing = M.load(pr)
  if existing and existing.head_sha and existing.head_sha ~= pr.head_sha then
    vim.notify(string.format(
      'AgentPR: #%s has moved since your draft — reviewing the head you started '
      .. 'on (%s). :AgentPRSubmit will tell you which comments are affected.',
      tostring(pr.number), existing.head_sha:sub(1, 8)), vim.log.levels.WARN)
    pr.pin = existing.head_sha
  end

  local ok, cerr = M.checkout(pr)
  if not ok then
    vim.notify('AgentPR: ' .. tostring(cerr), vim.log.levels.ERROR)
    return false
  end

  local draft = existing or M.new_draft(pr)
  draft.head_sha = pr.head_sha
  draft.base_sha = pr.base_sha
  draft.worktree = pr.worktree
  draft.git_root = root
  draft.title    = pr.title
  draft.url      = pr.url
  M.save(draft)

  if M.state then M.close() end
  define_highlights()

  local source_win = vim.api.nvim_get_current_win()
  local wins = build_layout()

  M.state = {
    draft       = draft,
    pr          = pr,
    files       = gitdiff.changed_files(pr.worktree, draft.base_sha, draft.head_sha),
    file_idx    = 1,
    comment_idx = 0,
    sel_comment = nil,
    allowed     = nil,   -- computed lazily on the first comment
    wins        = wins,
    source_win  = source_win,
    guard       = false,
  }

  for _, w in ipairs({ wins.instructions, wins.files, wins.comments, wins.detail }) do
    set_keymaps(vim.api.nvim_win_get_buf(w), false)
  end
  render_instructions()

  -- The diff panes get fresh buffers on every redraw, so their keymaps are set
  -- after each render rather than once here.
  local group = vim.api.nvim_create_augroup('AIAgentPRReview', { clear = true })
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    callback = function(ev)
      local s = M.state
      if not s then return end
      local w = vim.fn.bufwinid(ev.buf)
      if w == s.wins.before or w == s.wins.after then
        set_keymaps(ev.buf, true)
      end
    end,
  })

  -- CursorMoved in the files pane selects a file; in the comments pane it
  -- selects a comment (which updates the detail pane).
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = group,
    callback = function()
      local s = M.state
      if not s or s.guard then return end
      local w = vim.api.nvim_get_current_win()
      if w == s.wins.files then
        local row = vim.api.nvim_win_get_cursor(w)[1]
        if #s.files > 0 and row ~= s.file_idx then
          s.guard = true
          s.file_idx = math.min(row, #s.files)
          s.sel_comment = nil
          refresh()
          s.guard = false
        end
      elseif w == s.wins.comments then
        local row = vim.api.nvim_win_get_cursor(w)[1]
        local c = s.rows and s.rows[row] and s.rows[row].comment
        if c and c ~= s.sel_comment then
          s.guard = true
          s.comment_idx = row
          s.sel_comment = c
          render_detail()
          s.guard = false
        end
      end
    end,
  })

  refresh()
  -- The diff panes exist before the first BufWinEnter fires for them, so wire
  -- their keymaps directly too.
  set_keymaps(vim.api.nvim_win_get_buf(wins.before), true)
  set_keymaps(vim.api.nvim_win_get_buf(wins.after), true)
  vim.api.nvim_set_current_win(wins.after)
  return true
end

--- Close the viewer.  The draft is deliberately NOT discarded — a review in
--- progress survives closing the tab, closing Neovim, and rebooting.
function M.close()
  local s = M.state
  if not s then return end
  M.state = nil
  pcall(vim.api.nvim_del_augroup_by_name, 'AIAgentPRReview')
  if s.wins.tab and vim.api.nvim_tabpage_is_valid(s.wins.tab) then
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(s.wins.tab)) do
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  if s.source_win and vim.api.nvim_win_is_valid(s.source_win) then
    pcall(vim.api.nvim_set_current_win, s.source_win)
  end
end

-- ---------------------------------------------------------------------------
-- Picking a PR
-- ---------------------------------------------------------------------------

--- Choose an open PR to review.  Uses the plugin's own menu float rather than
--- `vim.ui.select`, for the reason recorded in the history-tree notes: a
--- cmdline prompt beside a busy agent terminal is easy to miss, and a user's
--- select handler is often a filtering picker where typing filters instead of
--- choosing.
function M.pick()
  local root = M.git_root()
  if not root then
    vim.notify('AgentPR: not in a git repository', vim.log.levels.ERROR)
    return
  end
  local rem = M.remote_for(root)
  if not rem then
    vim.notify('AgentPR: no GitHub remote found', vim.log.levels.ERROR)
    return
  end

  local out, ok, err = M.gh({ 'pr', 'list', '--repo', repo_arg(rem), '--limit', '20',
    '--json', 'number,title,author,isDraft' })
  if not ok then
    vim.notify('AgentPR: ' .. ((err ~= '' and err or out):gsub('%s+$', '')),
      vim.log.levels.ERROR)
    return
  end
  local decoded, data = pcall(vim.fn.json_decode, out)
  if not decoded or type(data) ~= 'table' or #data == 0 then
    vim.notify('AgentPR: no open pull requests', vim.log.levels.INFO)
    return
  end

  local items, numbers = {}, {}
  for i, pr in ipairs(data) do
    local who = (type(pr.author) == 'table' and pr.author.login) or '?'
    items[i] = string.format('#%-5s %s  (%s)%s', tostring(pr.number),
      truncate(pr.title or '', 60), who, pr.isDraft and '  [draft]' or '')
    numbers[i] = pr.number
  end

  require('aiagent.history').menu(items, { title = 'Review a pull request' },
    function(idx)
      if idx and numbers[idx] then M.open(numbers[idx]) end
    end)
end

-- ---------------------------------------------------------------------------
-- Agent entry point
-- ---------------------------------------------------------------------------

--- Record an agent-proposed comment.  Driven from a running agent via
---   nvim --server "$NVIM" --remote-expr "luaeval(...)"
--- so the agent can read the diff and suggest comments straight into the draft.
---
--- Everything it writes lands as `origin = "agent"`, `accepted = false`, and
--- M.submittable filters those out — so an agent can propose, and only a human
--- can post.  That is the whole safety property of the feature.
---@param spec table  { number?, path, side?, line?, start_line?, body, subject_type? }
---@return string  a one-line result, for the agent to read back
function M.propose(spec)
  if type(spec) ~= 'table' then return 'error: expected a table' end

  local draft = M.state and M.state.draft or nil
  if not draft then
    local root = M.git_root()
    local rem = root and M.remote_for(root)
    if not rem or not spec.number then
      return 'error: no review open; pass number= or run :AgentPR <n> first'
    end
    rem.number = spec.number
    draft = M.load(rem)
    if not draft then
      return 'error: no draft for #' .. tostring(spec.number) .. '; run :AgentPR ' ..
        tostring(spec.number) .. ' first'
    end
  end

  local c = {
    path         = spec.path,
    side         = spec.side or 'RIGHT',
    line         = tonumber(spec.line),
    start_line   = tonumber(spec.start_line),
    start_side   = spec.start_side or spec.side or 'RIGHT',
    subject_type = spec.subject_type,
    body         = spec.body,
    origin       = 'agent',
    accepted     = false,
  }
  if c.start_line and c.start_line == c.line then
    c.start_line, c.start_side = nil, nil
  end

  -- Validate against the same map the interactive path uses, so an agent
  -- cannot inject a comment that would 422 the whole review at submit time.
  local sets
  if M.state then
    sets = allowed_for(c.path)
  else
    local diff = gitdiff.unified(draft.worktree or draft.git_root,
      draft.base_sha, draft.head_sha, nil, 3)
    sets = M.commentable_by_file(diff)[c.path] or { LEFT = {}, RIGHT = {} }
  end

  local ok, err = M.validate(c, sets)
  if not ok then return 'rejected: ' .. err end

  M.add(draft, c)
  M.save(draft)
  if M.state and M.state.draft == draft then
    pcall(refresh)
  end
  return string.format('proposed %s on %s (id %s) — awaiting your review',
    M.locator(c), c.path, c.id)
end

-- ---------------------------------------------------------------------------
-- Agent primer
-- ---------------------------------------------------------------------------

--- Build the text that briefs an agent on a PR and tells it how to propose
--- comments.  Typed into the agent WITHOUT submitting (the same
--- type-don't-submit path as send_diagnostics), so the user reads it and
--- presses Enter.
---
--- The diff is generated with `--no-ext-diff` — the house rule; a configured
--- external difftool would otherwise decide what the agent sees.
---@param draft table
---@param files table[]|nil  changed files (recomputed when omitted)
---@return string|nil text, string|nil err
function M.build_primer(draft, files)
  if not draft then return nil, 'no review draft' end
  local root = draft.worktree or draft.git_root
  if not root then return nil, 'the draft has no worktree' end

  files = files or gitdiff.changed_files(root, draft.base_sha, draft.head_sha)
  local diff = gitdiff.unified(root, draft.base_sha, draft.head_sha, nil, 3)

  local p = {}
  local function add(s) table.insert(p, s) end

  add(string.format('# Review pull request #%s: %s',
    tostring(draft.number), draft.title or ''))
  add('')
  if draft.url and draft.url ~= '' then add(draft.url) end
  add(string.format('Base %s .. head %s (%d file(s) changed)',
    (draft.base_sha or ''):sub(1, 8), (draft.head_sha or ''):sub(1, 8), #files))
  add('')
  add('Read the diff below and propose review comments. For each one, call:')
  add('')
  add('```bash')
  add('nvim --server "$NVIM" --remote-expr \'')
  add('  \'luaeval("require(\\"aiagent\\").pr_comment(_A)", {')
  add('     path = "lua/aiagent/init.lua", side = "RIGHT", line = 412,')
  add('     body = "what is wrong and what to do about it" })\'')
  add('```')
  add('')
  add('Rules the call enforces, so read them before writing any:')
  add('')
  add('- `side = "RIGHT"` with a line number in the NEW file (the `+` side), or')
  add('  `side = "LEFT"` with a line number in the OLD file. Read the numbers off')
  add('  the `@@ -old,n +new,n @@` hunk headers in the diff below.')
  add('- The line MUST be inside a hunk (changed or context). Anything else is')
  add('  rejected with a message saying so — fix the line and call again.')
  add('- Add `start_line = N` for a multi-line comment; both ends, same side.')
  add('- Omit line/side and pass `subject_type = "file"` for a whole-file note.')
  add('- `path` is the file\'s path on the NEW side, even for a LEFT comment.')
  add('')
  add('Every comment you propose is recorded as a PROPOSAL and is NOT posted to')
  add('GitHub. The user accepts or deletes each one in the review viewer and')
  add('submits the review themselves. Propose the ones worth a reviewer\'s time:')
  add('correctness bugs, missed edge cases, things that will break under load or')
  add('at a boundary. Do not comment on style the diff is already consistent with.')
  add('')
  add('## Changed files')
  add('')
  if #files == 0 then
    add('(none)')
  else
    for _, f in ipairs(files) do
      add(string.format('  %s  %s', f.status, f.path))
    end
  end
  add('')
  add('## Diff')
  add('')
  add('```diff')
  for _, l in ipairs(diff) do add(l) end
  add('```')

  return table.concat(p, '\n'), nil
end

return M
