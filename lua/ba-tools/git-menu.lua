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
local last_mode = "status" -- Remember last mode (status or pr)

-- Cache for PR files data (speeds up refresh operations)
local pr_files_cache = {
	pr_number = nil,
	data = nil,
	timestamp = 0,
}

-- Loading state for PR mode
local pr_loading = false

-- State for the current menu instance
local state = {
	buf = nil,
	win = nil,
	width = 0,
	current_line = 1,
	current_mode = "status", -- "status" or "pr"
	lines = {},
	line_to_file = {}, -- Map line number to file entry
	line_highlights = {}, -- Store highlights for optimistic updates
	selectable_lines = {}, -- Lines that can be selected
	keybind_to_line_diff = {}, -- Map lowercase keybind to line number (opens diff)
	keybind_to_line_direct = {}, -- Map uppercase keybind to line number (opens directly)
}

-- Helper function to get GitHub hostname using gh CLI
local function get_github_hostname()
	-- Try to get repo URL from gh CLI which includes the hostname
	local repo_info = vim.fn.system("gh repo view --json url 2>&1"):gsub("%s+$", "")
	if vim.v.shell_error == 0 then
		local success, repo = pcall(vim.fn.json_decode, repo_info)
		if success and repo and repo.url then
			-- Extract hostname from URL (e.g., https://git.somelocalgithub.com/xxx/app)
			local hostname = repo.url:match("https://([^/]+)/")
			if hostname then
				return hostname
			end
		end
	end

	-- Fallback: extract from git remote URL
	local remote_url = vim.fn.system("git remote get-url origin 2>&1"):gsub("%s+$", "")
	if vim.v.shell_error == 0 then
		-- SSH format: git@hostname:owner/repo.git
		local hostname = remote_url:match("git@([^:]+):")
		if hostname then
			return hostname
		end

		-- HTTPS format: https://hostname/owner/repo.git
		hostname = remote_url:match("https://([^/]+)/")
		if hostname then
			return hostname
		end
	end

	return nil
end

-- Reset state
local function reset_state()
	state = {
		buf = nil,
		win = nil,
		width = 0,
		current_line = 1,
		current_mode = last_mode, -- Restore last mode
		lines = {},
		line_to_file = {},
		line_highlights = {},
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
		-- Ensure cursor position is valid
		if new_line >= 1 and new_line <= #state.lines then
			vim.api.nvim_win_set_cursor(state.win, { new_line, 0 })
		end
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
	-- Remember current mode before closing
	last_mode = state.current_mode

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

-- Generate window title based on current mode
local function get_window_title()
	if state.current_mode == "status" then
		return " Git [Status (S)]  Pull Request (P) "
	else
		return " Git Status (S)  [Pull Request (P)] "
	end
end

-- Update window title
local function update_window_title()
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		local config = vim.api.nvim_win_get_config(state.win)
		config.title = get_window_title()
		vim.api.nvim_win_set_config(state.win, config)
	end
end

-- Forward declaration for functions used before they're defined
local refresh_menu

-- Switch to a different mode
local function switch_mode(new_mode)
	if state.current_mode == new_mode then
		return -- Already in this mode
	end

	state.current_mode = new_mode
	last_mode = new_mode -- Remember for next time
	update_window_title()
	refresh_menu()
end

-- Render status mode
local function render_status_mode()
	-- Get git status
	local status, err = git.get_status()
	if not status then
		vim.notify("ba-tools: " .. (err or "Failed to get git status"), vim.log.levels.ERROR)
		close_menu()
		return nil
	end

	-- If no changes, display message but keep menu open for PR mode access
	if #status.conflicts == 0 and #status.staged == 0 and #status.unstaged == 0 then
		local lines = {}
		local line_highlights = {}
		local selectable_lines = {}
		local line_to_file = {}

		table.insert(lines, "")
		table.insert(lines, "No changes to display")
		table.insert(lines, "")
		line_highlights[2] = { { group = "BaGitMenuHeader", start_col = 0, end_col = -1 } }

		return {
			lines = lines,
			line_highlights = line_highlights,
			selectable_lines = selectable_lines,
			line_to_file = line_to_file,
			keybind_to_line_diff = {},
			keybind_to_line_direct = {},
			target_line = nil,
		}
	end

	-- Remember current section and index to maintain position after refresh
	local current_file_info = get_current_file()
	local target_section = current_file_info and current_file_info.section
	local target_index = current_file_info and current_file_info.index
	local target_is_category = current_file_info and current_file_info.is_category

	-- If no current file (e.g., first open), try to restore to last selected file
	local target_file = (current_file_info and current_file_info.entry and current_file_info.entry.file) or last_selected_file

	-- First pass: Calculate max filename width for consistent columns (including icons)
	local max_filename_width = 0
	local has_devicons, devicons = pcall(require, "nvim-web-devicons")

	for _, entry in ipairs(status.conflicts) do
		local filename = vim.fn.fnamemodify(entry.file, ":t")
		local width = #filename
		-- Add icon width if devicons available (icon + space = ~3 chars)
		if has_devicons then
			width = width + 3
		end
		max_filename_width = math.max(max_filename_width, width)
	end
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

	-- Merge Changes section (conflicts have highest priority)
	if #status.conflicts > 0 then
		table.insert(lines, string.format("Merge Changes (%d)", #status.conflicts))
		line_highlights[line_num] = { { group = "BaGitMenuHeader", start_col = 0, end_col = -1 } }
		table.insert(selectable_lines, line_num)
		line_to_file[line_num] = { is_category = true, section = "conflicts", files = status.conflicts }
		line_num = line_num + 1

		for i, entry in ipairs(status.conflicts) do
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
			line_to_file[line_num] = { section = "conflicts", index = i, entry = entry }
			line_num = line_num + 1
		end

		-- Empty line separator
		table.insert(lines, "")
		line_num = line_num + 1
	end

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

	-- Try to restore by file path if we have a target file
	if not target_line and target_file then
		for line, file_info in pairs(line_to_file) do
			if not file_info.is_category and file_info.entry and file_info.entry.file == target_file then
				target_line = line
				break
			end
		end
	end

	-- Fallback: if target not found, use first selectable line
	if not target_line and #selectable_lines > 0 then
		target_line = selectable_lines[1]
	end

	return {
		lines = lines,
		line_highlights = line_highlights,
		selectable_lines = selectable_lines,
		line_to_file = line_to_file,
		keybind_to_line_diff = keybind_to_line_diff,
		keybind_to_line_direct = keybind_to_line_direct,
		target_line = target_line,
	}
end

-- Async function to fetch PR files in background
local function fetch_pr_files_async(pr_data, hostname)
	-- Build the GraphQL query command
	local query = string.format([[
		query {
			repository(owner: "%s", name: "%s") {
				pullRequest(number: %d) {
					id
					files(first: 100) {
						nodes {
							path
							additions
							deletions
							viewerViewedState
						}
					}
				}
			}
		}
	]], pr_data.owner_login, pr_data.repo_name, pr_data.number)

	-- Build gh command with hostname via GH_HOST environment variable
	local cmd
	if hostname and hostname ~= "github.com" then
		cmd = string.format("GH_HOST=%s gh api graphql -f query=%s",
			vim.fn.shellescape(hostname), vim.fn.shellescape(query))
	else
		cmd = string.format("gh api graphql -f query=%s", vim.fn.shellescape(query))
	end

	-- Debug: log hostname if not github.com
	if hostname and hostname ~= "github.com" then
		vim.notify("Fetching PR files from: " .. hostname, vim.log.levels.INFO)
	end

	-- Start async job
	vim.fn.jobstart(cmd, {
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = function(_, data)
			if not data then return end
			local output = table.concat(data, "\n")

			vim.schedule(function()
				-- Parse the JSON response
				local success, graphql_result = pcall(vim.fn.json_decode, output)
				if success and graphql_result and graphql_result.data and
				   graphql_result.data.repository and
				   type(graphql_result.data.repository) == "table" and
				   graphql_result.data.repository.pullRequest then
					local pr = graphql_result.data.repository.pullRequest
					local pr_id = pr.id
					local files = pr.files.nodes or {}

					-- Build result with viewed status
					local pr_files = {}
					for _, file in ipairs(files) do
						table.insert(pr_files, {
							file = file.path,
							additions = file.additions or 0,
							deletions = file.deletions or 0,
							reviewed = file.viewerViewedState == "VIEWED",
							pr_id = pr_id,
						})
					end

					-- Update cache
					pr_files_cache.pr_number = pr_data.number
					pr_files_cache.data = pr_files
					pr_files_cache.timestamp = os.time()

					-- Mark as no longer loading
					pr_loading = false

					-- Refresh the menu with new data
					if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
						refresh_menu()
					end
				else
					-- Failed to parse or repository/PR not found, use fallback
					-- Log error for debugging
					if success and graphql_result then
						if graphql_result.errors then
							vim.notify("GitHub API error: " .. vim.inspect(graphql_result.errors), vim.log.levels.WARN)
						elseif not graphql_result.data then
							vim.notify("GitHub API returned no data", vim.log.levels.WARN)
						elseif not graphql_result.data.repository then
							vim.notify("Repository not found in response", vim.log.levels.WARN)
						elseif type(graphql_result.data.repository) ~= "table" then
							vim.notify("Repository field is not a table", vim.log.levels.WARN)
						else
							vim.notify("Pull request not found in repository", vim.log.levels.WARN)
						end
					elseif not success then
						vim.notify("Failed to parse GitHub API response: " .. tostring(graphql_result), vim.log.levels.WARN)
					end
					local pr_files = {}
					for _, file in ipairs(pr_data.files or {}) do
						table.insert(pr_files, {
							file = file.path,
							additions = file.additions or 0,
							deletions = file.deletions or 0,
							reviewed = false,
							pr_id = nil,
						})
					end

					pr_files_cache.pr_number = pr_data.number
					pr_files_cache.data = pr_files
					pr_files_cache.timestamp = os.time()
					pr_loading = false

					if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
						refresh_menu()
					end
				end
			end)
		end,
		on_stderr = function(_, data)
			if not data then return end
			local error_output = table.concat(data, "\n")
			if error_output ~= "" then
				vim.schedule(function()
					vim.notify("GitHub API stderr: " .. error_output, vim.log.levels.WARN)
				end)
			end
		end,
		on_exit = function(_, exit_code)
			if exit_code ~= 0 then
				vim.schedule(function()
					vim.notify("GitHub API command failed with exit code: " .. exit_code, vim.log.levels.WARN)
					-- Use fallback data
					if pr_data.files then
						local pr_files = {}
						for _, file in ipairs(pr_data.files) do
							table.insert(pr_files, {
								file = file.path,
								additions = file.additions or 0,
								deletions = file.deletions or 0,
								reviewed = false,
								pr_id = nil,
							})
						end

						pr_files_cache.pr_number = pr_data.number
						pr_files_cache.data = pr_files
						pr_files_cache.timestamp = os.time()
					end

					pr_loading = false
					if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
						refresh_menu()
					end
				end)
			end
		end,
	})
end

-- Render PR mode
local function render_pr_mode()
	local lines = {}
	local line_highlights = {}
	local selectable_lines = {}
	local line_to_file = {}
	local keybind_to_line_diff = {}
	local keybind_to_line_direct = {}

	-- Check if there's a PR for the current branch (this is fast, uses gh pr view)
	local pr_data, err = git.get_current_pr()

	if not pr_data then
		-- No PR found for current branch
		table.insert(lines, "")
		table.insert(lines, "No pull request open for this branch")
		table.insert(lines, "")
		line_highlights[2] = { { group = "BaGitMenuHeader", start_col = 0, end_col = -1 } }

		return {
			lines = lines,
			line_highlights = line_highlights,
			selectable_lines = selectable_lines,
			line_to_file = line_to_file,
			keybind_to_line_diff = keybind_to_line_diff,
			keybind_to_line_direct = keybind_to_line_direct,
			target_line = nil,
		}
	end

	-- Get PR files with review status (with caching)
	local pr_files
	local current_time = os.time()
	local cache_ttl = 120 -- Cache for 30 seconds to speed up refreshes

	-- Check if cache is valid
	if pr_files_cache.pr_number == pr_data.number and
	   pr_files_cache.data and
	   (current_time - pr_files_cache.timestamp) < cache_ttl then
		-- Use cached data (instant!)
		pr_files = pr_files_cache.data
	elseif pr_loading then
		-- Already loading, show loading message
		table.insert(lines, "")
		table.insert(lines, "Loading PR files...")
		table.insert(lines, "")
		line_highlights[2] = { { group = "BaGitMenuHeader", start_col = 0, end_col = -1 } }

		return {
			lines = lines,
			line_highlights = line_highlights,
			selectable_lines = selectable_lines,
			line_to_file = line_to_file,
			keybind_to_line_diff = keybind_to_line_diff,
			keybind_to_line_direct = keybind_to_line_direct,
			target_line = nil,
		}
	else
		-- Need to fetch - show loading message and start async fetch
		pr_loading = true

		-- Get GitHub hostname for enterprise instances
		local hostname = get_github_hostname()

		-- Get repo info for GraphQL query (gh repo view auto-detects host from git remote)
		local repo_info = vim.fn.system("gh repo view --json owner,name 2>&1")
		if vim.v.shell_error == 0 then
			local success, repo = pcall(vim.fn.json_decode, repo_info)
			if success and repo then
				pr_data.owner_login = repo.owner.login
				pr_data.repo_name = repo.name

				-- Start async fetch
				fetch_pr_files_async(pr_data, hostname)
			end
		end

		-- Return loading display immediately
		table.insert(lines, "")
		table.insert(lines, "Loading PR files...")
		table.insert(lines, "")
		line_highlights[2] = { { group = "BaGitMenuHeader", start_col = 0, end_col = -1 } }

		return {
			lines = lines,
			line_highlights = line_highlights,
			selectable_lines = selectable_lines,
			line_to_file = line_to_file,
			keybind_to_line_diff = keybind_to_line_diff,
			keybind_to_line_direct = keybind_to_line_direct,
			target_line = nil,
		}
	end

	-- Remember current file to maintain position after refresh
	local current_file_info = get_current_file()
	local target_file = (current_file_info and current_file_info.entry and current_file_info.entry.file) or last_selected_file

	-- First pass: Calculate max filename width
	local max_filename_width = 0
	local has_devicons, devicons = pcall(require, "nvim-web-devicons")

	for _, file_info in ipairs(pr_files) do
		local filename = vim.fn.fnamemodify(file_info.file, ":t")
		local width = #filename
		if has_devicons then
			width = width + 3
		end
		max_filename_width = math.max(max_filename_width, width)
	end

	-- Separate files into unchecked and checked
	local unchecked_files = {}
	local checked_files = {}

	for _, file_info in ipairs(pr_files) do
		if file_info.reviewed then
			table.insert(checked_files, file_info)
		else
			table.insert(unchecked_files, file_info)
		end
	end

	-- Build lines
	local line_num = 1
	local keybind_idx = 1

	-- PR title header
	table.insert(lines, string.format("Pull Request #%s: %s", pr_data.number, pr_data.title))
	line_highlights[line_num] = { { group = "BaGitMenuHeader", start_col = 0, end_col = -1 } }
	line_num = line_num + 1

	-- Empty line
	table.insert(lines, "")
	line_num = line_num + 1

	-- Unchecked Files section
	table.insert(lines, string.format("Unchecked Files (%d)", #unchecked_files))
	line_highlights[line_num] = { { group = "BaGitMenuHeader", start_col = 0, end_col = -1 } }
	table.insert(selectable_lines, line_num)
	line_to_file[line_num] = { is_category = true, section = "unchecked", files = unchecked_files }
	line_num = line_num + 1

	-- Render unchecked files
	if #unchecked_files > 0 then
		for i, file_info in ipairs(unchecked_files) do
			local filepath = file_info.file

			-- Assign keybinds
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

			local keybind = keybind_diff
			keybind_idx = keybind_idx + 1

			-- Determine status indicator based on changes
			local status = "M"
			if file_info.additions and file_info.additions > 0 and (not file_info.deletions or file_info.deletions == 0) then
				status = "A" -- Mostly additions
			elseif file_info.deletions and file_info.deletions > 0 and (not file_info.additions or file_info.additions == 0) then
				status = "D" -- Mostly deletions
			end

			-- Format the line similar to status mode
			local formatted = ui.format_file_line(filepath, status, state.width, max_filename_width, keybind)

			table.insert(lines, formatted.line)

			-- Copy highlights from formatted line
			line_highlights[line_num] = formatted.highlights

			-- Add red text color for unchecked files
			table.insert(line_highlights[line_num], {
				group = "BaGitMenuPRNotReviewed",
				start_col = 0,
				end_col = -1,
			})

			table.insert(selectable_lines, line_num)
			line_to_file[line_num] = {
				section = "unchecked",
				index = i,
				entry = {
					file = filepath,
					status = status,
					additions = file_info.additions or 0,
					deletions = file_info.deletions or 0,
					reviewed = false,
					pr_id = file_info.pr_id,
				},
			}
			line_num = line_num + 1
		end
	end

	-- Empty line separator
	table.insert(lines, "")
	line_num = line_num + 1

	-- Checked Files section
	table.insert(lines, string.format("Checked Files (%d)", #checked_files))
	line_highlights[line_num] = { { group = "BaGitMenuHeader", start_col = 0, end_col = -1 } }
	table.insert(selectable_lines, line_num)
	line_to_file[line_num] = { is_category = true, section = "checked", files = checked_files }
	line_num = line_num + 1

	-- Render checked files
	if #checked_files > 0 then
		for i, file_info in ipairs(checked_files) do
			local filepath = file_info.file

			-- Assign keybinds
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

			local keybind = keybind_diff
			keybind_idx = keybind_idx + 1

			-- Determine status indicator based on changes
			local status = "M"
			if file_info.additions and file_info.additions > 0 and (not file_info.deletions or file_info.deletions == 0) then
				status = "A" -- Mostly additions
			elseif file_info.deletions and file_info.deletions > 0 and (not file_info.additions or file_info.additions == 0) then
				status = "D" -- Mostly deletions
			end

			-- Format the line similar to status mode
			local formatted = ui.format_file_line(filepath, status, state.width, max_filename_width, keybind)

			table.insert(lines, formatted.line)

			-- Copy highlights from formatted line
			line_highlights[line_num] = formatted.highlights

			-- Add green text color for checked files
			table.insert(line_highlights[line_num], {
				group = "BaGitMenuPRReviewed",
				start_col = 0,
				end_col = -1,
			})

			table.insert(selectable_lines, line_num)
			line_to_file[line_num] = {
				section = "checked",
				index = i,
				entry = {
					file = filepath,
					status = status,
					additions = file_info.additions or 0,
					deletions = file_info.deletions or 0,
					reviewed = true,
					pr_id = file_info.pr_id,
				},
			}
			line_num = line_num + 1
		end
	end

	-- Calculate target line for cursor positioning
	local target_line = nil
	if target_file then
		-- Try to restore to the same file
		for line, file_info in pairs(line_to_file) do
			if file_info.entry and file_info.entry.file == target_file then
				target_line = line
				break
			end
		end
	end

	-- Fallback to first selectable line
	if not target_line and #selectable_lines > 0 then
		target_line = selectable_lines[1]
	end

	return {
		lines = lines,
		line_highlights = line_highlights,
		selectable_lines = selectable_lines,
		line_to_file = line_to_file,
		keybind_to_line_diff = keybind_to_line_diff,
		keybind_to_line_direct = keybind_to_line_direct,
		target_line = target_line,
	}
end

-- Refresh the menu (rebuild contents)
refresh_menu = function()
	local render_data

	-- Dispatch to appropriate renderer based on mode
	if state.current_mode == "status" then
		render_data = render_status_mode()
	elseif state.current_mode == "pr" then
		render_data = render_pr_mode()
	else
		vim.notify("Unknown mode: " .. state.current_mode, vim.log.levels.ERROR)
		return
	end

	-- If rendering failed or returned nil, exit
	if not render_data then
		return
	end

	-- Store state
	state.lines = render_data.lines
	state.line_highlights = render_data.line_highlights
	state.selectable_lines = render_data.selectable_lines
	state.line_to_file = render_data.line_to_file
	state.keybind_to_line_diff = render_data.keybind_to_line_diff
	state.keybind_to_line_direct = render_data.keybind_to_line_direct

	-- Set cursor position
	if render_data.target_line and is_selectable(render_data.target_line) then
		state.current_line = render_data.target_line
	elseif #render_data.selectable_lines > 0 then
		state.current_line = render_data.selectable_lines[1]
	end

	-- Update buffer
	vim.api.nvim_buf_set_option(state.buf, "modifiable", true)
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, state.lines)
	vim.api.nvim_buf_set_option(state.buf, "modifiable", false)

	-- Clear both namespaces before re-applying highlights
	vim.api.nvim_buf_clear_namespace(state.buf, ns_id_syntax, 0, -1)
	vim.api.nvim_buf_clear_namespace(state.buf, ns_id_selection, 0, -1)

	-- Apply syntax highlights to all lines
	for line_idx, highlights in pairs(render_data.line_highlights) do
		for _, hl in ipairs(highlights) do
			vim.api.nvim_buf_add_highlight(state.buf, ns_id_syntax, hl.group, line_idx - 1, hl.start_col, hl.end_col)
		end
	end

	-- Apply selection highlight
	if state.current_line and state.current_line >= 1 and state.current_line <= #state.lines then
		vim.api.nvim_buf_add_highlight(state.buf, ns_id_selection, "BaGitMenuSelected", state.current_line - 1, 0, -1)
	end

	-- Move vim cursor to the current line
	if state.win and vim.api.nvim_win_is_valid(state.win) and state.current_line then
		-- Ensure cursor position is within bounds
		if state.current_line >= 1 and state.current_line <= #state.lines then
			vim.api.nvim_win_set_cursor(state.win, { state.current_line, 0 })
		end
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
	-- Only works in status mode
	if state.current_mode ~= "status" then
		vim.notify("This action is only available in Status mode", vim.log.levels.WARN)
		return
	end

	local file_info = get_current_file()
	if not file_info then
		return
	end

	-- For conflicts, staging is allowed - git will validate if conflicts are resolved
	-- If conflict markers remain, git will error which we'll show to the user

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

-- Open diff using diffview with custom configuration (no file panel)
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
		-- Close any existing diffview
		vim.cmd("DiffviewClose")
		-- Close all windows and open file cleanly
		vim.cmd("only")
		vim.cmd("edit " .. vim.fn.fnameescape(filepath))
		return
	end

	-- Close menu
	close_menu()

	-- Load diffview module
	local ok, diffview = pcall(require, 'diffview')
	if not ok then
		vim.notify("Diffview not available, falling back to native diff", vim.log.levels.WARN)
		vim.cmd("edit " .. vim.fn.fnameescape(filepath))
		return
	end

	-- Determine what to diff against based on mode
	local diff_base = "HEAD"
	if state.current_mode == "pr" then
		-- In PR mode: diff against base branch
		local pr_data, err = git.get_current_pr()
		if pr_data and pr_data.baseRefName then
			diff_base = pr_data.baseRefName
		else
			-- Fallback to main if we can't get base branch
			diff_base = "main"
		end
	end

	-- Open diff view
	vim.cmd("DiffviewOpen " .. diff_base .. " -- " .. vim.fn.fnameescape(filepath))

	-- Wait for diffview to open, then close the file panel
	vim.defer_fn(function()
		local diffview_lib = require('diffview.lib')
		local view = diffview_lib.get_current_view()

		if view and view.panel then
			-- Close the file panel (left side list)
			if view.panel:is_open() then
				view.panel:close()
			end
		end
	end, 100) -- 100ms delay to let diffview fully initialize
end

-- Discard changes to the selected file
local function discard_changes()
	-- Only works in status mode
	if state.current_mode ~= "status" then
		vim.notify("This action is only available in Status mode", vim.log.levels.WARN)
		return
	end

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

	-- Handle conflicts differently
	if section == "conflicts" then
		local choice = vim.fn.confirm(
			string.format("Resolve conflict in '%s' by accepting incoming changes (theirs)?\nThis will discard your local changes.", filepath),
			"&Yes\n&No",
			2
		)

		if choice ~= 1 then
			return
		end

		-- For conflicts, use git checkout --theirs to accept incoming changes
		local cmd = string.format("git checkout --theirs %s && git add %s", vim.fn.shellescape(filepath), vim.fn.shellescape(filepath))
		local output = vim.fn.system(cmd)
		if vim.v.shell_error ~= 0 then
			vim.notify("Failed to resolve conflict: " .. output, vim.log.levels.ERROR)
		else
			vim.notify("Resolved conflict by accepting incoming changes: " .. filepath, vim.log.levels.INFO)
			refresh_menu()
		end
		return
	end

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

-- Revert unstaged changes (restore from staged or HEAD)
local function revert_unstaged()
	-- Only works in status mode
	if state.current_mode ~= "status" then
		vim.notify("This action is only available in Status mode", vim.log.levels.WARN)
		return
	end

	local file_info = get_current_file()
	if not file_info then
		return
	end

	-- Handle category reverting
	if file_info.is_category then
		local section = file_info.section

		-- Can only revert unstaged category
		if section == "staged" then
			vim.notify("Cannot revert staged changes. Use this on unstaged files only.", vim.log.levels.WARN)
			return
		end

		local files = file_info.files or {}
		if #files == 0 then
			vim.notify("No files to revert in this category.", vim.log.levels.WARN)
			return
		end

		-- Confirm before reverting all files
		local choice = vim.fn.confirm(
			string.format("Revert all %d files in this category?", #files),
			"&Yes\n&No",
			2
		)

		if choice ~= 1 then
			return
		end

		-- Revert all files
		local failed = {}
		for _, entry in ipairs(files) do
			local success, restore_err = git.restore_file(entry.file)
			if not success then
				table.insert(failed, entry.file)
			end
		end

		if #failed > 0 then
			vim.notify(string.format("Failed to revert %d files: %s", #failed, table.concat(failed, ", ")), vim.log.levels.ERROR)
		else
			vim.notify(string.format("Reverted %d files", #files), vim.log.levels.INFO)
		end
		refresh_menu()
		return
	end

	local filepath = file_info.entry.file
	local section = file_info.section

	-- Handle conflicts - offer to accept our changes (ours)
	if section == "conflicts" then
		local choice = vim.fn.confirm(
			string.format("Resolve conflict in '%s' by keeping your local changes (ours)?", filepath),
			"&Yes\n&No",
			2
		)

		if choice ~= 1 then
			return
		end

		-- For conflicts, use git checkout --ours to keep our changes
		local cmd = string.format("git checkout --ours %s && git add %s", vim.fn.shellescape(filepath), vim.fn.shellescape(filepath))
		local output = vim.fn.system(cmd)
		if vim.v.shell_error ~= 0 then
			vim.notify("Failed to resolve conflict: " .. output, vim.log.levels.ERROR)
		else
			vim.notify("Resolved conflict by keeping your local changes: " .. filepath, vim.log.levels.INFO)
			refresh_menu()
		end
		return
	end

	-- Can only revert unstaged changes
	if section == "staged" then
		vim.notify("Cannot revert staged changes. Use this on unstaged files only.", vim.log.levels.WARN)
		return
	end

	-- Check if file is also staged to determine restore source
	local is_also_staged = false
	local status, err = git.get_status()
	if status then
		for _, entry in ipairs(status.staged) do
			if entry.file == filepath then
				is_also_staged = true
				break
			end
		end
	end

	-- Confirm before reverting
	local restore_source = is_also_staged and "staged version" or "HEAD"
	local choice = vim.fn.confirm(
		string.format("Revert '%s' to %s?", filepath, restore_source),
		"&Yes\n&No",
		2
	)

	if choice ~= 1 then
		return
	end

	-- Revert the changes using git restore
	local success, restore_err = git.restore_file(filepath)
	if success then
		vim.notify(string.format("Reverted to %s: %s", restore_source, filepath), vim.log.levels.INFO)
		refresh_menu()
	else
		vim.notify(restore_err, vim.log.levels.ERROR)
	end
end

-- Toggle file review status in PR mode
local function toggle_review_status()
	-- Only works in PR mode
	if state.current_mode ~= "pr" then
		vim.notify("This action is only available in Pull Request mode", vim.log.levels.WARN)
		return
	end

	local file_info = get_current_file()
	if not file_info or not file_info.entry then
		return
	end

	local filepath = file_info.entry.file
	local pr_id = file_info.entry.pr_id
	local is_reviewed = file_info.entry.reviewed or false
	local current_section = file_info.section

	-- Check if we have a PR ID
	if not pr_id then
		vim.notify("PR ID not available. Try refreshing the menu.", vim.log.levels.ERROR)
		return
	end

	-- Check if cache is available
	if not pr_files_cache.data then
		vim.notify("Cache not available. Try refreshing the menu.", vim.log.levels.ERROR)
		return
	end

	-- Calculate new status
	local new_reviewed_status = not is_reviewed

	-- If we're marking a file as checked (was unchecked), find the next unchecked file
	-- so we can position on it after the refresh
	local next_unchecked_file = nil
	if not is_reviewed and current_section == "unchecked" then
		-- Build a sorted list of line numbers for unchecked files
		local unchecked_lines = {}
		for line_num, line_file_info in pairs(state.line_to_file) do
			if not line_file_info.is_category and line_file_info.section == "unchecked" then
				table.insert(unchecked_lines, line_num)
			end
		end
		table.sort(unchecked_lines)

		-- Find the next unchecked file after the current line
		local found_next = false
		for _, line_num in ipairs(unchecked_lines) do
			if line_num > state.current_line then
				next_unchecked_file = state.line_to_file[line_num].entry.file
				found_next = true
				break
			end
		end

		-- If we didn't find a next file (we were on the last one), get the first unchecked file
		-- But only if there are other unchecked files remaining
		if not found_next and #unchecked_lines > 1 then
			next_unchecked_file = state.line_to_file[unchecked_lines[1]].entry.file
		end

		-- Update last_selected_file so the refresh positions on the next unchecked file
		if next_unchecked_file and next_unchecked_file ~= filepath then
			last_selected_file = next_unchecked_file
		end
	end

	-- OPTION 1: IN-PLACE CACHE UPDATE
	-- Find the file in cache and update its reviewed status
	local cache_file_updated = false
	for _, cached_file in ipairs(pr_files_cache.data) do
		if cached_file.file == filepath then
			cached_file.reviewed = new_reviewed_status
			cache_file_updated = true
			break
		end
	end

	if not cache_file_updated then
		vim.notify("File not found in cache. Try refreshing the menu.", vim.log.levels.ERROR)
		return
	end

	-- Clear current_line so render_pr_mode doesn't try to stay on the current file
	-- This forces it to use last_selected_file instead
	state.current_line = nil

	-- Immediately refresh menu with updated cache (instant!)
	refresh_menu()

	-- Show immediate feedback
	local new_status_text = new_reviewed_status and "reviewed" or "unreviewed"
	vim.notify(string.format("Marking as %s: %s", new_status_text, filepath), vim.log.levels.INFO)

	-- Get GitHub hostname for enterprise instances
	local hostname = get_github_hostname()

	-- Run API call in background using jobstart (non-blocking)
	local mutation = string.format(
		[[mutation { %s(input: {pullRequestId: "%s", path: "%s"}) { pullRequest { id } } }]],
		new_reviewed_status and "markFileAsViewed" or "unmarkFileAsViewed",
		pr_id,
		filepath
	)

	local cmd
	if hostname and hostname ~= "github.com" then
		cmd = string.format("GH_HOST=%s gh api graphql -f query=%s",
			vim.fn.shellescape(hostname), vim.fn.shellescape(mutation))
	else
		cmd = string.format("gh api graphql -f query=%s", vim.fn.shellescape(mutation))
	end

	vim.fn.jobstart(cmd, {
		stderr_buffered = true,
		on_stderr = function(_, data)
			if not data then return end
			local error_output = table.concat(data, "\n")
			if error_output ~= "" then
				vim.schedule(function()
					vim.notify("Failed to toggle review status: " .. error_output, vim.log.levels.ERROR)
				end)
			end
		end,
		on_exit = function(_, exit_code)
			if exit_code ~= 0 then
				-- API call failed - revert the cache update and refresh
				vim.schedule(function()
					-- Find the file in cache and revert its status
					for _, cached_file in ipairs(pr_files_cache.data) do
						if cached_file.file == filepath then
							cached_file.reviewed = is_reviewed
							break
						end
					end

					-- Refresh menu to show reverted state
					if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
						refresh_menu()
					end

					vim.notify(
						string.format("Failed to sync review status for: %s (exit code: %d)", filepath, exit_code),
						vim.log.levels.ERROR
					)
				end)
			else
				-- API call succeeded - cache is already correct, no action needed
				-- The cache already has the correct state, and we don't need to refetch from server
			end
		end,
	})
end

-- Revert a file to base branch in PR mode (delete new files, restore modified/deleted files)
local function revert_pr_file()
	-- Only works in PR mode
	if state.current_mode ~= "pr" then
		vim.notify("This action is only available in Pull Request mode", vim.log.levels.WARN)
		return
	end

	local file_info = get_current_file()
	if not file_info or not file_info.entry then
		return
	end

	-- Cannot revert a category
	if file_info.is_category then
		vim.notify("Cannot revert category. Select individual files.", vim.log.levels.WARN)
		return
	end

	local filepath = file_info.entry.file
	local status = file_info.entry.status

	-- Get base branch from PR data
	local pr_data, err = git.get_current_pr()
	local base_ref = "main" -- fallback
	if pr_data and pr_data.baseRefName then
		base_ref = pr_data.baseRefName
	end

	-- Determine action based on status
	local action_desc
	if status == "A" then
		action_desc = string.format("delete '%s' (new file in PR)", filepath)
	elseif status == "D" then
		action_desc = string.format("restore '%s' from '%s' (deleted in PR)", filepath, base_ref)
	else
		action_desc = string.format("revert '%s' to '%s' branch", filepath, base_ref)
	end

	-- Confirm before reverting
	local choice = vim.fn.confirm(
		string.format("Are you sure you want to %s?", action_desc),
		"&Yes\n&No",
		2
	)

	if choice ~= 1 then
		return
	end

	-- Execute revert
	local success, revert_err = git.revert_to_base(filepath, base_ref)
	if success then
		vim.notify(string.format("Reverted: %s", filepath), vim.log.levels.INFO)
		refresh_menu()
	else
		vim.notify(revert_err, vim.log.levels.ERROR)
	end
end

-- Toggle (stage/unstage) all files at the current file's path
local function toggle_path()
	-- Only works in status mode
	if state.current_mode ~= "status" then
		vim.notify("This action is only available in Status mode", vim.log.levels.WARN)
		return
	end

	local file_info = get_current_file()
	if not file_info then
		return
	end

	-- For conflicts, allow staging - git will validate if resolved

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
	vim.keymap.set("n", "r", function()
		if state.current_mode == "status" then
			revert_unstaged()
		else -- pr mode
			revert_pr_file()
		end
	end, opts)
	vim.keymap.set("n", "p", toggle_path, opts)
	vim.keymap.set("n", "c", toggle_review_status, opts)

	-- Close
	vim.keymap.set("n", "q", close_menu, opts)
	vim.keymap.set("n", "<Esc>", close_menu, opts)

	-- Mode switching
	vim.keymap.set("n", "S", function()
		switch_mode("status")
	end, opts)
	vim.keymap.set("n", "P", function()
		switch_mode("pr")
	end, opts)

	-- Make buffer non-modifiable
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

-- Render the git status menu
M.show = function()
	-- Initialize state if needed (first time opening or after reset)
	if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
		state.current_mode = last_mode -- Restore last mode
	end

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
	vim.api.nvim_set_hl(0, "BaGitMenuConflict", get_fg_hl("ErrorMsg"))
	vim.api.nvim_set_hl(0, "BaGitMenuPath", get_fg_hl("Comment"))
	vim.api.nvim_set_hl(0, "BaGitMenuHeader", get_fg_hl("Title"))
	vim.api.nvim_set_hl(0, "BaGitMenuKeybind", get_fg_hl("Comment"))
	vim.api.nvim_set_hl(0, "BaGitMenuFilename", { fg = "NONE", bg = "NONE" })

	-- PR review status highlights (full line text colors)
	-- Get DiffAdd/DiffDelete foreground colors for reviewed/not reviewed
	local diff_add_hl = vim.api.nvim_get_hl(0, { name = "DiffAdd" })
	local diff_delete_hl = vim.api.nvim_get_hl(0, { name = "DiffDelete" })

	-- Use foreground colors - green for reviewed, red for not reviewed
	vim.api.nvim_set_hl(0, "BaGitMenuPRReviewed", {
		fg = diff_add_hl.fg or "#00ff00",  -- Green fallback
		bg = "NONE"
	})
	vim.api.nvim_set_hl(0, "BaGitMenuPRNotReviewed", {
		fg = diff_delete_hl.fg or "#ff0000",  -- Red fallback
		bg = "NONE"
	})

	-- Create window
	local window = ui.create_centered_window(get_window_title(), 0.6, 0.6)
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

	-- Auto-close window when navigating away
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

	-- Render content based on current mode
	refresh_menu()

	-- Setup keymaps only if buffer is still valid
	-- (refresh_menu might have closed the menu if there are no changes)
	if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
		setup_keymaps(state.buf)
	end
end

return M
