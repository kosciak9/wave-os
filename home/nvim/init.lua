local o = vim.o

o.encoding = "utf-8"
o.autoindent = true
o.expandtab = true
o.tabstop = 2
o.shiftwidth = 2
o.softtabstop = 4
o.shiftround = true

o.textwidth = 79
o.signcolumn = "yes"
o.display = "lastline"
o.hidden = true
o.showcmd = true
o.showmode = false

o.incsearch = true
o.hlsearch = true
o.ignorecase = true
o.scrolloff = 12
o.wrapscan = true

o.laststatus = 2

o.foldmethod = "expr"
o.foldexpr = "v:lua.vim.treesitter.foldexpr()"
o.foldcolumn = "0"
o.foldlevel = 99
o.foldlevelstart = 99
o.foldenable = true

o.autoread = true

o.swapfile = true
o.dir = "/tmp"
o.smartcase = true

o.cursorline = true
o.number = true
o.relativenumber = true
o.numberwidth = 4

o.termguicolors = false
o.splitkeep = "screen"
o.clipboard = "unnamedplus"
o.shortmess = "lmrwaIFScCWT"

vim.wo.fillchars = "eob: "

vim.o.completeopt = "menuone,noinsert,noselect,popup"
vim.api.nvim_create_autocmd({ "CompleteDone" }, {
	pattern = "*",
	command = "if pumvisible() == 0 | pclose | endif",
	group = vim.api.nvim_create_augroup("close_preview", { clear = true }),
})

require("keybinds")
require("lsp")
require("statusline")
require("packs")
require("neovide")
