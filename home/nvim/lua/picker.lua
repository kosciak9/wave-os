local M = {}

function M.setup()
	local telescope = require("telescope")
	local builtin = require("telescope.builtin")

	telescope.setup({
		extensions = {
			fzf = {
				fuzzy = true,
				override_file_sorter = true,
				override_generic_sorter = true,
				case_mode = "smart_case",
			},
		},
	})

	pcall(telescope.load_extension, "fzf")

	vim.keymap.set("n", "<leader>ff", builtin.find_files, { desc = "Find files" })
	vim.keymap.set("n", "<leader>fg", builtin.live_grep, { desc = "Live grep" })
	vim.keymap.set("n", "<leader>fb", builtin.buffers, { desc = "Find buffers" })
end

return M
