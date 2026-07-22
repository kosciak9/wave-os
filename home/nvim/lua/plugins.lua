-- vim-matchup reads this during plugin load.
vim.g.matchup_matchparen_offscreen = { method = "popup" }

-- Plugin acquisition, updates, and native builds are owned by Home Manager/Nix.

require("kanagawa").setup({
	compile = true,
	dimInactive = true,
	theme = "wave",
})

vim.o.termguicolors = true
vim.cmd("colorscheme kanagawa")

require("hardtime").setup({
	disabled_filetypes = { "qf", "netrw", "lazy", "oil" },
})

require("gitsigns").setup()

vim.keymap.set("n", "<leader>gb", require("gitsigns").blame_line, {
	desc = "Git line blame",
})

require("diffview").setup({
	use_icons = false,
})

require("neogit").setup({
	process_spinner = true,
	graph_style = "kitty",
	integrations = {
		diffview = true,
	},
})

vim.keymap.set("n", "<leader>gs", require("neogit").open, {
	desc = "Git status",
})

require("ts_context_commentstring").setup({
	enable_autocmd = false,
})

local get_filetype_option = vim.filetype.get_option
---@diagnostic disable-next-line: duplicate-set-field
vim.filetype.get_option = function(filetype, option)
	if option == "commentstring" then
		return require("ts_context_commentstring.internal").calculate_commentstring()
			or get_filetype_option(filetype, option)
	end

	return get_filetype_option(filetype, option)
end

require("nvim-surround").setup()

-- Default nvim-surround keymaps:
--   insert: <C-g>s{char} surrounds the cursor, e.g. <C-g>s" -> "|"
--   insert: <C-g>S{char} surrounds the cursor on new lines
--   normal: ys{motion}{char} surrounds a motion/text object, e.g. ysiw"
--   normal: yss{char} surrounds the current line
--   normal: yS{motion}{char} / ySS{char} surround on new lines
--   normal: ds{char} deletes a surrounding pair, e.g. ds"
--   normal: cs{target}{replacement} changes a pair, e.g. cs'"
--   normal: cS{target}{replacement} changes a pair onto new lines
--   visual: S{char} surrounds the selection
--   visual: gS{char} surrounds the selection on new lines

-- mini.family - icons and dashboard (start)
require("mini.icons").setup()
MiniIcons.mock_nvim_web_devicons()
require("picker").setup()
require("dashboard").setup()

local js_tooling = require("js_tooling")

local function js_formatters(bufnr)
	if js_tooling.has_deno(bufnr) then
		return { "deno_fmt" }
	end

	if js_tooling.has_biome(bufnr) then
		return { "biome" }
	end

	if js_tooling.has_oxfmt(bufnr) then
		return { "oxfmt" }
	end

	return { "prettierd", "prettier", stop_after_first = true }
end

require("conform").setup({
	formatters_by_ft = {
		lua = { "stylua" },
		python = { "ruff_format", "isort", "black", stop_after_first = true },
		javascript = js_formatters,
		javascriptreact = js_formatters,
		typescript = js_formatters,
		typescriptreact = js_formatters,
		graphql = { "prettierd", "prettier", stop_after_first = true },
		jsonc = js_formatters,
		json = js_formatters,
		markdown = { "markdownlint", "prettierd", "prettier", stop_after_first = true },
	},

	default_format_opts = {
		lsp_format = "fallback",
	},

	---@diagnostic disable-next-line: unused-local
	format_on_save = function(_bufnr)
		return { timeout_ms = 500, lsp_fallback = true }
	end,
})

vim.o.formatexpr = "v:lua.require'conform'.formatexpr()"

require("tiny-inline-diagnostic").setup({
	preset = "simple",
})

require("copilot").setup({
	suggestion = {
		auto_trigger = true,
	},
})

vim.keymap.set(
	"i",
	"<C-j>",
	require("copilot.suggestion").accept_line,
	{ desc = "Accept a line of Copilot suggestion" }
)

vim.keymap.set(
	"i",
	"<C-M-j>",
	require("copilot.suggestion").accept_word,
	{ desc = "Accept a word of Copilot suggestion" }
)

-- Tree-sitter parsers are provisioned by Home Manager/Nix.
vim.treesitter.language.register("tsx", { "javascriptreact", "typescriptreact" })

vim.api.nvim_create_autocmd("FileType", {
	pattern = {
		"markdown",
		"javascript",
		"javascriptreact",
		"typescript",
		"typescriptreact",
		"json",
		"jsonc",
		"graphql",
		"python",
		"yaml",
		"html",
		"scss",
		"lua",
		"elixir",
		"heex",
	},
	callback = function()
		vim.treesitter.start()
		vim.bo.indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
	end,
})

require("oil").setup({
	default_file_explorer = true,
	delete_to_trash = true,
	view_options = {
		show_hidden = true,
	},
})
