local M = {}

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

	return {
		buf = buf,
		win = win,
		width = width,
		height = height,
	}
end

-- Format a file entry for display in three columns:
-- "  filename.ts      path/to/dir/    A"
-- Priority: Always show full filename, path gets remaining space
M.format_file_line = function(filepath, status, width, is_selected)
	local filename = vim.fn.fnamemodify(filepath, ":t")
	local dir = vim.fn.fnamemodify(filepath, ":h")

	-- Show empty string if in current directory
	if dir == "." then
		dir = ""
	else
		-- Add trailing slash to directory
		dir = dir .. "/"
	end

	local prefix = is_selected and "> " or "  "
	local spacing = "  " -- Space between filename and path
	local status_col = "  " .. status

	-- Calculate available space for path
	-- total_width = prefix + filename + spacing + path + status_col
	local used = #prefix + #filename + #spacing + #status_col
	local path_space = width - used

	-- Truncate path if it doesn't fit
	local display_path = dir
	if #dir > path_space then
		if path_space > 3 then
			-- Show end of path (most relevant part)
			display_path = "..." .. dir:sub(-(path_space - 3))
		else
			-- Not enough space for path at all
			display_path = ""
		end
	end

	-- Pad path to fill remaining space
	local path_padding = path_space - #display_path
	if path_padding < 0 then
		path_padding = 0
	end

	return prefix .. filename .. spacing .. display_path .. string.rep(" ", path_padding) .. status_col
end

return M
