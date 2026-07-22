return {
	cmd = { "dexter", "lsp" },
	root_markers = { ".dexter/dexter.db", ".dexter.db", ".git", "mix.exs" },
	filetypes = { "elixir", "eelixir", "heex" },
	init_options = {
		followDelegates = true,
	},
}
