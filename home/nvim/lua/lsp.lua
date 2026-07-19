vim.lsp.config("*", {
	root_markers = { ".git" },
	capabilities = {
		textDocument = {
			semanticTokens = { multilineTokenSupport = true },
		},
	},
})

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

for _, name in ipairs({ "lua_ls", "harper_ls", "eslint", "yamlls", "jsonls", "expert" }) do
	local path = ("%s/lsp/%s.lua"):format(vim.fn.stdpath("config"), name)
	vim.lsp.config(name, dofile(path))
end

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
