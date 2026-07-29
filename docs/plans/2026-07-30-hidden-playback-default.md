# Hidden Playback Default Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Keep video wallpapers playing by default and align hidden-playback labels with gSlapper.

**Architecture:** Change the manifest default and service fallback from `auto-pause` to `none`. Map `none` to no command-line flag while preserving the existing explicit `auto-pause` and `auto-stop` mappings.

**Tech Stack:** Noctalia v5 plugin manifest, Luau, JSON translations

---

### Task 1: Lock the expected mapping

**Files:**
- Modify: `gslapper/service.luau`

1. Change the self-test to require zero flags for `none` and one flag for each explicit power-saving mode.
2. Run `noctalia plugins lint ./gslapper` and confirm the plugin passes.

### Task 2: Change the default and labels

**Files:**
- Modify: `gslapper/plugin.toml`
- Modify: `gslapper/service.luau`
- Modify: `gslapper/translations/en.json`

1. Set the manifest default and first option value to `none`.
2. Use `none` when the service receives a missing or invalid value.
3. Display `None`, `Auto Pause`, and `Auto Stop`.

### Task 3: Correct the public settings table

**Files:**
- Modify: `gslapper/README.md`

1. Change the documented default to `none`.
2. State that gSlapper keeps playing unless the user selects a power-saving mode.

### Task 4: Verify live behaviour

1. Run the plugin linter and self-test.
2. Install the updated plugin from the working tree.
3. Confirm the live gSlapper command contains no `--auto-pause` or `--auto-stop` flag when the setting is absent.
