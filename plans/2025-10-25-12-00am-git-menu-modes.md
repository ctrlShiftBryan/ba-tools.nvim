# Git Menu Modes Feature

## Overview
Add mode switching to the git menu, similar to lazy.nvim's interface. Users can press 'S' or 'P' to switch between Status and Pull Request modes.

## Implementation Plan

### 1. State Management Updates
- Add `current_mode` field to state object (values: "status" or "pr")
- Default mode: "status"

### 2. Window Title Updates
- Change title format to show available modes
- Example: ` Git Status (S)  Pull Request (P) `
- Highlight current mode differently

### 3. Mode Switching Keybindings
- Add 'S' keybinding → switch to status mode
- Add 'P' keybinding → switch to pull request mode
- On mode switch: refresh display, reset cursor

### 4. Refactor Display Logic
- Extract current status rendering into `render_status_mode()`
- Create new `render_pr_mode()` function
- Main `refresh_menu()` dispatches to appropriate renderer based on `current_mode`

### 5. Pull Request Mode Implementation

**Getting Current PR:**
- Use `gh pr view --json number,title,state` to get PR for current branch
- If no PR exists, display: "No pull request open for this branch"

**Getting PR Files:**
- Use `gh pr view --json files` to fetch changed files in the PR
- Parse file list with review status

**Display Format:**
```
Pull Request #123: feat: add new feature

Files Changed (5)
(hh)  ✓ file1.ts         src/            Modified   [reviewed]
(jj)  ✗ file2.js         app/            Added      [not reviewed]
(kk)  ✓ file3.lua        lib/            Modified   [reviewed]
```

**File Metadata:**
- Filename and path
- Change type (Modified, Added, Deleted)
- Review status (reviewed/not reviewed)

**Actions:**
- `<CR>` or `o` - Open file in editor
- `d` - Open diff view for the file
- `v` - View PR in browser (`gh pr view --web`)
- `r` - Refresh PR data

### 6. Shared Infrastructure
- Keep existing navigation (up/down)
- Keep existing window management
- Reuse keybind system for PR entries
- Maintain highlight namespaces

### 7. Mode-Specific State
- Status mode: keep existing state (staged/unstaged files)
- PR mode: new state (pr_list, pr_metadata)

## Files to Modify

1. **lua/ba-tools/git-menu.lua**
   - Add mode state
   - Add mode switching logic
   - Refactor rendering
   - Add PR mode implementation

2. **lua/ba-tools/git.lua** (optional)
   - Add PR-related git functions if needed

## Expected Outcome

Users can:
- Press `S` to view git status (existing functionality)
- Press `P` to view pull requests
- Navigate and interact with both modes seamlessly
- Quick mode switching without closing the menu
