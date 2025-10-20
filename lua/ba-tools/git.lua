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

	local staged = {}
	local unstaged = {}

	-- Parse each line
	-- Format: XY filename
	-- X = staged status, Y = unstaged status
	-- ' ' = not changed, M = modified, A = added, D = deleted, R = renamed, C = copied
	-- ?? = untracked
	for line in output:gmatch("[^\n]+") do
		if line ~= "" then
			local status_code = line:sub(1, 2)
			local filepath = line:sub(4) -- Skip status and space

			local staged_char = status_code:sub(1, 1)
			local unstaged_char = status_code:sub(2, 2)

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

	return {
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
	local cmd = string.format("git restore %s 2>&1", vim.fn.shellescape(filepath))
	local output = vim.fn.system(cmd)
	if vim.v.shell_error ~= 0 then
		return false, "Failed to restore file: " .. output
	end
	return true
end

return M
