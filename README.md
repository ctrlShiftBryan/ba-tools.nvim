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
- Close with `ESC` or `q`

**Usage:** Press `<leader>tg` to open the git menu.

## Development

This is a personal plugin for local use only. Add new functions to `lua/ba-tools/init.lua` and reload with `:Lazy reload ba-tools.nvim`.

## Architecture

- `lua/ba-tools/git.lua` - Git command execution and status parsing
- `lua/ba-tools/ui.lua` - Floating window utilities
- `lua/ba-tools/git-menu.lua` - Git menu navigation and rendering
- `lua/ba-tools/init.lua` - Main plugin entry point
