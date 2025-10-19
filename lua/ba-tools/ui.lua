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

-- Format a file entry for display
M.format_file_line = function(filepath, status, width, is_selected)
	local filename = vim.fn.fnamemodify(filepath, ":t")
	local dir = vim.fn.fnamemodify(filepath, ":h")

	-- Show just filename if in current directory
	if dir == "." then
		dir = ""
	end

	-- Calculate spacing
	-- Format: "  filename" + spaces + "dir   status"
	local prefix = is_selected and "> " or "  "
	local suffix = "   " .. status

	-- Available space for filename and directory
	local available = width - #prefix - #suffix - 3 -- 3 for spacing

	local display_path = dir
	if #dir > 0 then
		display_path = dir .. "/"
	end
	display_path = display_path .. filename

	-- Truncate if too long
	if #display_path > available then
		local max_filename = math.floor(available * 0.6)
		local max_dir = available - max_filename - 3 -- 3 for "..."

		if #filename > max_filename then
			filename = filename:sub(1, max_filename - 3) .. "..."
		end

		if #dir > max_dir and #dir > 0 then
			dir = "..." .. dir:sub(-(max_dir - 3))
		end

		display_path = dir
		if #dir > 0 then
			display_path = display_path .. "/"
		end
		display_path = display_path .. filename
	end

	-- Calculate remaining space for padding
	local padding_needed = width - #prefix - #display_path - #suffix
	if padding_needed < 0 then
		padding_needed = 0
	end
	local padding = string.rep(" ", padding_needed)

	return prefix .. display_path .. padding .. suffix
end

return M
