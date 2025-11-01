local M = {}

-- Get git status and parse into staged and unstaged changes
M.get_status = function()
	-- Check if we're in a git repository
	local git_dir = vim.fn.system("git rev-parse --git-dir 2>/dev/null")
	if vim.v.shell_error ~= 0 then
		return nil, "Not in a git repository"
	end

	-- Run git status with porcelain format for reliable parsing
	-- -u flag: show untracked files individually (not grouped by directory)
	local output = vim.fn.system("git status --porcelain=v1 -u 2>/dev/null")
	if vim.v.shell_error ~= 0 then
		return nil, "Failed to get git status"
	end

	local conflicts = {}
	local staged = {}
	local unstaged = {}

	-- Parse each line
	-- Format: XY filename
	-- X = staged status, Y = unstaged status
	-- ' ' = not changed, M = modified, A = added, D = deleted, R = renamed, C = copied
	-- ?? = untracked
	-- Conflict codes: UU, AA, DD, AU, UA, DU, UD
	for line in output:gmatch("[^\n]+") do
		if line ~= "" then
			local status_code = line:sub(1, 2)
			local filepath = line:sub(4) -- Skip status and space

			local staged_char = status_code:sub(1, 1)
			local unstaged_char = status_code:sub(2, 2)

			-- Check for merge conflicts first
			local is_conflict = false
			if status_code == "UU" or status_code == "AA" or status_code == "DD" or
			   status_code == "AU" or status_code == "UA" or status_code == "DU" or status_code == "UD" then
				is_conflict = true
				table.insert(conflicts, {
					file = filepath,
					status = "C", -- C for Conflict
					conflict_type = status_code,
				})
			end

			-- Only process as staged/unstaged if not a conflict
			if not is_conflict then
				-- Handle staged changes
				if staged_char ~= " " and staged_char ~= "?" then
					local status_display = "M" -- Default to modified
					if staged_char == "A" then
						status_display = "A"
					elseif staged_char == "D" then
						status_display = "D"
					elseif staged_char == "R" then
						status_display = "R"
					elseif staged_char == "C" then
						status_display = "C"
					end

					table.insert(staged, {
						file = filepath,
						status = status_display,
					})
				end

				-- Handle unstaged changes
				if unstaged_char ~= " " or status_code == "??" then
					local status_display = "M" -- Default to modified
					if status_code == "??" then
						status_display = "U" -- Untracked
					elseif unstaged_char == "M" then
						status_display = "M" -- Modified
					elseif unstaged_char == "D" then
						status_display = "D"
					end

					table.insert(unstaged, {
						file = filepath,
						status = status_display,
					})
				end
			end
		end
	end

	return {
		conflicts = conflicts,
		staged = staged,
		unstaged = unstaged,
	}
end

-- Stage a file
M.stage_file = function(filepath)
	local cmd = string.format("git add %s 2>&1", vim.fn.shellescape(filepath))
	local output = vim.fn.system(cmd)
	if vim.v.shell_error ~= 0 then
		return false, "Failed to stage file: " .. output
	end
	return true
end

-- Unstage a file
M.unstage_file = function(filepath)
	local cmd = string.format("git restore --staged %s 2>&1", vim.fn.shellescape(filepath))
	local output = vim.fn.system(cmd)
	if vim.v.shell_error ~= 0 then
		return false, "Failed to unstage file: " .. output
	end
	return true
end

-- Stage multiple files at once (batch operation)
M.stage_files = function(filepaths)
	if #filepaths == 0 then
		return true
	end

	-- Build array of shell-escaped paths
	local escaped = {}
	for _, path in ipairs(filepaths) do
		table.insert(escaped, vim.fn.shellescape(path))
	end

	-- Single git command for all files
	local cmd = "git add " .. table.concat(escaped, " ") .. " 2>&1"
	local output = vim.fn.system(cmd)

	if vim.v.shell_error ~= 0 then
		return false, "Failed to stage files: " .. output
	end
	return true
end

-- Unstage multiple files at once (batch operation)
M.unstage_files = function(filepaths)
	if #filepaths == 0 then
		return true
	end

	-- Build array of shell-escaped paths
	local escaped = {}
	for _, path in ipairs(filepaths) do
		table.insert(escaped, vim.fn.shellescape(path))
	end

	-- Single git command for all files
	local cmd = "git restore --staged " .. table.concat(escaped, " ") .. " 2>&1"
	local output = vim.fn.system(cmd)

	if vim.v.shell_error ~= 0 then
		return false, "Failed to unstage files: " .. output
	end
	return true
end

-- Discard changes to a file
M.discard_file = function(filepath, is_untracked)
	local cmd
	if is_untracked then
		-- For untracked files, just remove them
		cmd = string.format("rm -rf %s 2>&1", vim.fn.shellescape(filepath))
	else
		-- For tracked files, restore from HEAD
		cmd = string.format("git restore %s 2>&1", vim.fn.shellescape(filepath))
	end

	local output = vim.fn.system(cmd)
	if vim.v.shell_error ~= 0 then
		return false, "Failed to discard changes: " .. output
	end
	return true
end

-- Restore unstaged changes to a file (from staged version or HEAD)
-- Uses git restore which automatically:
-- - If file is staged: restores from index (staged version)
-- - If file is not staged: restores from HEAD
M.restore_file = function(filepath)
	-- Check if file is tracked by git
	local check_cmd = string.format("git ls-files %s", vim.fn.shellescape(filepath))
	local tracked_output = vim.fn.system(check_cmd)
	local is_tracked = vim.v.shell_error == 0 and tracked_output ~= ""

	local cmd
	if not is_tracked then
		-- File is untracked (new file) - use git clean to remove it
		cmd = string.format("git clean -f %s 2>&1", vim.fn.shellescape(filepath))
	else
		-- File is tracked - restore from git
		cmd = string.format("git restore %s 2>&1", vim.fn.shellescape(filepath))
	end

	local output = vim.fn.system(cmd)
	if vim.v.shell_error ~= 0 then
		return false, "Failed to restore file: " .. output
	end
	return true
end

-- Revert a file to its state in a specific branch (for PR mode)
-- Handles: new files (delete), modified files (restore), deleted files (restore)
M.revert_to_base = function(filepath, base_ref)
	-- Check if file exists in base branch
	local check_cmd = string.format(
		"git cat-file -e %s:%s 2>/dev/null",
		vim.fn.shellescape(base_ref),
		vim.fn.shellescape(filepath)
	)
	vim.fn.system(check_cmd)
	local exists = vim.v.shell_error == 0

	local cmd
	if not exists then
		-- File doesn't exist in base branch (new file) - delete it
		-- First unstage if staged
		local unstage_cmd = string.format("git restore --staged %s 2>/dev/null", vim.fn.shellescape(filepath))
		vim.fn.system(unstage_cmd)

		-- Then delete the file
		cmd = string.format("rm -rf %s 2>&1", vim.fn.shellescape(filepath))
	else
		-- File exists in base branch - restore from it
		-- This handles both modified and deleted files
		-- First unstage if staged
		local unstage_cmd = string.format("git restore --staged %s 2>/dev/null", vim.fn.shellescape(filepath))
		vim.fn.system(unstage_cmd)

		-- Then restore from base branch
		cmd = string.format(
			"git restore --source=%s -- %s 2>&1",
			vim.fn.shellescape(base_ref),
			vim.fn.shellescape(filepath)
		)
	end

	local output = vim.fn.system(cmd)
	if vim.v.shell_error ~= 0 then
		return false, "Failed to revert file: " .. output
	end
	return true
end

-- Get current PR information for the current branch
M.get_current_pr = function()
	-- Check if gh CLI is available
	local gh_check = vim.fn.system("which gh 2>/dev/null")
	if vim.v.shell_error ~= 0 then
		return nil, "gh CLI not found. Please install GitHub CLI."
	end

	-- Get PR for current branch including base branch info
	local cmd = "gh pr view --json number,title,state,files,baseRefName,headRefName 2>&1"
	local output = vim.fn.system(cmd)

	if vim.v.shell_error ~= 0 then
		-- No PR found for current branch
		return nil, "No pull request found for current branch"
	end

	-- Parse JSON output
	local success, pr_data = pcall(vim.fn.json_decode, output)
	if not success or not pr_data then
		return nil, "Failed to parse PR data"
	end

	return pr_data
end

-- Get files changed in a PR with their review status using GraphQL
M.get_pr_files = function()
	-- Check if gh CLI is available
	local gh_check = vim.fn.system("which gh 2>/dev/null")
	if vim.v.shell_error ~= 0 then
		return nil, "gh CLI not found. Please install GitHub CLI."
	end

	-- GraphQL query to get PR with node ID and file viewed states
	local query = [[
		query {
			repository(owner: "{owner}", name: "{repo}") {
				pullRequest(number: {number}) {
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
	]]

	-- Get current PR number and repo info
	local pr_data, err = M.get_current_pr()
	if not pr_data then
		return nil, err
	end

	-- Get repo owner and name
	local repo_info = vim.fn.system("gh repo view --json owner,name 2>&1")
	if vim.v.shell_error ~= 0 then
		return nil, "Failed to get repository info"
	end

	local success, repo = pcall(vim.fn.json_decode, repo_info)
	if not success or not repo then
		return nil, "Failed to parse repository info"
	end

	-- Replace placeholders in query
	query = query:gsub("{owner}", repo.owner.login)
	query = query:gsub("{repo}", repo.name)
	query = query:gsub("{number}", pr_data.number)

	-- Execute GraphQL query
	local cmd = string.format("gh api graphql -f query=%s 2>&1", vim.fn.shellescape(query))
	local output = vim.fn.system(cmd)

	if vim.v.shell_error ~= 0 then
		-- Fallback to simple file list without viewed status if GraphQL fails
		local files = pr_data.files or {}
		local result = {}
		for _, file in ipairs(files) do
			table.insert(result, {
				file = file.path,
				additions = file.additions or 0,
				deletions = file.deletions or 0,
				reviewed = false,
				pr_id = nil, -- No PR ID available in fallback
			})
		end
		return result
	end

	-- Parse GraphQL response
	local success2, graphql_result = pcall(vim.fn.json_decode, output)
	if not success2 or not graphql_result then
		return nil, "Failed to parse GraphQL response"
	end

	-- Extract PR ID and files
	local pr = graphql_result.data.repository.pullRequest
	local pr_id = pr.id
	local files = pr.files.nodes or {}

	-- Build result with viewed status
	local result = {}
	for _, file in ipairs(files) do
		table.insert(result, {
			file = file.path,
			additions = file.additions or 0,
			deletions = file.deletions or 0,
			-- viewerViewedState can be: VIEWED, UNVIEWED, or DISMISSED
			reviewed = file.viewerViewedState == "VIEWED",
			pr_id = pr_id,
		})
	end

	return result
end

-- Mark a file as viewed in a PR
M.mark_file_as_viewed = function(pr_id, filepath)
	if not pr_id then
		return false, "PR ID is required"
	end

	-- GraphQL mutation to mark file as viewed
	local mutation = [[
		mutation {
			markFileAsViewed(input: {pullRequestId: "%s", path: "%s"}) {
				pullRequest {
					id
				}
			}
		}
	]]

	mutation = string.format(mutation, pr_id, filepath)

	local cmd = string.format("gh api graphql -f query=%s 2>&1", vim.fn.shellescape(mutation))
	local output = vim.fn.system(cmd)

	if vim.v.shell_error ~= 0 then
		return false, "Failed to mark file as viewed: " .. output
	end

	return true
end

-- Unmark a file as viewed in a PR
M.unmark_file_as_viewed = function(pr_id, filepath)
	if not pr_id then
		return false, "PR ID is required"
	end

	-- GraphQL mutation to unmark file as viewed
	local mutation = [[
		mutation {
			unmarkFileAsViewed(input: {pullRequestId: "%s", path: "%s"}) {
				pullRequest {
					id
				}
			}
		}
	]]

	mutation = string.format(mutation, pr_id, filepath)

	local cmd = string.format("gh api graphql -f query=%s 2>&1", vim.fn.shellescape(mutation))
	local output = vim.fn.system(cmd)

	if vim.v.shell_error ~= 0 then
		return false, "Failed to unmark file as viewed: " .. output
	end

	return true
end

-- Toggle file viewed status in a PR
M.toggle_file_viewed = function(pr_id, filepath, is_reviewed)
	if is_reviewed then
		return M.unmark_file_as_viewed(pr_id, filepath)
	else
		return M.mark_file_as_viewed(pr_id, filepath)
	end
end

return M
