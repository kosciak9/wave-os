local js = require("js_tooling")

return {
	cmd = { "vscode-eslint-language-server", "--stdio" },
	filetypes = { "javascript", "javascriptreact", "typescript", "typescriptreact" },
	root_dir = function(bufnr, on_dir)
		if not js.has_eslint(bufnr) then
			return
		end

		on_dir(js.project_root(bufnr))
	end,
	settings = {
		validate = "on",
	},
}
