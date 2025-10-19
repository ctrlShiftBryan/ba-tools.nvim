local M = {}

-- Configuration state
M.config = {}

-- Setup function called by lazy.nvim
M.setup = function(opts)
	opts = opts or {}
	M.config = vim.tbl_deep_extend("force", M.config, opts)

	-- Any initialization code goes here
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

return M
