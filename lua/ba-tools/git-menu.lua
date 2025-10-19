local ui = require("ba-tools.ui")
local git = require("ba-tools.git")

local M = {}

-- State for the current menu instance
local state = {
	buf = nil,
	win = nil,
	width = 0,
	current_line = 1,
	lines = {},
	line_to_file = {}, -- Map line number to file entry
	selectable_lines = {}, -- Lines that can be selected
}

-- Reset state
local function reset_state()
	state = {
		buf = nil,
		win = nil,
		width = 0,
		current_line = 1,
		lines = {},
		line_to_file = {},
		selectable_lines = {},
	}
end

-- Check if a line is selectable
local function is_selectable(line_num)
	for _, selectable in ipairs(state.selectable_lines) do
		if selectable == line_num then
			return true
		end
	end
	return false
end

-- Find next selectable line in a direction
local function find_next_selectable(current, direction)
	local next = current + direction

	-- Wrap around
	if next < 1 then
		next = #state.lines
	elseif next > #state.lines then
		next = 1
	end

	-- Find next selectable line
	local attempts = 0
	while not is_selectable(next) and attempts < #state.lines do
		next = next + direction
		if next < 1 then
			next = #state.lines
		elseif next > #state.lines then
			next = 1
		end
		attempts = attempts + 1
	end

	return next
end

-- Update the cursor position visually
local function update_cursor(new_line)
	if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
		return
	end

	-- Remove cursor from old line
	if state.current_line and state.current_line >= 1 and state.current_line <= #state.lines then
		local old_line = state.lines[state.current_line]
		if old_line:sub(1, 2) == "> " then
			state.lines[state.current_line] = "  " .. old_line:sub(3)
		end
	end

	-- Add cursor to new line
	if new_line >= 1 and new_line <= #state.lines then
		local line = state.lines[new_line]
		if line:sub(1, 2) == "  " then
			state.lines[new_line] = "> " .. line:sub(3)
		end
	end

	-- Update buffer
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, state.lines)

	state.current_line = new_line
end

-- Move cursor
local function move_cursor(direction)
	local new_line = find_next_selectable(state.current_line, direction)
	update_cursor(new_line)
end

-- Close the menu
local function close_menu()
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		vim.api.nvim_win_close(state.win, true)
	end
	reset_state()
end

-- Setup keymaps for the menu
local function setup_keymaps(buf)
	local opts = { buffer = buf, nowait = true, silent = true }

	-- Navigation
	vim.keymap.set("n", "j", function()
		move_cursor(1)
	end, opts)

	vim.keymap.set("n", "k", function()
		move_cursor(-1)
	end, opts)

	-- Close
	vim.keymap.set("n", "q", close_menu, opts)
	vim.keymap.set("n", "<Esc>", close_menu, opts)

	-- Make buffer non-modifiable
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

-- Render the git status menu
M.show = function()
	-- Get git status
	local status, err = git.get_status()
	if not status then
		vim.notify("ba-tools: " .. (err or "Failed to get git status"), vim.log.levels.ERROR)
		return
	end

	-- Create window
	local window = ui.create_centered_window(" Git Status ", 0.6, 0.6)
	state.buf = window.buf
	state.win = window.win
	state.width = window.width

	-- Build lines
	local lines = {}
	local line_num = 1
	local selectable_lines = {}
	local line_to_file = {}

	-- Staged section
	table.insert(lines, string.format("Staged Changes (%d)", #status.staged))
	line_num = line_num + 1

	if #status.staged > 0 then
		for i, entry in ipairs(status.staged) do
			local line = ui.format_file_line(entry.file, entry.status, state.width, false)
			table.insert(lines, line)
			table.insert(selectable_lines, line_num)
			line_to_file[line_num] = { section = "staged", index = i, entry = entry }
			line_num = line_num + 1
		end
	end

	-- Empty line separator
	table.insert(lines, "")
	line_num = line_num + 1

	-- Unstaged section
	table.insert(lines, string.format("Changes (%d)", #status.unstaged))
	line_num = line_num + 1

	if #status.unstaged > 0 then
		for i, entry in ipairs(status.unstaged) do
			local line = ui.format_file_line(entry.file, entry.status, state.width, false)
			table.insert(lines, line)
			table.insert(selectable_lines, line_num)
			line_to_file[line_num] = { section = "unstaged", index = i, entry = entry }
			line_num = line_num + 1
		end
	end

	-- Store state
	state.lines = lines
	state.selectable_lines = selectable_lines
	state.line_to_file = line_to_file

	-- Set initial cursor position to first selectable line
	if #selectable_lines > 0 then
		state.current_line = selectable_lines[1]
		-- Add cursor indicator
		if state.lines[state.current_line]:sub(1, 2) == "  " then
			state.lines[state.current_line] = "> " .. state.lines[state.current_line]:sub(3)
		end
	end

	-- Set buffer content
	vim.api.nvim_buf_set_option(state.buf, "modifiable", true)
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, state.lines)

	-- Setup keymaps
	setup_keymaps(state.buf)
end

return M
