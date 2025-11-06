local M = {}

-- Configuration state
M.config = {}

-- Setup function called by lazy.nvim
M.setup = function(opts)
	opts = opts or {}
	M.config = vim.tbl_deep_extend("force", M.config, opts)

	-- Register user commands
	vim.api.nvim_create_user_command("PrCommentsFile", function()
		M.post_pr_comment_file()
	end, { desc = "Post PR comments from current file" })

	vim.api.nvim_create_user_command("PrCommentsBatch", function()
		M.post_pr_comment_batch()
	end, { desc = "Post PR comments from all PR files" })

	vim.api.nvim_create_user_command("PrCommentsSidebar", function()
		M.toggle_pr_comment_sidebar()
	end, { desc = "Toggle PR comments sidebar for current file" })
end

-- Example function: Print a hello message
M.hello = function()
	print("Hello from ba-tools.nvim!")
end

-- Example function: Get current file info
M.file_info = function()
	local bufnr = vim.api.nvim_get_current_buf()
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local filetype = vim.bo[bufnr].filetype

	print(string.format("File: %s\nType: %s", filepath, filetype))
end

-- Show git status menu
M.git_menu = function()
	local git_menu = require("ba-tools.git-menu")
	git_menu.show()
end

-- Post PR comments from current file
M.post_pr_comment_file = function()
	local bufnr = vim.api.nvim_get_current_buf()
	local filepath = vim.api.nvim_buf_get_name(bufnr)

	-- Convert to relative path
	local cwd = vim.fn.getcwd()
	filepath = vim.fn.fnamemodify(filepath, ":.")

	-- Check if we have a valid file
	if filepath == "" then
		vim.notify("No file in current buffer", vim.log.levels.ERROR)
		return
	end

	-- Show processing message
	vim.notify("Scanning " .. filepath .. " for comments...", vim.log.levels.INFO)

	-- Process comments for this file
	local pr_comments = require("ba-tools.pr-comments")
	local success, msg = pr_comments.process_comments("file", filepath)

	if success then
		vim.notify(msg, vim.log.levels.INFO)
	else
		vim.notify("Failed to post comments: " .. msg, vim.log.levels.ERROR)
	end
end

-- Post PR comments from all PR files (batch mode)
M.post_pr_comment_batch = function()
	-- Show processing message
	vim.notify("Scanning PR files for comments...", vim.log.levels.INFO)

	-- Process comments in batch mode
	local pr_comments = require("ba-tools.pr-comments")
	local success, msg = pr_comments.process_comments("batch")

	if success then
		vim.notify(msg, vim.log.levels.INFO)
	else
		vim.notify("Failed to post comments: " .. msg, vim.log.levels.ERROR)
	end
end

-- Toggle PR comment sidebar for current file
M.toggle_pr_comment_sidebar = function()
	local bufnr = vim.api.nvim_get_current_buf()
	local filepath = vim.api.nvim_buf_get_name(bufnr)

	-- Convert to relative path
	filepath = vim.fn.fnamemodify(filepath, ":.")

	-- Check if we have a valid file
	if filepath == "" then
		vim.notify("No file in current buffer", vim.log.levels.ERROR)
		return
	end

	-- Get PR base branch (default to origin/main)
	local diff_base = "origin/main"
	local git = require("ba-tools.git")
	local pr_data, err = git.get_current_pr()
	if pr_data and pr_data.baseRefName then
		diff_base = "origin/" .. pr_data.baseRefName
	end

	-- Toggle sidebar
	local sidebar = require("ba-tools.pr-comment-sidebar")
	sidebar.toggle_sidebar(filepath, diff_base, bufnr)
end

return M
