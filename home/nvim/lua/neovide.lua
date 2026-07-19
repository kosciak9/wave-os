if vim.g.neovide then
	vim.o.guifont = "OverpassM Nerd Font:h10"

	vim.g.neovide_padding_top = 32
	vim.g.neovide_padding_bottom = 16
	vim.g.neovide_padding_right = 32
	vim.g.neovide_padding_left = 32

	vim.g.neovide_scale_factor = 1.1
	local change_scale_factor = function(delta)
		vim.g.neovide_scale_factor = vim.g.neovide_scale_factor * delta
	end

	vim.keymap.set("n", "<C-=>", function()
		change_scale_factor(1.1)
	end)
	vim.keymap.set("n", "<C-->", function()
		change_scale_factor(1 / 1.1)
	end)
end
