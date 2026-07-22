-- nvim setup options (shorthand)
local o = vim.o

o.encoding = "utf-8" -- https://xkcd.com/927/
o.autoindent = true -- Indent according to previous line.
o.expandtab = true -- Use spaces instead of tabs
o.tabstop = 2 -- Tab key indents by 4 spaces
o.shiftwidth = 2 -- >> indents by tabstop spaces
o.softtabstop = 4 -- >> indents by softtabstop spaces
o.shiftround = true -- >> indents to next multiple of 'shiftwidth'

o.textwidth = 79 -- terminals
o.signcolumn = "yes" -- don't "jump" the UI with linters
o.display = "lastline" -- show as much as possible of the last line
o.hidden = true -- switch between buffers without having to save
o.showcmd = true -- show already typed keys when more are expected
o.showmode = false -- hide "-INSERT–"

o.incsearch = true -- highlight search results
o.hlsearch = true -- highlight _all_ search results
o.ignorecase = true -- ignore case when searching
o.scrolloff = 12 -- cursor offset on searching
o.wrapscan = true -- wrap search on end

o.laststatus = 2 -- always show statusline

-- folds!
o.foldmethod = "expr"
o.foldexpr = "v:lua.vim.treesitter.foldexpr()"
o.foldcolumn = "0"
o.foldlevel = 99
o.foldlevelstart = 99
o.foldenable = true

-- Required for `opts.events.reload`.
o.autoread = true

o.swapfile = true -- use swap files
o.dir = "/tmp" -- keep swap files in tmp
o.smartcase = true -- ignore case only when there is no uppercase chars

o.cursorline = true -- find the current line quickly.
o.number = true -- show line numbers
o.relativenumber = true -- …but relative ones
o.numberwidth = 4 -- keep line-number gutter width stable across short files

o.termguicolors = false -- if no colorscheme loaded - use term colors

o.splitkeep = "screen" -- keep buffers stable on opening another split (stop UI jumps)

o.clipboard = "unnamedplus" -- copy to system clipboard

-- unclutter feedback
o.shortmess = "lmrwaIFScCWT"

-- don't show ~ on empty lines
vim.wo.fillchars = "eob: "

-- use builtin completion
vim.o.completeopt = "menuone,noinsert,noselect,popup"
vim.api.nvim_create_autocmd({ "CompleteDone" }, {
	pattern = "*",
	command = "if pumvisible() == 0 | pclose | endif",
	group = vim.api.nvim_create_augroup("close_preview", { clear = true }),
})

-- keybinds that don't require any plugin
require("keybinds")

-- language server protocol configuration
require("lsp")

-- vanilla-friendly, no runtime dependency statusline.
require("statusline")

-- all the plugins I use - with their configuration and keybinds
-- only loads for nvim --version > 0.12.0
-- loaded from the Nix-managed runtime, without using vim.pack as a package manager
if vim.pack then
	require("plugins")
end

-- neovide configuration - loads conditionally
require("neovide")
