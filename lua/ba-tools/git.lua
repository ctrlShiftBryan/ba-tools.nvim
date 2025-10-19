local M = {}

-- Get git status and parse into staged and unstaged changes
M.get_status = function()
	-- Check if we're in a git repository
	local git_dir = vim.fn.system("git rev-parse --git-dir 2>/dev/null")
	if vim.v.shell_error ~= 0 then
		return nil, "Not in a git repository"
	end

	-- Run git status with porcelain format for reliable parsing
	local output = vim.fn.system("git status --porcelain=v1 2>/dev/null")
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
				local status_display = "U" -- Default to unstaged
				if status_code == "??" then
					status_display = "U" -- Untracked
				elseif unstaged_char == "M" then
					status_display = "U"
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

return M
