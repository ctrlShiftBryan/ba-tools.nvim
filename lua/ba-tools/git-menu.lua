local ui = require("ba-tools.ui")
local git = require("ba-tools.git")

local M = {}

-- Create highlight namespace for selection
local ns_id = vim.api.nvim_create_namespace("ba-git-menu-selection")

-- Ergonomic two-character keybind pattern using hjkl; home row (25 total)
local keybind_sequence = {
	-- Same key (easiest)
	"hh", "jj", "kk", "ll", ";;",
	-- Adjacent outward roll
	"hj", "jk", "kl", "l;",
	-- Adjacent inward roll
	"jh", "kj", "lk", ";l",
	-- Skip one outward
	"hk", "jl", "k;",
	-- Skip one inward
	"kh", "lj", ";k",
	-- Remaining combinations
	"hl", "lh", "h;", ";h", "j;", ";j"
}

-- Persistent state across menu invocations
local last_selected_file = nil

-- State for the current menu instance
local state = {
	buf = nil,
	win = nil,
	width = 0,
	current_line = 1,
	lines = {},
	line_to_file = {}, -- Map line number to file entry
	selectable_lines = {}, -- Lines that can be selected
	keybind_to_line = {}, -- Map keybind to line number
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
		keybind_to_line = {},
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

	-- Clear all existing highlights
	vim.api.nvim_buf_clear_namespace(state.buf, ns_id, 0, -1)

	-- Add highlight to new line (0-indexed for line number)
	if new_line >= 1 and new_line <= #state.lines then
		vim.api.nvim_buf_add_highlight(state.buf, ns_id, "BaGitMenuSelected", new_line - 1, 0, -1)
	end

	-- Move vim cursor to the new line
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		vim.api.nvim_win_set_cursor(state.win, { new_line, 0 })
	end

	state.current_line = new_line

	-- Remember last selected file for next time (but not categories)
	local file_info = state.line_to_file[new_line]
	if file_info and not file_info.is_category then
		last_selected_file = file_info.entry.file
	end
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

-- Get currently selected file
local function get_current_file()
	local file_info = state.line_to_file[state.current_line]
	if not file_info then
		return nil
	end
	return file_info
end

-- Refresh the menu (rebuild contents)
local function refresh_menu()
	-- Get git status
	local status, err = git.get_status()
	if not status then
		vim.notify("ba-tools: " .. (err or "Failed to get git status"), vim.log.levels.ERROR)
		close_menu()
		return
	end

	-- If no changes, close the menu
	if #status.staged == 0 and #status.unstaged == 0 then
		vim.notify("No changes to display", vim.log.levels.INFO)
		close_menu()
		return
	end

	-- Remember current section and index to maintain position after refresh
	local current_file_info = get_current_file()
	local target_section = current_file_info and current_file_info.section
	local target_index = current_file_info and current_file_info.index
	local target_is_category = current_file_info and current_file_info.is_category

	-- First pass: Calculate max filename width for consistent columns
	local max_filename_width = 0
	for _, entry in ipairs(status.staged) do
		local filename = vim.fn.fnamemodify(entry.file, ":t")
		max_filename_width = math.max(max_filename_width, #filename)
	end
	for _, entry in ipairs(status.unstaged) do
		local filename = vim.fn.fnamemodify(entry.file, ":t")
		max_filename_width = math.max(max_filename_width, #filename)
	end

	-- Build lines
	local lines = {}
	local line_num = 1
	local selectable_lines = {}
	local line_to_file = {}
	local keybind_to_line = {}
	local keybind_idx = 1 -- Track keybind assignment (1-25)

	-- Staged section
	table.insert(lines, string.format("Staged Changes (%d)", #status.staged))
	table.insert(selectable_lines, line_num)
	line_to_file[line_num] = { is_category = true, section = "staged", files = status.staged }
	line_num = line_num + 1

	if #status.staged > 0 then
		for i, entry in ipairs(status.staged) do
			-- Assign keybind if within limit (25 files max)
			local keybind = nil
			if keybind_idx <= #keybind_sequence then
				keybind = keybind_sequence[keybind_idx]
				keybind_to_line[keybind] = line_num
				keybind_idx = keybind_idx + 1
			end

			local line = ui.format_file_line(entry.file, entry.status, state.width, max_filename_width, keybind)
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
	table.insert(selectable_lines, line_num)
	line_to_file[line_num] = { is_category = true, section = "unstaged", files = status.unstaged }
	line_num = line_num + 1

	if #status.unstaged > 0 then
		for i, entry in ipairs(status.unstaged) do
			-- Assign keybind if within limit (25 files max)
			local keybind = nil
			if keybind_idx <= #keybind_sequence then
				keybind = keybind_sequence[keybind_idx]
				keybind_to_line[keybind] = line_num
				keybind_idx = keybind_idx + 1
			end

			local line = ui.format_file_line(entry.file, entry.status, state.width, max_filename_width, keybind)
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
	state.keybind_to_line = keybind_to_line

	-- Set cursor position (stay at same section + index for natural "next file" behavior)
	local target_line = nil

	if target_section and target_is_category then
		-- Restore to the category header for the same section
		for line, file_info in pairs(line_to_file) do
			if file_info.is_category and file_info.section == target_section then
				target_line = line
				break
			end
		end
	elseif target_section and target_index then
		-- Restore to same index within the section (which is now the "next" file)
		for line, file_info in pairs(line_to_file) do
			if not file_info.is_category and file_info.section == target_section and file_info.index == target_index then
				target_line = line
				break
			end
		end
	end

	-- Fallback: if target not found, use first selectable line
	if target_line and is_selectable(target_line) then
		state.current_line = target_line
	elseif #selectable_lines > 0 then
		state.current_line = selectable_lines[1]
	end

	-- Update buffer
	vim.api.nvim_buf_set_option(state.buf, "modifiable", true)
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, state.lines)
	vim.api.nvim_buf_set_option(state.buf, "modifiable", false)

	-- Apply highlight to current line
	vim.api.nvim_buf_clear_namespace(state.buf, ns_id, 0, -1)
	if state.current_line then
		vim.api.nvim_buf_add_highlight(state.buf, ns_id, "BaGitMenuSelected", state.current_line - 1, 0, -1)
	end

	-- Move vim cursor to the current line
	if state.win and vim.api.nvim_win_is_valid(state.win) and state.current_line then
		vim.api.nvim_win_set_cursor(state.win, { state.current_line, 0 })
	end
end

-- Open the selected file
local function open_file()
	local file_info = get_current_file()
	if not file_info then
		return
	end

	-- Cannot open a category
	if file_info.is_category then
		vim.notify("Cannot open category. Use 's' to stage/unstage all files.", vim.log.levels.WARN)
		return
	end

	local filepath = file_info.entry.file
	close_menu()

	-- Open file in previous window
	vim.cmd("edit " .. vim.fn.fnameescape(filepath))
end

-- Stage or unstage the selected file or category
local function toggle_stage()
	local file_info = get_current_file()
	if not file_info then
		return
	end

	-- Check if this is a category header
	if file_info.is_category then
		local section = file_info.section
		local files = file_info.files

		-- Stage/unstage all files in this category
		local failed = {}
		local action = section == "staged" and "Unstaging" or "Staging"

		for _, entry in ipairs(files) do
			local success, err
			if section == "staged" then
				success, err = git.unstage_file(entry.file)
			else
				success, err = git.stage_file(entry.file)
			end

			if not success then
				table.insert(failed, entry.file)
			end
		end

		-- Show notification
		if #failed == 0 then
			local past_tense = section == "staged" and "unstaged" or "staged"
			vim.notify(string.format("%s %d files", past_tense, #files), vim.log.levels.INFO)
		else
			vim.notify(string.format("Failed to process %d files", #failed), vim.log.levels.ERROR)
		end

		refresh_menu()
		return
	end

	-- Single file stage/unstage
	local filepath = file_info.entry.file
	local section = file_info.section

	local success, err

	if section == "staged" then
		-- Unstage the file
		success, err = git.unstage_file(filepath)
		if success then
			vim.notify("Unstaged: " .. filepath, vim.log.levels.INFO)
		else
			vim.notify(err, vim.log.levels.ERROR)
		end
	else
		-- Stage the file
		success, err = git.stage_file(filepath)
		if success then
			vim.notify("Staged: " .. filepath, vim.log.levels.INFO)
		else
			vim.notify(err, vim.log.levels.ERROR)
		end
	end

	-- Refresh the menu
	if success then
		refresh_menu()
	end
end

-- Open diff with native vim diff
local function open_diff()
	local file_info = get_current_file()
	if not file_info then
		return
	end

	-- Cannot diff a category
	if file_info.is_category then
		vim.notify("Cannot open diff for category. Select individual files.", vim.log.levels.WARN)
		return
	end

	local filepath = file_info.entry.file
	local is_untracked = file_info.entry.status == "U"

	-- For untracked files, just open them normally (no diff to show)
	if is_untracked then
		close_menu()
		vim.cmd("edit " .. vim.fn.fnameescape(filepath))
		return
	end

	-- Close menu
	close_menu()

	-- Turn off diff mode in all windows before cleanup
	vim.cmd("diffoff!")

	-- Close all other windows to ensure clean diff setup (only 2 windows)
	vim.cmd("only")

	-- Open the file
	vim.cmd("edit " .. vim.fn.fnameescape(filepath))

	-- Get HEAD version of the file
	local head_content = vim.fn.system("git show HEAD:" .. vim.fn.shellescape(filepath))

	if vim.v.shell_error ~= 0 then
		vim.notify("Failed to get HEAD version of file", vim.log.levels.ERROR)
		return
	end

	-- Create a temporary buffer for HEAD version
	vim.cmd("vertical new")
	local head_buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_name(head_buf, filepath .. " (HEAD)")

	-- Set buffer options
	vim.api.nvim_buf_set_option(head_buf, "buftype", "nofile")
	vim.api.nvim_buf_set_option(head_buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(head_buf, "swapfile", false)

	-- Set the content
	local lines = vim.split(head_content, "\n")
	vim.api.nvim_buf_set_lines(head_buf, 0, -1, false, lines)

	-- Set filetype to match the original file
	local ft = vim.bo.filetype
	vim.api.nvim_buf_set_option(head_buf, "filetype", ft)

	-- Enable diff mode on both buffers
	vim.cmd("diffthis")
	vim.cmd("wincmd p")  -- Go back to working file
	vim.cmd("diffthis")
end

-- Discard changes to the selected file
local function discard_changes()
	local file_info = get_current_file()
	if not file_info then
		return
	end

	-- Cannot discard a category
	if file_info.is_category then
		vim.notify("Cannot discard category. Select individual files.", vim.log.levels.WARN)
		return
	end

	local filepath = file_info.entry.file
	local section = file_info.section

	-- Can only discard unstaged changes
	if section == "staged" then
		vim.notify("Cannot discard staged changes. Unstage first with 's'", vim.log.levels.WARN)
		return
	end

	-- Check if file is untracked
	local is_untracked = file_info.entry.status == "U"

	-- Confirm before discarding
	local action = is_untracked and "delete" or "discard changes to"
	local choice = vim.fn.confirm(string.format("Are you sure you want to %s '%s'?", action, filepath), "&Yes\n&No", 2)

	if choice ~= 1 then
		return
	end

	-- Discard the changes
	local success, err = git.discard_file(filepath, is_untracked)
	if success then
		vim.notify((is_untracked and "Deleted: " or "Discarded: ") .. filepath, vim.log.levels.INFO)
		refresh_menu()
	else
		vim.notify(err, vim.log.levels.ERROR)
	end
end

-- Setup keymaps for the menu
local function setup_keymaps(buf)
	local opts = { buffer = buf, nowait = true, silent = true }

	-- Dynamic keybinds for quick file access (hh, jj, kk, etc.)
	for keybind, line_num in pairs(state.keybind_to_line) do
		vim.keymap.set("n", keybind, function()
			-- Move cursor to the line and open the file
			update_cursor(line_num)
			open_diff()
		end, opts)
	end

	-- Actions
	vim.keymap.set("n", "<CR>", open_diff, opts)
	vim.keymap.set("n", "o", open_file, opts)
	vim.keymap.set("n", "s", toggle_stage, opts)
	vim.keymap.set("n", "d", discard_changes, opts)

	-- Close
	vim.keymap.set("n", "q", close_menu, opts)
	vim.keymap.set("n", "<Esc>", close_menu, opts)

	-- Make buffer non-modifiable
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

-- Render the git status menu
M.show = function()
	-- Set up highlight group (link to Visual for visible selection)
	vim.api.nvim_set_hl(0, "BaGitMenuSelected", { link = "Visual", default = true })

	-- Get git status
	local status, err = git.get_status()
	if not status then
		vim.notify("ba-tools: " .. (err or "Failed to get git status"), vim.log.levels.ERROR)
		return
	end

	-- Check if there are any changes
	if #status.staged == 0 and #status.unstaged == 0 then
		vim.notify("No changes to display", vim.log.levels.INFO)
		return
	end

	-- Create window
	local window = ui.create_centered_window(" Git Status ", 0.6, 0.6)
	state.buf = window.buf
	state.win = window.win
	state.width = window.width

	-- First pass: Calculate max filename width for consistent columns
	local max_filename_width = 0
	for _, entry in ipairs(status.staged) do
		local filename = vim.fn.fnamemodify(entry.file, ":t")
		max_filename_width = math.max(max_filename_width, #filename)
	end
	for _, entry in ipairs(status.unstaged) do
		local filename = vim.fn.fnamemodify(entry.file, ":t")
		max_filename_width = math.max(max_filename_width, #filename)
	end

	-- Build lines
	local lines = {}
	local line_num = 1
	local selectable_lines = {}
	local line_to_file = {}
	local keybind_to_line = {}
	local keybind_idx = 1 -- Track keybind assignment (1-25)

	-- Staged section
	table.insert(lines, string.format("Staged Changes (%d)", #status.staged))
	table.insert(selectable_lines, line_num)
	line_to_file[line_num] = { is_category = true, section = "staged", files = status.staged }
	line_num = line_num + 1

	if #status.staged > 0 then
		for i, entry in ipairs(status.staged) do
			-- Assign keybind if within limit (25 files max)
			local keybind = nil
			if keybind_idx <= #keybind_sequence then
				keybind = keybind_sequence[keybind_idx]
				keybind_to_line[keybind] = line_num
				keybind_idx = keybind_idx + 1
			end

			local line = ui.format_file_line(entry.file, entry.status, state.width, max_filename_width, keybind)
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
	table.insert(selectable_lines, line_num)
	line_to_file[line_num] = { is_category = true, section = "unstaged", files = status.unstaged }
	line_num = line_num + 1

	if #status.unstaged > 0 then
		for i, entry in ipairs(status.unstaged) do
			-- Assign keybind if within limit (25 files max)
			local keybind = nil
			if keybind_idx <= #keybind_sequence then
				keybind = keybind_sequence[keybind_idx]
				keybind_to_line[keybind] = line_num
				keybind_idx = keybind_idx + 1
			end

			local line = ui.format_file_line(entry.file, entry.status, state.width, max_filename_width, keybind)
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
	state.keybind_to_line = keybind_to_line

	-- Set initial cursor position
	-- Try to restore to last selected file, otherwise go to first selectable line
	local cursor_line = nil
	if last_selected_file then
		-- Find the line with this file
		for line, file_info in pairs(line_to_file) do
			if not file_info.is_category and file_info.entry and file_info.entry.file == last_selected_file then
				cursor_line = line
				break
			end
		end
	end

	-- Fall back to first selectable line if file not found
	if not cursor_line and #selectable_lines > 0 then
		cursor_line = selectable_lines[1]
	end

	if cursor_line then
		state.current_line = cursor_line
	end

	-- Set buffer content
	vim.api.nvim_buf_set_option(state.buf, "modifiable", true)
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, state.lines)
	vim.api.nvim_buf_set_option(state.buf, "modifiable", false)

	-- Apply highlight to initial cursor line
	if state.current_line then
		vim.api.nvim_buf_add_highlight(state.buf, ns_id, "BaGitMenuSelected", state.current_line - 1, 0, -1)
	end

	-- Move vim cursor to initial line
	if state.win and vim.api.nvim_win_is_valid(state.win) and state.current_line then
		vim.api.nvim_win_set_cursor(state.win, { state.current_line, 0 })
	end

	-- Setup keymaps
	setup_keymaps(state.buf)
end

return M
