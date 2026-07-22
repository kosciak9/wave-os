local M = {}

local uv = vim.uv or vim.loop

M.limit = 20
M.path = vim.fn.stdpath("state") .. "/recent-dirs.json"

local function normalize(dir)
	if type(dir) ~= "string" or dir == "" then
		return nil
	end

	local path = vim.fn.fnamemodify(dir, ":p")
	if path == "" then
		return nil
	end

	if vim.fs and vim.fs.normalize then
		path = vim.fs.normalize(path)
	end

	path = path:gsub("/+$", "")
	if path == "" then
		path = "/"
	end

	return path
end

local function is_dir(dir)
	local stat = uv.fs_stat(dir)
	return stat ~= nil and stat.type == "directory"
end

local function clean_dirs(dirs)
	local clean = {}
	local seen = {}

	for _, dir in ipairs(dirs or {}) do
		local normalized = normalize(dir)
		if normalized ~= nil and not seen[normalized] and is_dir(normalized) then
			seen[normalized] = true
			table.insert(clean, normalized)

			if #clean >= M.limit then
				break
			end
		end
	end

	return clean
end

local function same_dirs(left, right)
	if #left ~= #right then
		return false
	end

	for index, dir in ipairs(left) do
		if dir ~= right[index] then
			return false
		end
	end

	return true
end

function M.load()
	local ok, lines = pcall(vim.fn.readfile, M.path)
	if not ok then
		return {}
	end

	local content = table.concat(lines, "\n")
	if content == "" then
		return {}
	end

	local ok_decode, decoded = pcall(vim.json.decode, content)
	if not ok_decode or type(decoded) ~= "table" then
		return {}
	end

	return decoded
end

function M.save(dirs)
	vim.fn.mkdir(vim.fn.fnamemodify(M.path, ":h"), "p")
	return pcall(vim.fn.writefile, { vim.json.encode(dirs or {}) }, M.path)
end

function M.list()
	local loaded = M.load()
	local dirs = clean_dirs(loaded)

	if not same_dirs(dirs, loaded) then
		M.save(dirs)
	end

	return dirs
end

function M.add(dir)
	local normalized = normalize(dir)
	if normalized == nil or not is_dir(normalized) then
		return false
	end

	local dirs = clean_dirs(M.load())
	local next_dirs = { normalized }

	for _, existing in ipairs(dirs) do
		if existing ~= normalized then
			table.insert(next_dirs, existing)
		end

		if #next_dirs >= M.limit then
			break
		end
	end

	M.save(next_dirs)
	return true
end

function M.display_name(dir)
	return vim.fn.fnamemodify(normalize(dir) or dir, ":~")
end

function M.setup(opts)
	opts = opts or {}
	M.limit = opts.limit or M.limit

	local group = vim.api.nvim_create_augroup("RecentDirs", { clear = true })

	vim.api.nvim_create_autocmd("VimEnter", {
		group = group,
		callback = function()
			M.add(vim.fn.getcwd())
		end,
	})

	vim.api.nvim_create_autocmd("DirChanged", {
		group = group,
		pattern = "global",
		callback = function(event)
			M.add(event.file ~= "" and event.file or vim.fn.getcwd())
		end,
	})
end

return M
