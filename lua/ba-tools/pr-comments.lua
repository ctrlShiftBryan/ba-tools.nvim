local M = {}

-- Comment patterns for different file types
local comment_patterns = {
	lua = "^%+%s*(%-%-+)(.*)$",
	javascript = "^%+%s*(//)(.*)$",
	typescript = "^%+%s*(//)(.*)$",
	javascriptreact = "^%+%s*(//)(.*)$",
	typescriptreact = "^%+%s*(//)(.*)$",
	python = "^%+%s*(#+)(.*)$",
	ruby = "^%+%s*(#+)(.*)$",
	sh = "^%+%s*(#+)(.*)$",
	bash = "^%+%s*(#+)(.*)$",
	zsh = "^%+%s*(#+)(.*)$",
	vim = "^%+%s*(\")(.*)$",
	go = "^%+%s*(//)(.*)$",
	rust = "^%+%s*(//)(.*)$",
	c = "^%+%s*(//)(.*)$",
	cpp = "^%+%s*(//)(.*)$",
	java = "^%+%s*(//)(.*)$",
	css = "^%+%s*(//)(.*)$",
	scss = "^%+%s*(//)(.*)$",
	sass = "^%+%s*(//)(.*)$",
	html = "^%+%s*(<!--)(.*)$",
	xml = "^%+%s*(<!--)(.*)$",
	yaml = "^%+%s*(#+)(.*)$",
	json = "^%+%s*(//)(.*)$", -- Some JSON parsers allow comments
}

-- Detect file type from extension
local function get_filetype(filepath)
	local ext = filepath:match("%.([^%.]+)$")
	if not ext then
		return nil
	end

	-- Map extensions to filetypes
	local ext_map = {
		lua = "lua",
		js = "javascript",
		jsx = "javascriptreact",
		ts = "typescript",
		tsx = "typescriptreact",
		py = "python",
		rb = "ruby",
		sh = "bash",
		bash = "bash",
		zsh = "zsh",
		vim = "vim",
		go = "go",
		rs = "rust",
		c = "c",
		cpp = "cpp",
		cc = "cpp",
		h = "c",
		hpp = "cpp",
		java = "java",
		css = "css",
		scss = "scss",
		sass = "sass",
		html = "html",
		xml = "xml",
		yaml = "yaml",
		yml = "yaml",
		json = "json",
	}

	return ext_map[ext]
end

-- Parse git diff output to extract added comment lines
-- Returns array of comments with: { line, text, filepath }
M.parse_diff = function(diff_output, filepath)
	local filetype = get_filetype(filepath)
	if not filetype then
		return {}
	end

	local pattern = comment_patterns[filetype]
	if not pattern then
		return {}
	end

	local comments = {}
	local current_line = 0

	-- Parse diff output line by line
	for line in diff_output:gmatch("[^\n]+") do
		-- Track current line number from diff hunk headers
		-- Format: @@ -10,5 +11,8 @@
		local new_start = line:match("^@@%s+%-[%d,]+%s+%+(%d+)")
		if new_start then
			current_line = tonumber(new_start) - 1 -- -1 because we increment before checking
		else
			-- Check if this is an added line
			if line:match("^%+") and not line:match("^%+%+%+") then
				current_line = current_line + 1

				-- Check if it's a comment line
				local marker, text = line:match(pattern)
				if marker and text then
					-- Trim whitespace from comment text
					text = text:match("^%s*(.-)%s*$")

					-- Only include non-empty comments
					if text ~= "" then
						table.insert(comments, {
							line = current_line,
							text = text,
							filepath = filepath,
						})
					end
				end
			elseif not line:match("^%-") then
				-- Context line (not added or removed)
				current_line = current_line + 1
			end
		end
	end

	return comments
end

-- Group consecutive comment lines into multi-line blocks
-- Returns array of comment blocks with: { start_line, end_line, text, filepath }
M.group_comments = function(comments)
	if #comments == 0 then
		return {}
	end

	-- Sort by line number
	table.sort(comments, function(a, b)
		return a.line < b.line
	end)

	local blocks = {}
	local current_block = {
		start_line = comments[1].line,
		end_line = comments[1].line,
		lines = { comments[1].text },
		filepath = comments[1].filepath,
	}

	for i = 2, #comments do
		local comment = comments[i]

		-- Check if this comment is consecutive (next line)
		if comment.line == current_block.end_line + 1 then
			-- Add to current block
			current_block.end_line = comment.line
			table.insert(current_block.lines, comment.text)
		else
			-- Start new block
			-- First, save current block
			table.insert(blocks, {
				start_line = current_block.start_line,
				end_line = current_block.end_line,
				text = table.concat(current_block.lines, "\n"),
				filepath = current_block.filepath,
			})

			-- Create new block
			current_block = {
				start_line = comment.line,
				end_line = comment.line,
				lines = { comment.text },
				filepath = comment.filepath,
			}
		end
	end

	-- Don't forget the last block
	table.insert(blocks, {
		start_line = current_block.start_line,
		end_line = current_block.end_line,
		text = table.concat(current_block.lines, "\n"),
		filepath = current_block.filepath,
	})

	return blocks
end

-- Scan a single file for PR comments
-- base_ref: branch to diff against (e.g., "origin/main")
M.scan_file = function(filepath, base_ref)
	-- Get diff for this file against base branch
	local cmd = string.format(
		"git diff %s -- %s 2>&1",
		vim.fn.shellescape(base_ref),
		vim.fn.shellescape(filepath)
	)

	local diff_output = vim.fn.system(cmd)
	if vim.v.shell_error ~= 0 then
		return nil, "Failed to get diff: " .. diff_output
	end

	-- If no diff, return empty
	if diff_output == "" then
		return {}
	end

	-- Parse diff to extract comments
	local comments = M.parse_diff(diff_output, filepath)

	-- Group consecutive comments
	local blocks = M.group_comments(comments)

	return blocks
end

-- Scan all PR files for comments
-- pr_files: array of file paths from PR
-- base_ref: branch to diff against
M.scan_pr_files = function(pr_files, base_ref)
	local all_blocks = {}

	for _, file in ipairs(pr_files) do
		local blocks, err = M.scan_file(file, base_ref)
		if blocks then
			for _, block in ipairs(blocks) do
				table.insert(all_blocks, block)
			end
		end
	end

	return all_blocks
end

-- Get repository info (owner, name)
local function get_repo_info()
	local cmd = "gh repo view --json owner,name 2>&1"
	local output = vim.fn.system(cmd)

	if vim.v.shell_error ~= 0 then
		return nil, "Failed to get repository info: " .. output
	end

	local success, repo = pcall(vim.fn.json_decode, output)
	if not success or not repo then
		return nil, "Failed to parse repository info"
	end

	return {
		owner = repo.owner.login,
		name = repo.name,
	}
end

-- Get current PR number and head SHA
local function get_pr_info()
	local cmd = "gh pr view --json number,headRefOid 2>&1"
	local output = vim.fn.system(cmd)

	if vim.v.shell_error ~= 0 then
		return nil, "Failed to get PR info: " .. output
	end

	local success, pr = pcall(vim.fn.json_decode, output)
	if not success or not pr then
		return nil, "Failed to parse PR info"
	end

	return {
		number = pr.number,
		head_sha = pr.headRefOid,
	}
end

-- Post review comments to GitHub
-- comment_blocks: array of { start_line, text, filepath }
M.post_review = function(comment_blocks)
	if #comment_blocks == 0 then
		return true, "No comments to post"
	end

	-- Get repo and PR info
	local repo_info, err1 = get_repo_info()
	if not repo_info then
		return false, err1
	end

	local pr_info, err2 = get_pr_info()
	if not pr_info then
		return false, err2
	end

	-- Build JSON payload for the review
	local comments = {}
	for _, block in ipairs(comment_blocks) do
		table.insert(comments, {
			path = block.filepath,
			line = block.start_line,
			body = block.text,
		})
	end

	local payload = {
		commit_id = pr_info.head_sha,
		event = "COMMENT",
		comments = comments,
	}

	-- Encode as JSON
	local json_payload = vim.fn.json_encode(payload)

	-- Post review via gh api
	local cmd = string.format(
		"gh api --method POST repos/%s/%s/pulls/%d/reviews --input - 2>&1",
		repo_info.owner,
		repo_info.name,
		pr_info.number
	)

	-- Use vim.fn.system with input
	local output = vim.fn.system(cmd, json_payload)

	if vim.v.shell_error ~= 0 then
		return false, "Failed to post review: " .. output
	end

	return true, string.format("Posted %d comment(s) to PR #%d", #comment_blocks, pr_info.number)
end

-- Revert files to remove the added comments
M.cleanup_files = function(comment_blocks)
	-- Get unique file paths
	local files = {}
	local seen = {}

	for _, block in ipairs(comment_blocks) do
		if not seen[block.filepath] then
			table.insert(files, block.filepath)
			seen[block.filepath] = true
		end
	end

	-- Revert each file
	for _, filepath in ipairs(files) do
		local cmd = string.format("git restore %s 2>&1", vim.fn.shellescape(filepath))
		local output = vim.fn.system(cmd)

		if vim.v.shell_error ~= 0 then
			return false, "Failed to revert " .. filepath .. ": " .. output
		end
	end

	return true, string.format("Reverted %d file(s)", #files)
end

-- Main function: scan, post, and cleanup
-- mode: "file" for single file, "batch" for all PR files
-- filepath: only used in "file" mode
M.process_comments = function(mode, filepath)
	-- Get base branch from PR
	local pr_cmd = "gh pr view --json baseRefName 2>&1"
	local pr_output = vim.fn.system(pr_cmd)

	if vim.v.shell_error ~= 0 then
		return false, "Failed to get PR base branch: " .. pr_output
	end

	local success, pr_data = pcall(vim.fn.json_decode, pr_output)
	if not success or not pr_data then
		return false, "Failed to parse PR data"
	end

	local base_ref = "origin/" .. pr_data.baseRefName

	-- Scan for comments
	local comment_blocks
	if mode == "file" then
		if not filepath then
			return false, "Filepath required for file mode"
		end
		comment_blocks = M.scan_file(filepath, base_ref)
	elseif mode == "batch" then
		-- Get PR files
		local git = require("ba-tools.git")
		local pr_files, err = git.get_pr_files()
		if not pr_files then
			return false, err
		end

		-- Extract file paths
		local filepaths = {}
		for _, file_info in ipairs(pr_files) do
			table.insert(filepaths, file_info.file)
		end

		comment_blocks = M.scan_pr_files(filepaths, base_ref)
	else
		return false, "Invalid mode: " .. mode
	end

	if not comment_blocks then
		return false, "Failed to scan for comments"
	end

	if #comment_blocks == 0 then
		return true, "No comments found"
	end

	-- Post comments to GitHub
	local post_success, post_msg = M.post_review(comment_blocks)
	if not post_success then
		return false, post_msg
	end

	-- Clean up local files
	local cleanup_success, cleanup_msg = M.cleanup_files(comment_blocks)
	if not cleanup_success then
		return false, cleanup_msg
	end

	return true, post_msg .. "\n" .. cleanup_msg
end

return M
