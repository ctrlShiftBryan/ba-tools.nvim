# ba-tools.nvim

Personal neovim plugin for custom tools and utilities.

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "ba-tools.nvim",
  dir = "~/code2/ba-tools.nvim",
  keys = {
    { "<leader>th", function() require("ba-tools").hello() end, desc = "Tools: Hello" },
    { "<leader>ti", function() require("ba-tools").file_info() end, desc = "Tools: File Info" },
    { "<leader>tg", function() require("ba-tools").git_menu() end, desc = "Tools: Git Menu" },
  },
  config = function()
    require("ba-tools").setup({
      -- Your configuration options here
    })
  end,
}
```

## Available Functions

### `hello()`
Prints a hello message to test the plugin is working.

### `file_info()`
Displays information about the current file (path and filetype).

### `git_menu()`
Opens a centered floating window showing git status with staged and unstaged changes. Similar to Harpoon's menu style.

**Features:**
- Shows staged changes with count
- Shows unstaged changes with count
- Navigate with `j`/`k` keys
- Visual cursor indicator (`>`)
- Interactive file operations
- Auto-refresh after operations
- Close with `ESC` or `q`

**Keymaps:**
- `↓`/`↑` - Navigate up/down through files (includes category headers)
- **Quick access shortcuts** - Each file has two-character keybinds displayed in the first column
  - **Lowercase** (e.g., `hh`, `jj`, `kk`, `hl`) - Opens file in diff mode
  - **Uppercase** (e.g., `HH`, `JJ`, `KK`, `HL`) - Opens file directly (no diff, clean window)
  - Uses ergonomic home row pattern: `hjkl` (semicolon excluded from uppercase)
  - Supports up to 25 files for lowercase, 16 for uppercase
  - Order: Same-key easiest (`hh`/`HH`, `jj`/`JJ`, `kk`/`KK`, `ll`/`LL`), then adjacent rolls, then others
- `<Enter>` - Open currently selected file
  - Modified files: Opens in diff mode (HEAD vs working copy)
  - Untracked files: Opens normally (no diff available)
  - Closes git menu automatically
- `o` - Open file in editor (without diff)
- `s` - Stage/unstage
  - On a file: Stage (if unstaged) or unstage (if staged)
  - On a category header: Stage/unstage ALL files in that category
- `d` - Discard changes to file (with confirmation prompt)
  - For untracked files: deletes the file
  - For tracked files: restores from HEAD
  - Cannot discard staged changes (unstage first with `s`)
  - Not available on category headers
- `q`/`<Esc>` - Close menu

**Usage:** Press `<leader>tg` to open the git menu.

## Development

This is a personal plugin for local use only. Add new functions to `lua/ba-tools/init.lua` and reload with `:Lazy reload ba-tools.nvim`.

## Architecture

- `lua/ba-tools/git.lua` - Git command execution and status parsing
- `lua/ba-tools/ui.lua` - Floating window utilities
- `lua/ba-tools/git-menu.lua` - Git menu navigation and rendering
- `lua/ba-tools/init.lua` - Main plugin entry point
