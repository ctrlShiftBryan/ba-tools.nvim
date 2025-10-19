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

	-- Column widths (approximate percentages of available width)
	-- prefix (2) + filename (35%) + space (2) + path (50%) + space (2) + status (3)
	local available = width - #prefix - 7 -- 7 = spaces and status column
	local filename_width = math.floor(available * 0.35)
	local path_width = available - filename_width

	-- Truncate filename if needed
	local display_filename = filename
	if #filename > filename_width then
		display_filename = filename:sub(1, filename_width - 3) .. "..."
	end

	-- Truncate path if needed
	local display_path = dir
	if #dir > path_width then
		-- Show end of path (most relevant part)
		display_path = "..." .. dir:sub(-(path_width - 3))
	end

	-- Build the line with proper spacing
	-- Column 1: filename (left-aligned, fixed width)
	local col1 = display_filename .. string.rep(" ", filename_width - #display_filename)

	-- Column 2: path (left-aligned in its space)
	local col2 = display_path .. string.rep(" ", path_width - #display_path)

	-- Column 3: status (right-aligned, 3 chars wide)
	local col3 = "  " .. status

	return prefix .. col1 .. "  " .. col2 .. col3
end

return M
