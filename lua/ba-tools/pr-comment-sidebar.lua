local M = {}

-- Sidebar state
local state = {
	buf = nil, -- Sidebar buffer number
	win = nil, -- Sidebar window ID
	filepath = "", -- Current file being viewed
	diff_base = "", -- Base ref for diff
	comments = {}, -- Array of comment objects
	current_idx = 1, -- Currently selected comment index
	diff_bufnr = nil, -- Buffer number of diff view (for syncing)
	cache = {}, -- Comment cache per file
	cache_ttl = 120, -- Cache TTL in seconds
	sign_group = "ba_pr_comments", -- Sign group name
	ns_id = vim.api.nvim_create_namespace("ba_pr_comments"), -- Namespace for extmarks
}

-- Define sign on module load
vim.fn.sign_define("BaPrComment", {
	text = "💬",
	texthl = "DiagnosticInfo",
})

-- Helper: Truncate comment text for inline preview
local function truncate_comment(text, max_len)
	max_len = max_len or 60

	-- Get first line only
	local first_line = text:match("^[^\n]+") or text

	-- Remove leading/trailing whitespace
	first_line = first_line:gsub("^%s+", ""):gsub("%s+$", "")

	-- Truncate if too long
	if #first_line > max_len then
		return first_line:sub(1, max_len - 3) .. "..."
	end

	return first_line
end

-- Comment cache structure: { [filepath] = { comments = {}, timestamp = os.time() } }

-- Helper: Get relative timestamp string
local function format_relative_time(timestamp)
	if not timestamp then
		return ""
	end

	-- Parse ISO 8601 timestamp: 2025-11-05T12:00:00Z
	local year, month, day, hour, min, sec = timestamp:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z")
	if not year then
		return ""
	end

	local comment_time = os.time({
		year = tonumber(year),
		month = tonumber(month),
		day = tonumber(day),
		hour = tonumber(hour),
		min = tonumber(min),
		sec = tonumber(sec),
	})

	local now = os.time()
	local diff = now - comment_time

	if diff < 60 then
		return "just now"
	elseif diff < 3600 then
		local mins = math.floor(diff / 60)
		return string.format("%dm ago", mins)
	elseif diff < 86400 then
		local hours = math.floor(diff / 3600)
		return string.format("%dh ago", hours)
	else
		local days = math.floor(diff / 86400)
		return string.format("%dd ago", days)
	end
end

-- Fetch existing GitHub PR comments for a file
M.fetch_github_comments = function(filepath)
	-- Check cache first (no TTL - use R to manually refresh)
	local cached = state.cache[filepath]
	if cached then
		return cached.comments
	end

	-- Get current PR number
	local pr_cmd = "gh pr view --json number 2>&1"
	local pr_output = vim.fn.system(pr_cmd)

	if vim.v.shell_error ~= 0 then
		return {}, "Not in a PR branch"
	end

	local success, pr_data = pcall(vim.fn.json_decode, pr_output)
	if not success or not pr_data then
		return {}, "Failed to parse PR data"
	end

	-- Get repo info
	local repo_cmd = "gh repo view --json owner,name 2>&1"
	local repo_output = vim.fn.system(repo_cmd)

	if vim.v.shell_error ~= 0 then
		return {}, "Failed to get repo info"
	end

	local success2, repo = pcall(vim.fn.json_decode, repo_output)
	if not success2 or not repo then
		return {}, "Failed to parse repo info"
	end

	-- Fetch ALL review comments for this PR (we'll filter in Lua)
	local api_path = string.format("repos/%s/%s/pulls/%s/comments", repo.owner.login, repo.name, pr_data.number)

	local cmd = string.format("gh api %s 2>&1", api_path)

	-- Debug: log what we're fetching
	vim.notify(string.format("Fetching all PR comments, will filter for: %s", filepath), vim.log.levels.DEBUG)

	local output = vim.fn.system(cmd)

	if vim.v.shell_error ~= 0 then
		vim.notify("GitHub API error: " .. output, vim.log.levels.ERROR)
		return {}, "Failed to fetch comments from GitHub: " .. output
	end

	local success3, all_comments_data = pcall(vim.fn.json_decode, output)
	if not success3 or not all_comments_data then
		vim.notify("Failed to parse JSON from GitHub API", vim.log.levels.ERROR)
		return {}, "Failed to parse GitHub comments"
	end

	-- Debug: log how many total comments we got
	vim.notify(string.format("Fetched %d total PR comments", #all_comments_data), vim.log.levels.DEBUG)

	-- Filter comments for this specific file in Lua
	local comments = {}
	for _, comment in ipairs(all_comments_data) do
		-- Debug: log each comment's path to help diagnose filepath mismatches
		if comment.path then
			vim.notify(string.format("Comment path: '%s' (looking for: '%s')", comment.path, filepath), vim.log.levels.DEBUG)
		end

		-- Match comments for this file
		if comment.path == filepath then
			table.insert(comments, {
				line = comment.line or comment.original_line or 0,
				author = comment.user and comment.user.login or "unknown",
				body = comment.body or "",
				created_at = comment.created_at or "",
				id = comment.id,
			})
		end
	end

	-- Debug: log how many comments matched this file
	vim.notify(string.format("Found %d comment(s) for this file", #comments), vim.log.levels.INFO)

	-- Cache the results
	state.cache[filepath] = {
		comments = comments,
		timestamp = os.time(),
	}

	return comments
end

-- Fetch local draft comments from diff
M.fetch_local_comments = function(filepath, diff_base)
	local pr_comments = require("ba-tools.pr-comments")

	-- Scan file for added comments
	local blocks, err = pr_comments.scan_file(filepath, diff_base)

	if not blocks then
		return {}, err
	end

	-- Transform to our format
	local comments = {}
	for _, block in ipairs(blocks) do
		table.insert(comments, {
			line = block.start_line,
			author = nil,
			body = block.text,
			created_at = nil,
			id = nil,
			is_draft = true,
			lines = count_lines(block.text),
			collapsed = true,
		})
	end

	-- Debug: log number of local comments found
	if #comments > 0 then
		vim.notify(string.format("Found %d local comment block(s)", #comments), vim.log.levels.DEBUG)
	end

	return comments
end

-- Sort comments by line number
M.sort_comments = function(comments)
	-- Sort by line number
	table.sort(comments, function(a, b)
		return a.line < b.line
	end)

	return comments
end

-- Render sidebar buffer with comment list
M.render_sidebar = function()
	if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
		return
	end

	local lines = {}
	local highlights = {}

	-- Filename header (simpler since window has title bar)
	local filename = vim.fn.fnamemodify(state.filepath, ":t")
	table.insert(lines, filename)
	table.insert(highlights, { line = 0, group = "Comment" })
	table.insert(lines, "")

	if #state.comments == 0 then
		table.insert(lines, "No comments yet")
		table.insert(highlights, { line = 2, group = "Comment" })
	else
		for i, comment in ipairs(state.comments) do
			local line_idx = #lines

			-- GitHub comment header
			local time_str = format_relative_time(comment.created_at)
			local line_text = string.format("L%-4d 💬 @%s", comment.line, comment.author)
			if time_str ~= "" then
				line_text = line_text .. string.format(" [%s]", time_str)
			end
			table.insert(lines, line_text)
			table.insert(highlights, { line = line_idx, group = "Title" })

			-- Show full comment body (always expanded)
			for body_line in comment.body:gmatch("[^\n]+") do
				table.insert(lines, "  " .. body_line)
				table.insert(highlights, { line = #lines - 1, group = "Normal" })
			end

			-- Add spacing between comments
			table.insert(lines, "")

			-- Highlight current selection
			if i == state.current_idx then
				table.insert(highlights, { line = line_idx, group = "Visual" })
			end
		end
	end

	-- Footer (help text)
	table.insert(lines, "")
	table.insert(lines, "")
	table.insert(lines, "Keys: j/k=nav J=jump R=refresh C/q=close")
	table.insert(highlights, { line = #lines - 1, group = "Comment" })

	-- Set buffer content
	vim.api.nvim_buf_set_option(state.buf, "modifiable", true)
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(state.buf, "modifiable", false)

	-- Apply highlights
	local ns = vim.api.nvim_create_namespace("ba-pr-comment-sidebar")
	vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)

	for _, hl in ipairs(highlights) do
		vim.api.nvim_buf_add_highlight(state.buf, ns, hl.group, hl.line, 0, -1)
	end
end

-- Navigate to next/previous comment
M.navigate = function(direction)
	if #state.comments == 0 then
		return
	end

	state.current_idx = state.current_idx + direction

	-- Wrap around
	if state.current_idx < 1 then
		state.current_idx = #state.comments
	elseif state.current_idx > #state.comments then
		state.current_idx = 1
	end

	M.render_sidebar()
end

-- Jump to comment line in diff view
M.jump_to_line = function()
	if #state.comments == 0 then
		return
	end

	local comment = state.comments[state.current_idx]
	if not comment or not state.diff_bufnr or not vim.api.nvim_buf_is_valid(state.diff_bufnr) then
		return
	end

	-- Find window containing diff buffer
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(win) == state.diff_bufnr then
			vim.api.nvim_set_current_win(win)
			vim.api.nvim_win_set_cursor(win, { comment.line, 0 })
			-- Center line in window
			vim.cmd("normal! zz")
			return
		end
	end
end

-- Place signs and virtual text in diff buffer for lines with comments
local function place_signs()
	if not state.diff_bufnr or not vim.api.nvim_buf_is_valid(state.diff_bufnr) then
		return
	end

	-- Clear existing signs and extmarks first
	vim.fn.sign_unplace(state.sign_group, { buffer = state.diff_bufnr })
	vim.api.nvim_buf_clear_namespace(state.diff_bufnr, state.ns_id, 0, -1)

	-- Place sign and virtual text for each comment
	for _, comment in ipairs(state.comments) do
		if comment.line and comment.line > 0 then
			-- Place sign in gutter
			vim.fn.sign_place(0, state.sign_group, "BaPrComment", state.diff_bufnr, {
				lnum = comment.line,
				priority = 10,
			})

			-- Create inline preview text
			local preview = truncate_comment(comment.body, 60)
			local virt_text = string.format("💬 @%s: %s", comment.author, preview)

			-- Place virtual text at end of line
			vim.api.nvim_buf_set_extmark(state.diff_bufnr, state.ns_id, comment.line - 1, 0, {
				virt_text = { { virt_text, "Comment" } },
				virt_text_pos = "eol",
				priority = 100,
			})
		end
	end
end

-- Clear all signs and virtual text from diff buffer
local function clear_signs()
	if state.diff_bufnr and vim.api.nvim_buf_is_valid(state.diff_bufnr) then
		vim.fn.sign_unplace(state.sign_group, { buffer = state.diff_bufnr })
		vim.api.nvim_buf_clear_namespace(state.diff_bufnr, state.ns_id, 0, -1)
	end
end

-- Refresh comments (re-fetch from GitHub)
M.refresh = function()
	-- Clear cache for this file
	state.cache[state.filepath] = nil

	-- Re-fetch GitHub comments
	local github_comments = M.fetch_github_comments(state.filepath)

	-- Update state
	state.comments = M.sort_comments(github_comments)
	state.current_idx = math.min(state.current_idx, #state.comments)
	if state.current_idx == 0 then
		state.current_idx = 1
	end

	-- Update signs
	place_signs()

	M.render_sidebar()
	vim.notify("Comments refreshed", vim.log.levels.INFO)
end

-- Close sidebar (keep signs visible)
M.close_sidebar = function()
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		vim.api.nvim_win_close(state.win, true)
	end

	-- Don't clear signs - keep them visible
	-- Don't clear comments - keep them cached for re-opening

	state.win = nil
	state.buf = nil
	state.current_idx = 1
end

-- Clear all state including signs (called when leaving diff view)
M.clear_all = function()
	M.close_sidebar()
	clear_signs()
	state.comments = {}
	state.filepath = ""
	state.diff_base = ""
	state.diff_bufnr = nil
end

-- Setup keybindings for sidebar buffer
local function setup_keymaps(buf)
	local opts = { buffer = buf, nowait = true, silent = true }

	vim.keymap.set("n", "j", function()
		M.navigate(1)
	end, opts)
	vim.keymap.set("n", "k", function()
		M.navigate(-1)
	end, opts)
	vim.keymap.set("n", "J", M.jump_to_line, opts)
	vim.keymap.set("n", "R", M.refresh, opts)
	vim.keymap.set("n", "C", M.close_sidebar, opts)
	vim.keymap.set("n", "q", M.close_sidebar, opts)
	vim.keymap.set("n", "<Esc>", M.close_sidebar, opts)
end

-- Show signs for a file (without opening sidebar)
M.show_signs = function(filepath, diff_base, diff_bufnr)
	-- Store context
	state.filepath = filepath
	state.diff_base = diff_base
	state.diff_bufnr = diff_bufnr

	-- Fetch GitHub comments (uses cache if available)
	local github_comments = M.fetch_github_comments(filepath)

	-- Sort and store comments
	state.comments = M.sort_comments(github_comments)
	state.current_idx = 1

	-- Place signs in diff buffer
	place_signs()

	-- Debug log
	if #state.comments > 0 then
		vim.notify(string.format("Found %d PR comment(s)", #state.comments), vim.log.levels.DEBUG)
	end
end

-- Main toggle function
M.toggle_sidebar = function(filepath, diff_base, diff_bufnr)
	-- If already open, close it
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		M.close_sidebar()
		return
	end

	-- If comments not loaded yet, load them
	if state.filepath ~= filepath or #state.comments == 0 then
		M.show_signs(filepath, diff_base, diff_bufnr)
	end

	-- Create buffer
	state.buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(state.buf, "buftype", "nofile")
	vim.api.nvim_buf_set_option(state.buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(state.buf, "swapfile", false)

	-- Calculate floating window dimensions
	local width = math.min(60, math.floor(vim.o.columns * 0.35))
	local height = vim.o.lines - 4 -- Leave space for status line and command line

	-- Position on right side of screen
	local col = vim.o.columns - width - 2 -- 2 char padding from right edge
	local row = 1 -- Start below top line

	-- Create floating window
	state.win = vim.api.nvim_open_win(state.buf, true, {
		relative = "editor",
		width = width,
		height = height,
		col = col,
		row = row,
		style = "minimal",
		border = "rounded",
		title = " PR Comments ",
		title_pos = "center",
	})

	-- Window options
	vim.api.nvim_win_set_option(state.win, "number", false)
	vim.api.nvim_win_set_option(state.win, "relativenumber", false)
	vim.api.nvim_win_set_option(state.win, "wrap", true)
	vim.api.nvim_win_set_option(state.win, "cursorline", true)
	vim.api.nvim_win_set_option(state.win, "winblend", 0) -- No transparency

	-- Setup keymaps
	setup_keymaps(state.buf)

	-- Render content
	M.render_sidebar()

	vim.notify(string.format("Loaded %d comment(s)", #state.comments), vim.log.levels.INFO)
end

return M
