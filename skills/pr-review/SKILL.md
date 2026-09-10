---
name: pr-review
description: Propose review comments on a GitHub pull request being reviewed in neovim. Use when the user is reviewing a PR locally (":AgentPR"), asks you to look over a pull request, suggest review comments, critique a diff, or check a PR for bugs. Comments you propose are recorded as PROPOSALS in the user's local draft and are never posted — the user accepts them and submits the review. Requires the AIAgent neovim plugin.
---

# PR Review

The user reviews a pull request inside neovim: `:AgentPR 123` checks the PR head
out into a worktree, opens a before|after diff viewer, and keeps a **local draft
review** on disk. You can write comments into that draft.

**Everything you propose is a proposal.** It lands with `origin = "agent"` and
`accepted = false`, it is marked `?` in the user's comment list, and it is
filtered out of the submitted payload until a human presses `a` on it. You
cannot post to GitHub. Say what you think; the user decides.

## Prerequisites (check once)

- `$NVIM` must be set — confirms you are running inside the AIAgent neovim.
- A review must be open. If a call comes back `error: no review open`, tell the
  user to run `:AgentPR <number>` and stop; do not try to open it yourself.

## Proposing a comment

One call per comment:

```bash
nvim --server "$NVIM" --remote-expr \
  'luaeval("require(\"aiagent\").pr_comment(_A)", {
     path = "lua/aiagent/init.lua",
     side = "RIGHT",
     line = 412,
     body = "chansend returns 0 on a closed channel, and the pcall around it
             only catches a throw — this reports success on a dead terminal."
   })'
```

It prints one line back. Read it:

- `proposed R412 on <path> (id c3) — awaiting your review` — recorded.
- `rejected: line 412 of <path> is not part of this PR's diff` — **fix the line
  and call again.** This is the common one; see the rules below.
- `error: ...` — something structural; report it to the user rather than retrying.

### The fields

| Field | Meaning |
|-------|---------|
| `path` | The file's path **on the new side**, even for a `LEFT` comment. |
| `side` | `"RIGHT"` for a line in the new file (the `+` side), `"LEFT"` for the old file. |
| `line` | The line number on that side. |
| `start_line` | Optional. Start of a multi-line comment; both ends must be on the same side. |
| `subject_type` | Pass `"file"` (with no `line`/`side`) for a comment about the whole file. |
| `body` | The comment text. Markdown is fine. |

### The one rule that will bite you

**The line must be inside a diff hunk** — changed or context. GitHub rejects
anything else, and it rejects the *entire review* when it does, so the plugin
refuses such a comment up front rather than letting it poison the submit.

Read line numbers off the hunk headers:

```
@@ -412,7 +412,9 @@ local function send_to_terminal(agent_name, text)
        │  │      │  │
        │  │      │  └── 9 lines from 412 on the NEW side  → side = "RIGHT", line 412..420
        │  │      └───── new start
        │  └──────────── 7 lines from 412 on the OLD side  → side = "LEFT",  line 412..418
        └─────────────── old start
```

A count is omitted when it is 1 (`@@ -5 +5,3 @@`). A count of 0 means that side
has no lines in the hunk at all — a pure insertion is `-12,0`, so there is no
`LEFT` line to comment on.

## Getting the diff

The primer from `:AgentPRReview` already contains the diff. If you need it
again, read it from the review worktree — **always with `--no-ext-diff`**, or a
configured external difftool will decide what you see:

```bash
git -C <worktree> diff --no-ext-diff -U3 <base_sha> <head_sha>
```

`:AgentPRReview` names the worktree and both SHAs. Never use a plain `git diff`.

## What is worth a comment

The user is spending their reviewing attention on what you flag, so spend it
well:

- **Correctness.** Wrong results, unhandled errors, races, resource leaks, off-by-one.
- **Edge cases the diff forgot.** Empty input, one element, the boundary, a
  failure of the thing being called.
- **Consequences the author may not have seen.** A changed contract with another
  caller, a migration this needs, a performance cliff at scale.
- **Things that will be expensive to change later** — a data format, a public
  signature, an API shape.

Not worth a comment: style the surrounding code is already consistent with,
preferences with no defect behind them, restating what the diff plainly does, or
praise. If a file has nothing wrong with it, say nothing about that file.

Write each comment as the reviewer would: what is wrong, and what would be
right. One concern per comment, anchored on the line it is about.

## After proposing

Tell the user what you proposed and where — a short list, one line each — and
remind them the comments are in the viewer's list awaiting `a` (accept), `e`
(edit) or `d` (delete), and that `gs` submits the review.
