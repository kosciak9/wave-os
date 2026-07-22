-- global LSP defaults
vim.lsp.config("*", {
	root_markers = { ".git" },
	capabilities = {
		textDocument = {
			semanticTokens = { multilineTokenSupport = true },
		},
	},
})

-- when LSP gets enabled - run these
-- 1. add keybinds for code action, hover, go to definition, jump between
--    diagnostics
-- 2. enable completions
vim.api.nvim_create_autocmd("LspAttach", {
	group = vim.api.nvim_create_augroup("lsp_config", {}),
	callback = function(ev)
		local client = vim.lsp.get_client_by_id(ev.data.client_id)
		local buf = ev.buf
		local opts = { buffer = buf }

		vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, opts)
		vim.keymap.set("n", "<leader>h", vim.lsp.buf.hover, opts)
		vim.keymap.set("n", "<leader>gd", vim.lsp.buf.definition, opts)
		vim.keymap.set("n", "<leader>gr", vim.lsp.buf.references, opts)
		vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename, opts)
		vim.keymap.set("n", "<leader>d[", function()
			vim.diagnostic.jump({ count = -1 })
		end, opts)
		vim.keymap.set("n", "<leader>d]", function()
			vim.diagnostic.jump({ count = 1 })
		end, opts)

		if client and client:supports_method("textDocument/completion") then
			vim.lsp.completion.enable(true, client.id, buf, {
				autotrigger = true,
				convert = function(item)
					return { abbr = item.label:gsub("%b()", "") }
				end,
			})
		end
	end,
})

-- enable all LSP servers (Neovim 0.12 autoloads from lsp/ folder)
vim.lsp.enable({
	"lua_ls",
	"harper_ls",
	"tsgo",
	"denols",
	"biome",
	"oxlint",
	"eslint",
	"yamlls",
	"jsonls",
	"tailwindcss",
	"expert",
	-- "dexter",
})
