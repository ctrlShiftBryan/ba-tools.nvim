local M = {}

-- Try to load nvim-web-devicons (optional)
local has_devicons, devicons = pcall(require, "nvim-web-devicons")

-- Status code to icon mapping
local status_icons = {
	A = "+", -- Added (green)
	M = "●", -- Modified (yellow)
	D = "−", -- Deleted (red)
	U = "?", -- Untracked (blue)
}

-- Create a centered floating window
M.create_centered_window = function(title, width_ratio, height_ratio)
	width_ratio = width_ratio or 0.6
	height_ratio = height_ratio or 0.6

	-- Calculate dimensions
	local width = math.floor(vim.o.columns * width_ratio)
	local height = math.floor(vim.o.lines * height_ratio)
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	-- Create buffer
	local buf = vim.api.nvim_create_buf(false, true) -- Not listed, scratch buffer
	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(buf, "filetype", "ba-git-menu")

	-- Window options
	local opts = {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = title or " Window ",
		title_pos = "center",
	}

	-- Create window
	local win = vim.api.nvim_open_win(buf, true, opts)

	-- Window settings
	vim.api.nvim_win_set_option(win, "winblend", 0)
	vim.api.nvim_win_set_option(win, "cursorline", false)
	vim.api.nvim_win_set_option(win, "cursorcolumn", false)

	return {
		buf = buf,
		win = win,
		width = width,
		height = height,
	}
end

-- Format a file entry for display with keybind, icon, and columns:
-- "(hh)  filename.ts      path/to/dir/    ●"
-- Returns: { line = "...", highlights = { ... } }
M.format_file_line = function(filepath, status, width, max_filename_width, keybind)
	local filename = vim.fn.fnamemodify(filepath, ":t")
	local dir = vim.fn.fnamemodify(filepath, ":h")

	-- Show empty string if in current directory
	if dir == "." then
		dir = ""
	else
		-- Add trailing slash to directory
		dir = dir .. "/"
	end

	-- Get file icon if devicons is available
	local icon = ""
	local icon_hl_group = nil
	if has_devicons then
		local i, color = devicons.get_icon(filename, nil, { default = true })
		if i then
			icon = i .. " "
			-- Create a wrapper highlight group with only foreground (no background)
			-- so selection background shows through
			if color then
				local hl_name = "BaGitMenuIcon_" .. color
				local devicon_hl = vim.api.nvim_get_hl(0, { name = color })
				vim.api.nvim_set_hl(0, hl_name, { fg = devicon_hl.fg, bg = "NONE" })
				icon_hl_group = hl_name
			end
		end
	end

	-- Get status icon
	local status_icon = status_icons[status] or status

	-- Build the line parts
	local keybind_col = keybind and string.format("(%s) ", keybind) or "     "
	local spacing = "  " -- Space between filename and path

	-- Account for icon in filename width calculation
	local filename_with_icon = icon .. filename
	local icon_len = #icon -- For byte position tracking

	-- Pad filename to max width (include icon in the width)
	local filename_padding = max_filename_width - #filename_with_icon
	if filename_padding < 0 then
		filename_padding = 0
	end
	local padded_filename = filename_with_icon .. string.rep(" ", filename_padding)

	-- Calculate available space for path
	local status_col = "  " .. status_icon
	local used = #keybind_col + max_filename_width + #spacing + #status_col
	local path_space = width - used

	-- Truncate path if it doesn't fit
	local display_path = dir
	if #dir > path_space then
		if path_space > 3 then
			display_path = "..." .. dir:sub(-(path_space - 3))
		else
			display_path = ""
		end
	end

	-- Pad path to fill remaining space
	local path_padding = path_space - #display_path
	if path_padding < 0 then
		path_padding = 0
	end

	-- Build complete line
	local line = keybind_col .. padded_filename .. spacing .. display_path .. string.rep(" ", path_padding) .. status_col

	-- Calculate byte positions for highlighting (0-indexed)
	local highlights = {}
	local pos = 0

	-- Keybind position (dimmed)
	if #keybind_col > 0 then
		table.insert(highlights, {
			group = "BaGitMenuKeybind",
			start_col = pos,
			end_col = pos + #keybind_col,
		})
		pos = pos + #keybind_col
	end

	-- Icon position (if present, use devicons color)
	if #icon > 0 and icon_hl_group then
		table.insert(highlights, {
			group = icon_hl_group,
			start_col = pos,
			end_col = pos + icon_len,
		})
		pos = pos + icon_len
	end

	-- Filename position (bright)
	local filename_end = pos + #filename
	table.insert(highlights, {
		group = "BaGitMenuFilename",
		start_col = pos,
		end_col = filename_end,
	})
	pos = #keybind_col + #padded_filename

	-- Path position (dimmed)
	pos = pos + #spacing
	if #display_path > 0 then
		table.insert(highlights, {
			group = "BaGitMenuPath",
			start_col = pos,
			end_col = pos + #display_path,
		})
	end

	-- Status icon position (colored by status type)
	local status_hl = "BaGitMenuModified" -- default
	if status == "A" then
		status_hl = "BaGitMenuAdded"
	elseif status == "D" then
		status_hl = "BaGitMenuDeleted"
	elseif status == "U" then
		status_hl = "BaGitMenuUntracked"
	end

	local status_pos = #line - #status_icon
	table.insert(highlights, {
		group = status_hl,
		start_col = status_pos,
		end_col = #line,
	})

	return {
		line = line,
		highlights = highlights,
	}
end

return M
