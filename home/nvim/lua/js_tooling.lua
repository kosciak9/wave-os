local M = {}

M.deno_files = { "deno.json", "deno.jsonc", "deno.lock" }
M.package_root_files = {
	"package-lock.json",
	"yarn.lock",
	"pnpm-lock.yaml",
	"bun.lock",
	"bun.lockb",
	"package.json",
}
M.biome_files = { "biome.json", "biome.jsonc" }
M.eslint_files = {
	"eslint.config.js",
	"eslint.config.mjs",
	"eslint.config.cjs",
	"eslint.config.ts",
	"eslint.config.mts",
	"eslint.config.cts",
	".eslintrc",
	".eslintrc.js",
	".eslintrc.cjs",
	".eslintrc.json",
	".eslintrc.yaml",
	".eslintrc.yml",
}
M.oxlint_files = {
	".oxlintrc.json",
	".oxlintrc.jsonc",
	"oxlint.config.ts",
}
M.oxfmt_files = {
	".oxfmtrc.json",
	".oxfmtrc.jsonc",
	"oxfmt.config.ts",
}
M.prettier_files = {
	".prettierrc",
	".prettierrc.json",
	".prettierrc.yml",
	".prettierrc.yaml",
	".prettierrc.json5",
	".prettierrc.js",
	".prettierrc.cjs",
	".prettierrc.mjs",
	".prettierrc.toml",
	"prettier.config.js",
	"prettier.config.cjs",
	"prettier.config.mjs",
	"prettier.config.ts",
}

local function buf_path(bufnr)
	return vim.api.nvim_buf_get_name(bufnr)
end

local function path_for(bufnr)
	local name = buf_path(bufnr)
	if name == "" then
		return vim.uv.cwd()
	end
	return name
end

local function readfile_ok(file)
	local ok, lines = pcall(vim.fn.readfile, file)
	if not ok then
		return {}
	end
	return lines
end

function M.find_upward(bufnr, names, stop)
	return vim.fs.find(names, {
		path = path_for(bufnr),
		upward = true,
		type = "file",
		limit = 1,
		stop = stop,
	})[1]
end

local function parent(path)
	if not path then
		return nil
	end
	return vim.fs.dirname(path)
end

function M.package_json_has(bufnr, field, stop)
	local package_json = M.find_upward(bufnr, { "package.json" }, stop)
	if not package_json then
		return nil
	end

	local quoted = '"' .. field .. '"'
	for _, line in ipairs(readfile_ok(package_json)) do
		if line:find(quoted, 1, true) or line:find(field, 1, true) then
			return package_json
		end
	end

	return nil
end

function M.node_root(bufnr)
	return vim.fs.root(bufnr, M.package_root_files)
end

function M.git_root(bufnr)
	return vim.fs.root(bufnr, { ".git" })
end

function M.project_root(bufnr)
	return M.node_root(bufnr) or M.git_root(bufnr) or vim.uv.cwd()
end

function M.has_deno(bufnr)
	local deno_root = vim.fs.root(bufnr, M.deno_files)
	if not deno_root then
		return false
	end

	local node_root = M.node_root(bufnr)
	return not node_root or #deno_root >= #node_root
end

function M.has_biome(bufnr)
	return M.find_upward(bufnr, M.biome_files) ~= nil
end

function M.has_oxc(bufnr)
	return M.find_upward(bufnr, M.oxlint_files) ~= nil or M.find_upward(bufnr, M.oxfmt_files) ~= nil
end

function M.has_oxlint(bufnr)
	return M.find_upward(bufnr, M.oxlint_files) ~= nil
end

function M.has_oxfmt(bufnr)
	return M.find_upward(bufnr, M.oxfmt_files) ~= nil
end

function M.has_eslint(bufnr)
	if M.has_deno(bufnr) then
		return false
	end

	local root = M.project_root(bufnr)
	local stop = parent(root)
	return M.find_upward(bufnr, M.eslint_files, stop) ~= nil or M.package_json_has(bufnr, "eslintConfig", stop) ~= nil
end

function M.oxlint_root(bufnr)
	return parent(M.find_upward(bufnr, M.oxlint_files))
end

function M.oxfmt_root(bufnr)
	return parent(M.find_upward(bufnr, M.oxfmt_files))
end

function M.has_prettier(bufnr)
	return M.find_upward(bufnr, M.prettier_files) ~= nil or M.package_json_has(bufnr, "prettier") ~= nil
end

function M.root_if(bufnr, predicate)
	if not predicate(bufnr) then
		return nil
	end
	return M.project_root(bufnr)
end

return M
