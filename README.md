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

## Development

This is a personal plugin for local use only. Add new functions to `lua/ba-tools/init.lua` and reload with `:Lazy reload ba-tools.nvim`.
