# ba-tools.nvim

Personal neovim plugin for custom tools and utilities.

## Features

- 🎨 **Modern Git Menu** - Beautiful, colorful git status interface with file icons
- ⌨️ **Ergonomic Keybindings** - Two-character home row shortcuts (hh, jj, kk, etc.)
- ⚡ **Fast Batch Operations** - Stage/unstage multiple files with a single git command
- 🎯 **Smart Navigation** - Section-aware operations and auto-close behavior
- 🎨 **Theme Compatible** - Automatically adapts to your colorscheme
- 💬 **PR Comment Workflow** - Add comments in code during review, auto-post to GitHub, auto-revert local changes

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "ba-tools.nvim",
  dir = "~/code2/ba-tools.nvim",
  dependencies = {
    "nvim-tree/nvim-web-devicons", -- Optional: for file type icons
  },
  keys = {
    { "<leader>th", function() require("ba-tools").hello() end, desc = "Tools: Hello" },
    { "<leader>ti", function() require("ba-tools").file_info() end, desc = "Tools: File Info" },
    { "<C-g>", function() require("ba-tools").git_menu() end, desc = "Git Menu", mode = "n" },
  },
  config = function()
    require("ba-tools").setup({
      -- Your configuration options here
    })
  end,
}
```

## Available Functions & Commands

The plugin provides both Lua functions and Vim commands. Commands (`:PrCommentsFile`, `:PrCommentsBatch`) are documented in the [Commands](#commands) section below.

### `hello()`
Prints a hello message to test the plugin is working.

### `file_info()`
Displays information about the current file (path and filetype).

### `git_menu()`
Opens a centered floating window showing git status with staged and unstaged changes. Features a modern, colorful interface with file type icons and ergonomic keybindings.

**Visual Features:**
- 🎨 **Colorful status indicators:**
  - `✗` Conflict (red) - merge conflicts
  - `+` Added (green)
  - `●` Modified (yellow)
  - `−` Deleted (red)
  - `?` Untracked (blue)
- 📄 **File type icons** (via nvim-web-devicons)
- 🎯 **Full row selection highlighting** (Visual background)
- 📁 **Dimmed paths** for better filename visibility
- 🎨 **Bold section headers**
- ⚡ **Auto-close on window leave** (temporary overlay behavior)
- 🚀 **Batch git operations** for fast multi-file staging/unstaging
- 🔥 **Merge conflict detection** - conflicts shown in dedicated "Merge Changes" section with priority keybinds

**Keymaps:**
- `↓`/`↑` - Navigate up/down through files (includes category headers)
- **Quick access shortcuts** - Each file has two-character keybinds displayed in the first column
  - **Lowercase** (e.g., `hh`, `jj`, `kk`, `;;`, `h;`) - Opens file in diff mode
  - **Uppercase** (e.g., `HH`, `JJ`, `KK`, `::`, `H:`) - Opens file directly (no diff, clean window)
  - Uses ergonomic home row pattern: `hjkl;` (colon `:` is uppercase of semicolon `;`)
  - Supports up to 25 files for both lowercase and uppercase
  - Order: Same-key easiest (`hh`/`HH`, `jj`/`JJ`, `kk`/`KK`, `ll`/`LL`, `;;`/`::`), then adjacent rolls, then others
- `<Enter>` - Open currently selected file
  - Modified files: Opens in diff mode (HEAD vs working copy)
  - Untracked files: Opens normally (no diff available)
  - Closes git menu automatically
- `o` - Open file in editor (without diff)
- `s` - Stage/unstage
  - On a file: Stage (if unstaged) or unstage (if staged)
  - On a category header: Stage/unstage ALL files in that category
- `p` - Toggle all files at current path (or entire section on category header)
  - **On a file:** Stages/unstages all files in the same directory
    - In unstaged section: Stages all unstaged files at that path
    - In staged section: Unstages all staged files at that path
    - Example: Press `p` on `app/context/PlayerId/file.ts` to toggle all files in `app/context/PlayerId/`
  - **On a category header:** Same as `s` - stages/unstages all files in that section
- `d` - Discard changes to file (with confirmation prompt)
  - For untracked files: deletes the file
  - For tracked files: restores from HEAD
  - **For merge conflicts:** Resolves by accepting incoming changes (theirs) and auto-stages
  - Cannot discard staged changes (unstage first with `s`)
  - Not available on category headers
- `r` - Revert unstaged changes
  - For unstaged files: restores from staged version or HEAD
  - **For merge conflicts:** Resolves by keeping your local changes (ours) and auto-stages
- `q`/`<Esc>` - Close menu
- **Window navigation** (`C-h`, `C-l`, etc.) - Automatically closes the menu (temporary overlay behavior)

**Merge Conflict Handling:**
When merge conflicts are detected, a "Merge Changes" section appears at the top with:
- 🔥 Conflicts get **priority keybinds** (first in sequence) for quick access
- ✗ **Visual distinction** with red conflict indicator
- 🚀 **Resolution options:**
  - `r` - Quick resolve: Keep your local changes (ours) and auto-stage
  - `d` - Quick resolve: Accept incoming changes (theirs) and auto-stage
  - `o`/`<CR>` - Open file to manually edit conflict markers
  - `s` - Stage after manually resolving (git validates resolution)
- After resolving, files move to "Staged Changes" section

**Recommended Keybinding:** `<C-g>` for quick access (like Harpoon's `C-e`)

**Usage:** Press `<C-g>` to open the git menu. Navigate away with window commands to auto-close.

**PR Mode:**
The git menu supports a PR (Pull Request) mode for reviewing GitHub PRs. Switch between modes with `P` (PR mode) and `S` (Status mode).

In PR mode:
- `s` - Toggle file review status (mark as viewed/unviewed on GitHub)
- `r` - Revert file to base branch (delete new files, restore modified/deleted)
- `c` - **Post PR comments** - Scan all PR files for added comments, post to GitHub, revert local changes
- All other keybindings work the same as status mode

## Commands

### `:PrCommentsFile`
Posts PR review comments from the current file.

**Workflow:**
1. Open a PR file in your editor
2. Add comments anywhere in the file using your language's comment syntax (e.g., `--`, `//`, `#`)
3. Run `:PrCommentsFile`
4. Plugin scans the file for added comments via git diff
5. Comments are posted to GitHub PR as review comments
6. Local changes are automatically reverted (comments removed)

**Usage:** While viewing a PR file, add comments in the code, then run `:PrCommentsFile` to post them to GitHub.

### `:PrCommentsBatch`
Posts PR review comments from all PR files (batch mode).

**Workflow:**
1. Add comments in any PR files in your working directory
2. Run `:PrCommentsBatch`
3. Plugin scans all PR files for added comments via git diff
4. All comments are posted to GitHub PR as a single review
5. Local changes are automatically reverted (comments removed)

**Usage:** After adding comments to multiple PR files, run `:PrCommentsBatch` to post them all at once. Also accessible via `c` keybinding in PR mode of the git menu.

**Features (both commands):**
- **Language-agnostic** - Detects comment syntax based on file type
- **Multi-line support** - Consecutive comment lines are grouped into single review comments
- **Smart diff parsing** - Only new comments (added lines) are posted
- **Markdown conversion** - Comments are converted to clean markdown for GitHub
- **Auto-cleanup** - Local files are restored after posting

**Supported languages:** Lua, JavaScript, TypeScript, Python, Ruby, Go, Rust, C/C++, Java, Shell, and more.

**Optional keybindings:** You can bind these commands in your config:
```lua
vim.keymap.set('n', '<leader>pc', ':PrCommentsFile<CR>', { desc = 'Post PR comments from file' })
vim.keymap.set('n', '<leader>pb', ':PrCommentsBatch<CR>', { desc = 'Post PR comments batch' })
```

## Development

This is a personal plugin for local use only. Add new functions to `lua/ba-tools/init.lua` and reload with `:Lazy reload ba-tools.nvim`.

## Architecture

- `lua/ba-tools/git.lua` - Git command execution and status parsing
- `lua/ba-tools/ui.lua` - Floating window utilities and visual formatting
- `lua/ba-tools/git-menu.lua` - Git menu navigation, keybindings, and rendering
- `lua/ba-tools/pr-comments.lua` - PR comment extraction, posting, and cleanup
- `lua/ba-tools/init.lua` - Main plugin entry point

## Requirements

- Neovim >= 0.9.0
- Git (for git menu functionality)
- [GitHub CLI (`gh`)](https://cli.github.com/) (for PR mode and comment posting)
- [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) (optional, for file type icons)
- A Nerd Font (optional, for icons to display correctly)

## Theme Compatibility

The git menu automatically adapts to your colorscheme by using standard highlight groups:
- `DiffAdd` - Added files (green)
- `DiffChange` - Modified files (yellow)
- `DiffDelete` - Deleted files (red)
- `Directory` - Untracked files (blue)
- `Comment` - Dimmed text (paths, keybinds)
- `Title` - Section headers
- `Visual` - Selection highlight

All syntax highlights use **foreground-only colors** so the selection background always shows through.

## Tips

- **Quick workflow:** `<C-g>` → navigate with arrows → `s` to stage → `<C-g>` again (refreshes automatically)
- **Bulk operations:** Use `s` on category headers to stage/unstage entire sections
- **Path-based staging:** Use `p` to toggle all files in the same directory
- **Diff workflow:** Quick shortcuts (hh, jj, etc.) open diffs immediately, uppercase opens files directly
- **Auto-close:** Just navigate away (`C-h`, `C-l`) - the menu closes automatically
