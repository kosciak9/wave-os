vim.keymap.set("n", " ", "<Nop>", { silent = true, remap = false })
vim.g.mapleader = " "

vim.keymap.set("n", "<leader>q", "<cmd>:bp<bar>sp<bar>bn<bar>bd<CR>", {
	desc = "Kill the buffer",
	silent = true,
})

vim.keymap.set("n", "<leader>-", function()
	local name = vim.api.nvim_buf_get_name(0)
	local stat = name ~= "" and vim.uv.fs_stat(name) or nil
	local is_file = stat ~= nil and stat.type == "file"
	local ok, oil = pcall(require, "oil")

	if ok then
		if is_file then
			oil.open()
		else
			oil.open(vim.uv.cwd())
		end

		return
	end

	local dir = is_file and vim.fs.dirname(name) or vim.uv.cwd()
	vim.cmd.edit(vim.fn.fnameescape(dir))
end, {
	desc = "Open file explorer at buffer directory",
	silent = true,
})
