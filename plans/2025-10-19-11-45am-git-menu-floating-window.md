# Git Menu Floating Window Implementation Plan

## Overview

Create a centered floating window that displays git status in a Harpoon-style menu, showing staged and unstaged changes with navigation support.

## Requirements

### UI Layout

```
┌─ Git Status ─────────────────────────┐
│ Staged Changes (2)                   │
│   prompt.md                      M   │
│   2025-10-19-add-player...md     A   │
│                                      │
│ Changes (5)                          │
│ > playerIdContext.db.test.ts     U   │
│   playerIdContext.ts             U   │
│   playerIdValidation.db.test.ts  U   │
│   playerIdValidation.ts          U   │
│   admin-ui.player.$id.tsx        M   │
└──────────────────────────────────────┘
```

### Features

1. **Centered floating window** similar to Harpoon menu
2. **Two sections**:
   - Staged Changes with count
   - Unstaged Changes with count
3. **File display**: filename left-aligned, path/status right-aligned
4. **Navigation**: j/k to move between files, visual cursor indicator (>)
5. **Git integration**: Populate from `git status`
6. **Close**: ESC or q to close

## Technical Approach

### 1. Git Status Parsing

Use `git status --porcelain=v1` which outputs:
```
M  staged-modified.txt
 M unstaged-modified.txt
A  new-file.txt
?? untracked.txt
```

**Status codes:**
- First character: staged status (space = not staged)
- Second character: unstaged status (space = not changed)
- `M` = modified, `A` = added, `D` = deleted, `??` = untracked

**Parsing logic:**
```lua
local staged = {}
local unstaged = {}

for line in git_output:gmatch("[^\n]+") do
  local status, file = line:match("^(..)%s+(.+)$")
  local staged_char = status:sub(1,1)
  local unstaged_char = status:sub(2,2)

  if staged_char ~= ' ' and staged_char ~= '?' then
    table.insert(staged, {file = file, status = staged_char})
  end

  if unstaged_char ~= ' ' or status == '??' then
    table.insert(unstaged, {file = file, status = unstaged_char})
  end
end
```

### 2. Floating Window Creation

Use `nvim.api.nvim_open_win()` with centered positioning:

```lua
local width = math.floor(vim.o.columns * 0.6)  -- 60% of screen width
local height = math.floor(vim.o.lines * 0.6)   -- 60% of screen height
local row = math.floor((vim.o.lines - height) / 2)
local col = math.floor((vim.o.columns - width) / 2)

local opts = {
  relative = 'editor',
  width = width,
  height = height,
  row = row,
  col = col,
  style = 'minimal',
  border = 'rounded',
  title = ' Git Status ',
  title_pos = 'center',
}
```

### 3. Buffer Content Rendering

Create lines array:
```lua
local lines = {}
local line_to_file = {}  -- Map line numbers to file entries
local current_line = 1

-- Staged section
table.insert(lines, string.format("Staged Changes (%d)", #staged))
current_line = current_line + 1

for _, entry in ipairs(staged) do
  local filename = vim.fn.fnamemodify(entry.file, ':t')
  local path = vim.fn.fnamemodify(entry.file, ':h')
  local display = string.format("  %s%s%s",
    filename,
    string.rep(' ', width - #filename - #path - 10),
    entry.status
  )
  table.insert(lines, display)
  line_to_file[current_line] = {section = 'staged', index = _}
  current_line = current_line + 1
end

-- Empty line separator
table.insert(lines, "")
current_line = current_line + 1

-- Changes section
table.insert(lines, string.format("Changes (%d)", #unstaged))
-- ... similar to staged
```

### 4. Navigation State

Track current position:
```lua
local state = {
  current_line = 2,  -- Start at first file (skip header)
  total_lines = #lines,
  buf = buf,
  win = win,
  line_to_file = line_to_file,
}
```

### 5. Navigation Keymaps

```lua
-- Move down
vim.keymap.set('n', 'j', function()
  move_cursor(state, 1)
end, {buffer = buf, nowait = true})

-- Move up
vim.keymap.set('n', 'k', function()
  move_cursor(state, -1)
end, {buffer = buf, nowait = true})

-- Close
vim.keymap.set('n', 'q', close_window, {buffer = buf, nowait = true})
vim.keymap.set('n', '<Esc>', close_window, {buffer = buf, nowait = true})
```

### 6. Visual Cursor Indicator

Update line content to show cursor:
```lua
function move_cursor(state, direction)
  -- Remove cursor from current line
  local old_line = vim.api.nvim_buf_get_lines(buf, state.current_line - 1, state.current_line, false)[1]
  local cleaned = old_line:gsub("^> ", "  ")
  vim.api.nvim_buf_set_lines(buf, state.current_line - 1, state.current_line, false, {cleaned})

  -- Calculate new position (skip headers and empty lines)
  state.current_line = calculate_next_valid_line(state, direction)

  -- Add cursor to new line
  local new_line = vim.api.nvim_buf_get_lines(buf, state.current_line - 1, state.current_line, false)[1]
  local with_cursor = "> " .. new_line:sub(3)
  vim.api.nvim_buf_set_lines(buf, state.current_line - 1, state.current_line, false, {with_cursor})
end
```

## Implementation Steps

### Phase 1: Git Status Parsing (Core)
1. Create `lua/ba-tools/git.lua` module
2. Implement `get_status()` function that runs `git status --porcelain=v1`
3. Parse output into staged and unstaged arrays
4. Add tests with sample git output

### Phase 2: UI Rendering
1. Create `lua/ba-tools/ui.lua` module for window utilities
2. Implement `create_centered_window()` function
3. Implement `render_git_status()` to format lines
4. Handle filename truncation for long paths
5. Add proper spacing/padding

### Phase 3: Navigation
1. Implement state management for current line
2. Add j/k keymap handlers
3. Implement `move_cursor()` with visual indicator
4. Skip non-selectable lines (headers, empty lines)
5. Wrap at top/bottom or stop at edges

### Phase 4: Integration
1. Add `git_menu()` function to `lua/ba-tools/init.lua`
2. Wire up git, ui, and navigation modules
3. Add keymap in `lazy.lua`: `<leader>tg` for git menu
4. Update which-key description

### Phase 5: Polish
1. Add syntax highlighting for status indicators
2. Color staged/unstaged headers differently
3. Handle edge cases (no git repo, no changes)
4. Add error messages for non-git directories
5. Consider future actions (stage, unstage, diff, open file)

## File Structure

```
ba-tools.nvim/
├── lua/
│   └── ba-tools/
│       ├── init.lua        # Main entry point, git_menu()
│       ├── git.lua         # Git command execution and parsing
│       ├── ui.lua          # Floating window utilities
│       └── git-menu.lua    # Navigation and state management
└── plans/
    └── 2025-10-19-11-45am-git-menu-floating-window.md
```

## Potential Challenges

1. **Line wrapping**: Long filenames need truncation
2. **Window resizing**: Need to recalculate layout if terminal resizes
3. **Empty states**: Handle no changes gracefully
4. **Performance**: Large repos with many changes
5. **Git repo detection**: Graceful failure if not in git repo

## Future Enhancements (Out of Scope)

1. Press Enter to open file diff
2. Press 's' to stage/unstage selected file
3. Press 'd' to discard changes
4. Refresh on focus/timer
5. Show diff preview in split
6. Support for git submodules

## Testing Strategy

1. Test with various git states:
   - No changes
   - Only staged
   - Only unstaged
   - Mixed staged/unstaged
   - Untracked files
2. Test navigation edge cases
3. Test outside git repo
4. Test with very long filenames

## Success Criteria

- [ ] Window opens centered like Harpoon
- [ ] Shows accurate staged/unstaged counts
- [ ] j/k navigation works smoothly
- [ ] Visual cursor (>) indicates current line
- [ ] ESC/q closes window
- [ ] Handles non-git directories gracefully
- [ ] Filenames display correctly with paths
