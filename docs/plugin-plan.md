# Plan: Extract sub-claude into a Claude Code Plugin

## Goal

Package skills and hooks that currently live in dotfiles into a proper Claude Code plugin **within this repo**. Same repo houses both the CLI tool and the plugin — two concerns, zero conflict. The plugin system only reads `.claude-plugin/`, `skills/`, `hooks/hooks.json` and ignores everything else.

## What moves into the plugin

| Component | Current location (dotfiles) | Plugin location |
|-----------|---------------------------|-----------------|
| Skill: SKILL.md | `config/claude/skills/sub-claude/SKILL.md` | `skills/sub-claude/SKILL.md` |
| Skill: pool-management.md | `config/claude/skills/sub-claude/pool-management.md` | `skills/sub-claude/pool-management.md` |
| Skill: interactive-sessions.md | `config/claude/skills/sub-claude/interactive-sessions.md` | `skills/sub-claude/interactive-sessions.md` |
| Hook: done signal | `config/claude/hooks/sub-claude-done.sh` | `hooks/sub-claude-done.sh` (already here) |
| Hook: guardrails | `config/claude/hooks/sub-claude-guardrails.sh` | `hooks/sub-claude-guardrails.sh` (new) |
| Hook wiring | `config/claude/settings.json` (2 PreToolUse entries) | `hooks/hooks.json` (new) |

## Plugin structure (additions to repo)

```
sub-claude/                        # repo root = plugin root
├── .claude-plugin/
│   └── plugin.json                # NEW — manifest
├── skills/
│   └── sub-claude/                # NEW — skill docs (from dotfiles)
│       ├── SKILL.md
│       ├── pool-management.md
│       └── interactive-sessions.md
├── hooks/
│   ├── hooks.json                 # NEW — hook wiring config
│   ├── sub-claude-done.sh         # EXISTS — no change
│   └── sub-claude-guardrails.sh   # NEW — from dotfiles
├── bin/                           # unchanged (CLI binary)
├── lib/                           # unchanged (shell libraries)
├── install.sh                     # unchanged (CLI installer)
├── tests/                         # unchanged
└── ...
```

## Phase 1: Build the plugin (this PR)

### Step 1 — Create `.claude-plugin/plugin.json`

```json
{
  "name": "sub-claude",
  "description": "Session-oriented pool of persistent Claude TUI slots backed by tmux",
  "version": "0.1.0",
  "author": {
    "name": "Elias Schlie"
  },
  "repository": "https://github.com/EliasSchlie/sub-claude",
  "license": "MIT"
}
```

### Step 2 — Create `skills/sub-claude/`

Copy the 3 skill markdown files from dotfiles. These are the canonical source of Claude-facing documentation.

Add a new sub-skill `installation.md` — linked from SKILL.md's sub-skills table. Contains:
- How to check if CLI is installed (`command -v sub-claude`)
- Installation steps (`git clone` + `./install.sh`)
- Verification (`sub-claude --help`)
- Claude should check this sub-skill when `sub-claude` command fails with "not found"

### Step 3 — Add `hooks/sub-claude-guardrails.sh`

Copy from dotfiles `config/claude/hooks/sub-claude-guardrails.sh`.

### Step 4 — Create `hooks/hooks.json`

Inline the done hook (1 line). For guardrails, reference the script — test whether plugin hooks can resolve sibling scripts. Fallback: inline.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "EnterPlanMode",
        "hooks": [{ "type": "command", "command": "..." }]
      },
      {
        "matcher": "AskUserQuestion",
        "hooks": [{ "type": "command", "command": "..." }]
      },
      {
        "matcher": "EnterWorktree|Bash",
        "hooks": [{ "type": "command", "command": "..." }]
      }
    ]
  }
}
```

### Step 5 — Update docs

- **README.md**: add plugin installation section (separate from CLI install)
- **CLAUDE.md**: mention plugin structure

### Step 6 — Test with `--plugin-dir`

```bash
claude --plugin-dir .
```

Verify: skills show up namespaced as `/sub-claude:sub-claude`, hooks fire on expected events.

## Phase 2: Dotfiles cleanup (separate PR in dotfiles repo)

After confirming the plugin works:

1. Remove `config/claude/skills/sub-claude/` (3 files)
2. Remove `config/claude/hooks/sub-claude-done.sh`
3. Remove `config/claude/hooks/sub-claude-guardrails.sh`
4. Remove sub-claude hook entries from `config/claude/settings.json`:
   - The `sub-claude-done.sh` line from the `ExitPlanMode|AskUserQuestion` matcher
   - The entire `EnterWorktree|Bash` matcher (only has sub-claude guardrails)
5. Add marketplace + plugin config to `config/claude/settings.json`:
   ```json
   {
     "extraKnownMarketplaces": {
       "elias-tools": {
         "source": { "source": "github", "repo": "EliasSchlie/claude-plugins" }
       }
     },
     "enabledPlugins": {
       "sub-claude@elias-tools": true
     }
   }
   ```
6. Run `deploy.sh` to propagate

## Phase 3: Marketplace repo (later)

Create `EliasSchlie/claude-plugins` — a lightweight index repo:

```
claude-plugins/
├── .claude-plugin/
│   └── marketplace.json
└── README.md
```

`marketplace.json`:
```json
{
  "name": "elias-tools",
  "owner": { "name": "Elias Schlie" },
  "plugins": [
    {
      "name": "sub-claude",
      "source": { "source": "github", "repo": "EliasSchlie/sub-claude" },
      "description": "Session-oriented pool of persistent Claude TUI slots backed by tmux",
      "version": "0.1.0"
    }
  ]
}
```

Future plugins get added as new entries pointing to their own repos.

## Phase 4: GitHub Action for version bumping (later)

Add `.github/workflows/release.yml`:

- Trigger: push a git tag like `v1.2.3`
- Action: update `version` in `.claude-plugin/plugin.json` to match tag
- Also update marketplace.json version in the marketplace repo (cross-repo dispatch or manual)
- Users with auto-update enabled get the new version on next Claude Code restart

## Distribution summary

**Two separate install steps (documented in README):**

1. **CLI tool**: `git clone` + `./install.sh` (or `brew install` later)
2. **Claude Code plugin**: `/plugin marketplace add EliasSchlie/claude-plugins` then `/plugin install sub-claude@elias-tools`

**For personal use (dotfiles):**
- `settings.json` has `extraKnownMarketplaces` + `enabledPlugins` — zero interactive steps
