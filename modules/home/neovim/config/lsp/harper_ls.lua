return {
	cmd = { "harper-ls", "--stdio" },
	filetypes = { "markdown", "text" },
	settings = {
		["harper-ls"] = {
			linters = {
				SentenceCapitalization = false,
			},
		},
	},
}
