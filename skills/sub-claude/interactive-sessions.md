# Interactive Sessions

## Terminal Interaction

For interactive sessions or when you need to poke at a running Claude:

```bash
sub-claude key "$id" Escape            # interrupt, dismiss menu
sub-claude key "$id" Enter             # confirm
sub-claude input "$id" "some message"  # type text + Enter
sub-claude capture "$id"               # see current terminal state
```

`input` on an **idle** (finished) session sends text but warns it won't be tracked as a job — use `followup` instead for new prompts.

`attach` opens the tmux pane for direct observation. Both you and `sub-claude` can type — avoid typing while Claude is actively sending keys or outputs will interleave.

## Pin / Unpin

Prevents a slot from being reclaimed (offloaded) while you're in the middle of an interactive sequence — menus, multi-step key flows, anything where losing the slot mid-action would break the interaction.

```bash
sub-claude pin "$id"        # default: 120 seconds
sub-claude pin "$id" 300    # 5 minutes
sub-claude unpin "$id"      # release immediately
```

**Don't pin for basic messaging.** `followup` handles offloaded sessions automatically. Pin only when you're sending a sequence of `key`/`input` commands that must land in the same session without interruption.

## Session Isolation

Each Claude instance only sees the jobs it started:

- `list` / `wait` / `clean` — default: **direct children only**
- `--tree` — includes all descendants (children of children)
- `--all` — every session across all Claude instances in this directory

> `--tree` and `--all` touch sessions from **other Claude instances**. Use sparingly — most workflows should only manage direct children.

Job IDs are scoped to the caller. The pool identifies callers by walking the process tree to the nearest parent `claude` process (PID + start time). Sessions started from a standalone terminal share a `"standalone"` scope.
