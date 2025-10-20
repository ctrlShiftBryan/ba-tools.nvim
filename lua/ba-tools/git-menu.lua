local ui = require("ba-tools.ui")
local git = require("ba-tools.git")

local M = {}

-- Create highlight namespaces
local ns_id_selection = vim.api.nvim_create_namespace("ba-git-menu-selection")
local ns_id_syntax = vim.api.nvim_create_namespace("ba-git-menu-syntax")

-- Ergonomic two-character keybind pattern using hjkl; home row
-- Lowercase (25 total): Opens diff view
local keybind_sequence_diff = {
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

-- Uppercase (25 total): Opens file directly (no diff)
-- Note: Colon (:) is the uppercase version of semicolon (;)
local keybind_sequence_direct = {
	-- Same key (easiest)
	"HH", "JJ", "KK", "LL", "::",
	-- Adjacent outward roll
	"HJ", "JK", "KL", "L:",
	-- Adjacent inward roll
	"JH", "KJ", "LK", ":L",
	-- Skip one outward
	"HK", "JL", "K:",
	-- Skip one inward
	"KH", "LJ", ":K",
	-- Remaining combinations
	"HL", "LH", "H:", ":H", "J:", ":J"
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
	keybind_to_line_diff = {}, -- Map lowercase keybind to line number (opens diff)
	keybind_to_line_direct = {}, -- Map uppercase keybind to line number (opens directly)
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
		keybind_to_line_diff = {},
		keybind_to_line_direct = {},
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

	-- Clear only selection highlights (not syntax highlights)
	vim.api.nvim_buf_clear_namespace(state.buf, ns_id_selection, 0, -1)

	-- Add highlight to new line (0-indexed for line number)
	if new_line >= 1 and new_line <= #state.lines then
		vim.api.nvim_buf_add_highlight(state.buf, ns_id_selection, "BaGitMenuSelected", new_line - 1, 0, -1)
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

	-- First pass: Calculate max filename width for consistent columns (including icons)
	local max_filename_width = 0
	local has_devicons, devicons = pcall(require, "nvim-web-devicons")

	for _, entry in ipairs(status.staged) do
		local filename = vim.fn.fnamemodify(entry.file, ":t")
		local width = #filename
		-- Add icon width if devicons available (icon + space = ~3 chars)
		if has_devicons then
			width = width + 3
		end
		max_filename_width = math.max(max_filename_width, width)
	end
	for _, entry in ipairs(status.unstaged) do
		local filename = vim.fn.fnamemodify(entry.file, ":t")
		local width = #filename
		-- Add icon width if devicons available
		if has_devicons then
			width = width + 3
		end
		max_filename_width = math.max(max_filename_width, width)
	end

	-- Build lines
	local lines = {}
	local line_highlights = {} -- Store highlights for each line
	local line_num = 1
	local selectable_lines = {}
	local line_to_file = {}
	local keybind_to_line_diff = {}
	local keybind_to_line_direct = {}
	local keybind_idx = 1 -- Track keybind assignment

	-- Staged section
	table.insert(lines, string.format("Staged Changes (%d)", #status.staged))
	line_highlights[line_num] = { { group = "BaGitMenuHeader", start_col = 0, end_col = -1 } }
	table.insert(selectable_lines, line_num)
	line_to_file[line_num] = { is_category = true, section = "staged", files = status.staged }
	line_num = line_num + 1

	if #status.staged > 0 then
		for i, entry in ipairs(status.staged) do
			-- Assign both lowercase (diff) and uppercase (direct) keybinds
			local keybind_diff = nil
			local keybind_direct = nil

			if keybind_idx <= #keybind_sequence_diff then
				keybind_diff = keybind_sequence_diff[keybind_idx]
				keybind_to_line_diff[keybind_diff] = line_num
			end

			if keybind_idx <= #keybind_sequence_direct then
				keybind_direct = keybind_sequence_direct[keybind_idx]
				keybind_to_line_direct[keybind_direct] = line_num
			end

			-- Use lowercase keybind for display
			local keybind = keybind_diff
			keybind_idx = keybind_idx + 1

			local formatted = ui.format_file_line(entry.file, entry.status, state.width, max_filename_width, keybind)
			table.insert(lines, formatted.line)
			line_highlights[line_num] = formatted.highlights
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
	line_highlights[line_num] = { { group = "BaGitMenuHeader", start_col = 0, end_col = -1 } }
	table.insert(selectable_lines, line_num)
	line_to_file[line_num] = { is_category = true, section = "unstaged", files = status.unstaged }
	line_num = line_num + 1

	if #status.unstaged > 0 then
		for i, entry in ipairs(status.unstaged) do
			-- Assign both lowercase (diff) and uppercase (direct) keybinds
			local keybind_diff = nil
			local keybind_direct = nil

			if keybind_idx <= #keybind_sequence_diff then
				keybind_diff = keybind_sequence_diff[keybind_idx]
				keybind_to_line_diff[keybind_diff] = line_num
			end

			if keybind_idx <= #keybind_sequence_direct then
				keybind_direct = keybind_sequence_direct[keybind_idx]
				keybind_to_line_direct[keybind_direct] = line_num
			end

			-- Use lowercase keybind for display
			local keybind = keybind_diff
			keybind_idx = keybind_idx + 1

			local formatted = ui.format_file_line(entry.file, entry.status, state.width, max_filename_width, keybind)
			table.insert(lines, formatted.line)
			line_highlights[line_num] = formatted.highlights
			table.insert(selectable_lines, line_num)
			line_to_file[line_num] = { section = "unstaged", index = i, entry = entry }
			line_num = line_num + 1
		end
	end

	-- Store state
	state.lines = lines
	state.selectable_lines = selectable_lines
	state.line_to_file = line_to_file
	state.keybind_to_line_diff = keybind_to_line_diff
	state.keybind_to_line_direct = keybind_to_line_direct

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

	-- Clear both namespaces before re-applying highlights
	vim.api.nvim_buf_clear_namespace(state.buf, ns_id_syntax, 0, -1)
	vim.api.nvim_buf_clear_namespace(state.buf, ns_id_selection, 0, -1)

	-- Apply syntax highlights to all lines
	for line_idx, highlights in pairs(line_highlights) do
		for _, hl in ipairs(highlights) do
			vim.api.nvim_buf_add_highlight(state.buf, ns_id_syntax, hl.group, line_idx - 1, hl.start_col, hl.end_col)
		end
	end

	-- Apply selection highlight
	if state.current_line then
		vim.api.nvim_buf_add_highlight(state.buf, ns_id_selection, "BaGitMenuSelected", state.current_line - 1, 0, -1)
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

	-- Clean up any existing diff mode and windows
	vim.cmd("diffoff!")
	vim.cmd("only")

	-- Open file in single window
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

		-- Stage/unstage all files in this category with a single git command (batch operation)
		local filepaths = {}
		for _, entry in ipairs(files) do
			table.insert(filepaths, entry.file)
		end

		local success, err
		if section == "staged" then
			success, err = git.unstage_files(filepaths)
		else
			success, err = git.stage_files(filepaths)
		end

		-- Show notification
		if success then
			local past_tense = section == "staged" and "Unstaged" or "Staged"
			vim.notify(string.format("%s %d files", past_tense, #files), vim.log.levels.INFO)
		else
			vim.notify(string.format("Failed to process files: %s", err or "unknown error"), vim.log.levels.ERROR)
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
		-- Clean up any existing diff mode and windows
		vim.cmd("diffoff!")
		vim.cmd("only")
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

-- Toggle (stage/unstage) all files at the current file's path
local function toggle_path()
	local file_info = get_current_file()
	if not file_info then
		return
	end

	-- If on category, just behave like 's' (stage/unstage all)
	if file_info.is_category then
		toggle_stage()
		return
	end

	local filepath = file_info.entry.file
	local dir = vim.fn.fnamemodify(filepath, ":h")
	local section = file_info.section

	-- Get current git status
	local status, err = git.get_status()
	if not status then
		vim.notify("Failed to get git status: " .. (err or "unknown error"), vim.log.levels.ERROR)
		return
	end

	local files_to_process = {}
	local action = ""
	local action_past = ""

	if section == "unstaged" then
		-- Find all unstaged files in the same directory
		for _, entry in ipairs(status.unstaged) do
			local entry_dir = vim.fn.fnamemodify(entry.file, ":h")
			if entry_dir == dir then
				table.insert(files_to_process, entry.file)
			end
		end
		action = "stage"
		action_past = "Staged"
	else -- staged
		-- Find all staged files in the same directory
		for _, entry in ipairs(status.staged) do
			local entry_dir = vim.fn.fnamemodify(entry.file, ":h")
			if entry_dir == dir then
				table.insert(files_to_process, entry.file)
			end
		end
		action = "unstage"
		action_past = "Unstaged"
	end

	-- Check if there are any files to process
	if #files_to_process == 0 then
		vim.notify(string.format("No %s files at path: %s", section, dir), vim.log.levels.INFO)
		return
	end

	-- Process all files with a single git command (batch operation)
	local success, process_err
	if section == "unstaged" then
		success, process_err = git.stage_files(files_to_process)
	else
		success, process_err = git.unstage_files(files_to_process)
	end

	-- Show notification
	if success then
		vim.notify(string.format("%s %d files at %s", action_past, #files_to_process, dir), vim.log.levels.INFO)
	else
		vim.notify(string.format("Failed to %s files: %s", action, process_err or "unknown error"), vim.log.levels.ERROR)
	end

	-- Refresh the menu
	refresh_menu()
end

-- Setup keymaps for the menu
local function setup_keymaps(buf)
	local opts = { buffer = buf, nowait = true, silent = true }

	-- Navigation with arrow keys
	vim.keymap.set("n", "<Down>", function()
		move_cursor(1)
	end, opts)

	vim.keymap.set("n", "<Up>", function()
		move_cursor(-1)
	end, opts)

	-- Dynamic keybinds for quick file access
	-- Lowercase (hh, jj, kk, etc.) - Opens diff view
	for keybind, line_num in pairs(state.keybind_to_line_diff) do
		vim.keymap.set("n", keybind, function()
			update_cursor(line_num)
			open_diff()
		end, opts)
	end

	-- Uppercase (HH, JJ, KK, etc.) - Opens file directly (no diff)
	for keybind, line_num in pairs(state.keybind_to_line_direct) do
		vim.keymap.set("n", keybind, function()
			update_cursor(line_num)
			open_file()
		end, opts)
	end

	-- Actions
	vim.keymap.set("n", "<CR>", open_diff, opts)
	vim.keymap.set("n", "o", open_file, opts)
	vim.keymap.set("n", "s", toggle_stage, opts)
	vim.keymap.set("n", "d", discard_changes, opts)
	vim.keymap.set("n", "p", toggle_path, opts)

	-- Close
	vim.keymap.set("n", "q", close_menu, opts)
	vim.keymap.set("n", "<Esc>", close_menu, opts)

	-- Make buffer non-modifiable
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

-- Render the git status menu
M.show = function()
	-- Set up highlight groups
	-- Selection uses Visual (keeps background)
	vim.api.nvim_set_hl(0, "BaGitMenuSelected", { link = "Visual", default = true })

	-- Extract foreground colors only (no background) so selection shows through
	local function get_fg_hl(name)
		local hl = vim.api.nvim_get_hl(0, { name = name })
		return { fg = hl.fg, bg = "NONE" }
	end

	vim.api.nvim_set_hl(0, "BaGitMenuAdded", get_fg_hl("DiffAdd"))
	vim.api.nvim_set_hl(0, "BaGitMenuModified", get_fg_hl("DiffChange"))
	vim.api.nvim_set_hl(0, "BaGitMenuDeleted", get_fg_hl("DiffDelete"))
	vim.api.nvim_set_hl(0, "BaGitMenuUntracked", get_fg_hl("Directory"))
	vim.api.nvim_set_hl(0, "BaGitMenuPath", get_fg_hl("Comment"))
	vim.api.nvim_set_hl(0, "BaGitMenuHeader", get_fg_hl("Title"))
	vim.api.nvim_set_hl(0, "BaGitMenuKeybind", get_fg_hl("Comment"))
	vim.api.nvim_set_hl(0, "BaGitMenuFilename", { fg = "NONE", bg = "NONE" })

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

	-- Hide cursor in this window by making it transparent
	-- Try to get background color from Normal or NormalFloat
	local normal_hl = vim.api.nvim_get_hl(0, { name = "NormalFloat" })
	local bg_color = normal_hl.bg

	if not bg_color then
		normal_hl = vim.api.nvim_get_hl(0, { name = "Normal" })
		bg_color = normal_hl.bg
	end

	-- Convert number to hex string if needed
	if bg_color and type(bg_color) == "number" then
		bg_color = string.format("#%06x", bg_color)
	elseif not bg_color then
		-- Fallback to black if no background found
		bg_color = "#000000"
	end

	vim.api.nvim_set_hl(0, "BaGitMenuCursor", { fg = bg_color, bg = bg_color, blend = 100 })

	local saved_guicursor = vim.opt.guicursor:get()
	vim.opt.guicursor = "a:block-BaGitMenuCursor"

	-- Auto-close window when navigating away (Option A: temporary overlay behavior)
	-- This autocmd will be automatically cleaned up when the buffer is wiped
	vim.api.nvim_create_autocmd("WinLeave", {
		buffer = state.buf,
		callback = function()
			-- Restore cursor
			vim.opt.guicursor = saved_guicursor

			-- Close the window when leaving it
			if state.win and vim.api.nvim_win_is_valid(state.win) then
				vim.api.nvim_win_close(state.win, true)
			end
		end,
		once = true, -- Only trigger once (then buffer gets wiped anyway)
	})

	-- First pass: Calculate max filename width for consistent columns (including icons)
	local max_filename_width = 0
	local has_devicons, devicons = pcall(require, "nvim-web-devicons")

	for _, entry in ipairs(status.staged) do
		local filename = vim.fn.fnamemodify(entry.file, ":t")
		local width = #filename
		-- Add icon width if devicons available (icon + space = ~3 chars)
		if has_devicons then
			width = width + 3
		end
		max_filename_width = math.max(max_filename_width, width)
	end
	for _, entry in ipairs(status.unstaged) do
		local filename = vim.fn.fnamemodify(entry.file, ":t")
		local width = #filename
		-- Add icon width if devicons available
		if has_devicons then
			width = width + 3
		end
		max_filename_width = math.max(max_filename_width, width)
	end

	-- Build lines
	local lines = {}
	local line_highlights = {} -- Store highlights for each line
	local line_num = 1
	local selectable_lines = {}
	local line_to_file = {}
	local keybind_to_line_diff = {}
	local keybind_to_line_direct = {}
	local keybind_idx = 1 -- Track keybind assignment

	-- Staged section
	table.insert(lines, string.format("Staged Changes (%d)", #status.staged))
	line_highlights[line_num] = { { group = "BaGitMenuHeader", start_col = 0, end_col = -1 } }
	table.insert(selectable_lines, line_num)
	line_to_file[line_num] = { is_category = true, section = "staged", files = status.staged }
	line_num = line_num + 1

	if #status.staged > 0 then
		for i, entry in ipairs(status.staged) do
			-- Assign both lowercase (diff) and uppercase (direct) keybinds
			local keybind_diff = nil
			local keybind_direct = nil

			if keybind_idx <= #keybind_sequence_diff then
				keybind_diff = keybind_sequence_diff[keybind_idx]
				keybind_to_line_diff[keybind_diff] = line_num
			end

			if keybind_idx <= #keybind_sequence_direct then
				keybind_direct = keybind_sequence_direct[keybind_idx]
				keybind_to_line_direct[keybind_direct] = line_num
			end

			-- Use lowercase keybind for display
			local keybind = keybind_diff
			keybind_idx = keybind_idx + 1

			local formatted = ui.format_file_line(entry.file, entry.status, state.width, max_filename_width, keybind)
			table.insert(lines, formatted.line)
			line_highlights[line_num] = formatted.highlights
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
	line_highlights[line_num] = { { group = "BaGitMenuHeader", start_col = 0, end_col = -1 } }
	table.insert(selectable_lines, line_num)
	line_to_file[line_num] = { is_category = true, section = "unstaged", files = status.unstaged }
	line_num = line_num + 1

	if #status.unstaged > 0 then
		for i, entry in ipairs(status.unstaged) do
			-- Assign both lowercase (diff) and uppercase (direct) keybinds
			local keybind_diff = nil
			local keybind_direct = nil

			if keybind_idx <= #keybind_sequence_diff then
				keybind_diff = keybind_sequence_diff[keybind_idx]
				keybind_to_line_diff[keybind_diff] = line_num
			end

			if keybind_idx <= #keybind_sequence_direct then
				keybind_direct = keybind_sequence_direct[keybind_idx]
				keybind_to_line_direct[keybind_direct] = line_num
			end

			-- Use lowercase keybind for display
			local keybind = keybind_diff
			keybind_idx = keybind_idx + 1

			local formatted = ui.format_file_line(entry.file, entry.status, state.width, max_filename_width, keybind)
			table.insert(lines, formatted.line)
			line_highlights[line_num] = formatted.highlights
			table.insert(selectable_lines, line_num)
			line_to_file[line_num] = { section = "unstaged", index = i, entry = entry }
			line_num = line_num + 1
		end
	end

	-- Store state
	state.lines = lines
	state.selectable_lines = selectable_lines
	state.line_to_file = line_to_file
	state.keybind_to_line_diff = keybind_to_line_diff
	state.keybind_to_line_direct = keybind_to_line_direct

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

	-- Apply syntax highlights to all lines
	for line_idx, highlights in pairs(line_highlights) do
		for _, hl in ipairs(highlights) do
			vim.api.nvim_buf_add_highlight(state.buf, ns_id_syntax, hl.group, line_idx - 1, hl.start_col, hl.end_col)
		end
	end

	vim.api.nvim_buf_set_option(state.buf, "modifiable", false)

	-- Apply highlight to initial cursor line
	if state.current_line then
		vim.api.nvim_buf_add_highlight(state.buf, ns_id_selection, "BaGitMenuSelected", state.current_line - 1, 0, -1)
	end

	-- Move vim cursor to initial line
	if state.win and vim.api.nvim_win_is_valid(state.win) and state.current_line then
		vim.api.nvim_win_set_cursor(state.win, { state.current_line, 0 })
	end

	-- Setup keymaps
	setup_keymaps(state.buf)
end

return M
