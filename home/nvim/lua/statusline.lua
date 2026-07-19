local CIRCLE = " ⚬ "
local GIT_BRANCH_ICON = "\u{f418}"
local GIT_LOGO_ICON = "\u{e702}"

local function truncate(s, n)
	if not s then
		return ""
	end
	if #s > n then
		return s:sub(1, n) .. "…"
	end
	return s
end

local function to_hex(color)
	if not color then
		return nil
	end
	if type(color) == "string" then
		return color
	end
	return string.format("#%06x", color)
end

local function hl_color(name, field)
	local ok, value = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
	if not ok or not value[field] then
		return nil
	end
	return to_hex(value[field])
end

local function resolve_colors()
	local ok, kanagawa = pcall(require, "kanagawa.colors")
	if ok then
		local theme = kanagawa.setup({ theme = "wave" })
		local vcs = theme.theme.vcs or {}
		return {
			fujiGray = theme.palette.fujiGray,
			sumiInk1 = theme.palette.sumiInk1,
			sumiInk2 = theme.palette.sumiInk2,
			sumiInk4 = theme.palette.sumiInk4,
			sumiInk6 = theme.palette.sumiInk6,
			bg_dim = theme.theme.ui.bg_dim,
			git_add = vcs.added or theme.theme.ui.special,
			git_remove = vcs.removed or theme.theme.ui.error,
			git_change = vcs.changed or theme.theme.ui.warning,
			mode_colors = {
				n = theme.palette.springGreen,
				i = theme.palette.lightBlue,
				v = theme.palette.oniViolet,
				V = theme.palette.oniViolet,
				["\22"] = theme.palette.sumiInk4,
				c = theme.palette.lotusOrange,
				s = theme.palette.carpYellow,
				S = theme.palette.carpYellow,
				["\19"] = theme.palette.waveRed,
				r = theme.palette.lotusAqua,
				R = theme.palette.lotusAqua,
				["!"] = theme.palette.waveRed,
				t = theme.palette.waveRed,
			},
		}
	end

	return {
		fujiGray = hl_color("Comment", "fg") or "#777777",
		sumiInk1 = hl_color("StatusLineNC", "bg") or hl_color("StatusLine", "bg") or "#1f1f1f",
		sumiInk2 = hl_color("StatusLine", "fg") or hl_color("Normal", "fg") or "#c8c8c8",
		sumiInk4 = hl_color("StatusLine", "bg") or hl_color("Normal", "bg") or "#2f2f2f",
		sumiInk6 = hl_color("StatusLine", "fg") or hl_color("Normal", "fg") or "#9d9d9d",
		bg_dim = hl_color("StatusLine", "bg") or hl_color("ColorColumn", "bg") or "#2a2a2a",
		git_add = hl_color("DiffAdd", "fg") or hl_color("LineNr", "fg") or "#98bb6c",
		git_remove = hl_color("DiffDelete", "fg") or hl_color("Error", "fg") or "#e46876",
		git_change = hl_color("DiffChange", "fg") or hl_color("Type", "fg") or "#957fb8",
		mode_colors = {
			n = hl_color("Function", "fg") or "#98bb6c",
			i = hl_color("Type", "fg") or "#7fb4ca",
			v = hl_color("Special", "fg") or "#957fb8",
			V = hl_color("Special", "fg") or "#957fb8",
			["\22"] = hl_color("Comment", "fg") or "#5f5f5f",
			c = hl_color("Statement", "fg") or "#e6b99d",
			s = hl_color("PreProc", "fg") or "#c0a36e",
			S = hl_color("PreProc", "fg") or "#c0a36e",
			["\19"] = hl_color("Error", "fg") or "#e46876",
			r = hl_color("Identifier", "fg") or "#7aa89f",
			R = hl_color("Identifier", "fg") or "#7aa89f",
			["!"] = hl_color("Error", "fg") or "#e46876",
			t = hl_color("Error", "fg") or "#e46876",
		},
	}
end

local colors = resolve_colors()

local MODE_BY_CHAR = {
	["\22"] = "ModeCtrlV",
	["\19"] = "ModeCtrlS",
	n = "ModeN",
	i = "ModeI",
	v = "ModeV",
	V = "ModeV",
	c = "ModeC",
	s = "ModeS",
	S = "ModeS",
	r = "ModeR",
	R = "ModeR",
	["!"] = "ModeEx",
	t = "ModeT",
}

local function mode_highlight_name(mode)
	return MODE_BY_CHAR[mode:sub(1, 1)] or "ModeOther"
end

local function wrap(text, hl)
	if not text or text == "" then
		return ""
	end

	-- Dynamic statusline text must not be interpreted as statusline syntax.
	text = text:gsub("%%", "%%%%")
	if hl and hl ~= "" then
		return ("%%#%s#%s%%*"):format(hl, text)
	end
	return text
end

local function strip_statusline_markup(text)
	return text:gsub("%%#[^#]-#", ""):gsub("%%%*", ""):gsub("%%=", ""):gsub("%%%%", "%%")
end

local function visible_len(text)
	return vim.fn.strdisplaywidth(strip_statusline_markup(text))
end

local function fill_between(winid, left, right)
	local width = vim.api.nvim_win_get_width(winid)
	local spaces = width - visible_len(left) - visible_len(right)
	if spaces < 3 then
		spaces = 3
	end
	return wrap(string.rep(" ", spaces), "StatuslineFill")
end

local function set_hl(name, opts)
	vim.api.nvim_set_hl(0, name, opts)
end

local function update_highlights()
	colors = resolve_colors()

	set_hl("StatusLine", { bg = colors.sumiInk1 })
	set_hl("StatusLineNC", { bg = colors.sumiInk1 })

	set_hl("StatuslineModeInactive", { fg = colors.sumiInk6, bg = colors.sumiInk4 })
	for mode, bg in pairs(colors.mode_colors) do
		set_hl("Statusline" .. mode_highlight_name(mode), { fg = colors.sumiInk1, bg = bg })
	end
	set_hl("StatuslineModeOther", { fg = colors.sumiInk1, bg = colors.sumiInk1 })

	local section_hls = {
		StatuslineFilename = { fg = colors.fujiGray, bg = colors.sumiInk2, bold = true },
		StatuslineFilenameInactive = { fg = colors.fujiGray, bg = colors.sumiInk2, bold = true },
		StatuslineFlags = { fg = colors.fujiGray, bg = colors.sumiInk2 },
		StatuslineDiagError = { fg = colors.fujiGray, bg = colors.sumiInk2 },
		StatuslineDiagWarn = { fg = colors.fujiGray, bg = colors.sumiInk2 },
		StatuslineDiagInfo = { fg = colors.fujiGray, bg = colors.sumiInk2 },
		StatuslineDiagHint = { fg = colors.fujiGray, bg = colors.sumiInk2 },
		StatuslineGit = { fg = colors.fujiGray, bg = colors.sumiInk2 },
		StatuslineGitNone = { fg = colors.fujiGray, bg = colors.sumiInk2 },
		StatuslineGitAdd = { fg = colors.git_add, bg = colors.sumiInk2 },
		StatuslineGitRemove = { fg = colors.git_remove, bg = colors.sumiInk2 },
		StatuslineGitChange = { fg = colors.git_change, bg = colors.sumiInk2 },
		StatuslineColumn = { fg = colors.fujiGray, bg = colors.bg_dim },
		StatuslineFill = { fg = colors.fujiGray, bg = colors.sumiInk2 },
		StatuslineTree = { fg = colors.fujiGray, bg = colors.sumiInk2 },
	}
	for name, opts in pairs(section_hls) do
		set_hl(name, opts)
	end
end

local function filename(buf)
	local name = vim.api.nvim_buf_get_name(buf)
	if name == "" then
		return "-"
	end
	return vim.fn.fnamemodify(name, ":t")
end

local function tree_buffer(buf)
	return vim.api.nvim_get_option_value("filetype", { buf = buf }) == "oil"
end

local function tree_label(buf)
	local path = vim.api.nvim_buf_get_name(buf)
	if path == "" then
		return "tree"
	end
	if path:sub(1, 6) == "oil://" then
		path = path:sub(7)
	end
	return vim.fn.fnamemodify(path, ":~")
end

local function is_active(winid)
	return winid == vim.api.nvim_get_current_win()
end

local function active_lsp(buf)
	return #vim.lsp.get_clients({ bufnr = buf }) > 0
end

local function build_mode_group()
	return "Statusline" .. mode_highlight_name(vim.api.nvim_get_mode().mode)
end

local function render_diagnostics(buf)
	if not active_lsp(buf) then
		return ""
	end

	local severity_map = {
		{ severity = vim.diagnostic.severity.ERROR, hl = "StatuslineDiagError" },
		{ severity = vim.diagnostic.severity.WARN, hl = "StatuslineDiagWarn" },
		{ severity = vim.diagnostic.severity.INFO, hl = "StatuslineDiagInfo" },
		{ severity = vim.diagnostic.severity.HINT, hl = "StatuslineDiagHint" },
	}

	local chunks = {}
	for _, item in ipairs(severity_map) do
		local count = #vim.diagnostic.get(buf, { severity = item.severity })
		if count > 0 then
			table.insert(chunks, wrap(CIRCLE .. count .. " ", item.hl))
		end
	end

	return table.concat(chunks)
end

local function git_none()
	return wrap(" " .. GIT_LOGO_ICON .. " - ", "StatuslineGitNone")
end

local function git_head(git_root)
	local head = vim.fn.systemlist({ "git", "-C", git_root, "rev-parse", "--abbrev-ref", "HEAD" })
	if vim.v.shell_error ~= 0 or #head == 0 then
		return nil
	end
	local branch = vim.trim(head[1])
	return branch ~= "" and branch or nil
end

local function git_counts(git_root)
	local status = vim.fn.systemlist({ "git", "-C", git_root, "status", "--short" })
	if vim.v.shell_error ~= 0 then
		return nil
	end

	local counts = { added = 0, removed = 0, changed = 0 }
	for _, line in ipairs(status) do
		if #line >= 2 then
			local x, y = line:sub(1, 1), line:sub(2, 2)
			if x == "?" and y == "?" then
				counts.added = counts.added + 1
			elseif x == "A" or y == "A" then
				counts.added = counts.added + 1
			elseif x == "D" or y == "D" then
				counts.removed = counts.removed + 1
			elseif x == "M" or y == "M" or x == "R" or y == "R" or x == "C" or y == "C" then
				counts.changed = counts.changed + 1
			end
		end
	end

	return counts
end

local M = {}

local git_cache = {
	root = nil,
	text = nil,
	last_refresh = 0,
	refresh_delay_ms = 1500,
}

local function git_root_from_cwd()
	local cwd = vim.uv.cwd()
	if not cwd or cwd == "" then
		return nil
	end

	local root = vim.fn.systemlist({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })
	if vim.v.shell_error ~= 0 or #root == 0 then
		return nil
	end

	root = vim.trim(root[1])
	return root ~= "" and root or nil
end

local function render_git_counts(branch, counts)
	if not branch then
		return git_none()
	end

	local chunks = { wrap("  " .. GIT_BRANCH_ICON .. " " .. truncate(branch, 30) .. " ", "StatuslineGit") }
	if counts then
		if counts.added > 0 then
			table.insert(chunks, wrap("+" .. counts.added .. " ", "StatuslineGitAdd"))
		end
		if counts.removed > 0 then
			table.insert(chunks, wrap("-" .. counts.removed .. " ", "StatuslineGitRemove"))
		end
		if counts.changed > 0 then
			table.insert(chunks, wrap("~" .. counts.changed .. " ", "StatuslineGitChange"))
		end
		return " " .. table.concat(chunks)
	end

	return " "
end

function M.refresh_git_cache(force)
	local now = vim.uv.now()
	if not force and now - git_cache.last_refresh < git_cache.refresh_delay_ms then
		return
	end

	local git_root = git_root_from_cwd()
	if not git_root then
		git_cache.root = nil
		git_cache.text = git_none()
		git_cache.last_refresh = now
		return
	end

	local branch = git_head(git_root)
	if not branch then
		git_cache.root = git_root
		git_cache.text = git_none()
		git_cache.last_refresh = now
		return
	end

	local counts = git_counts(git_root)
	git_cache.root = git_root
	git_cache.text = render_git_counts(branch, counts)
	git_cache.last_refresh = now
end

local function render_git(buf)
	if vim.api.nvim_get_option_value("readonly", { buf = buf }) and not tree_buffer(buf) then
		return ""
	end

	if not git_cache.text then
		M.refresh_git_cache(true)
	end

	return git_cache.text or git_none()
end

function M.render()
	local winid = vim.g.statusline_winid or vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_win_get_buf(winid)
	local is_tree = tree_buffer(buf)
	local modified = vim.api.nvim_get_option_value("modified", { buf = buf })
	local is_active_win = is_active(winid)

	local name = is_tree and tree_label(buf) or filename(buf)
	name = truncate(name, is_tree and 60 or 55)

	local file_hl = is_tree and "StatuslineTree"
		or (is_active_win and "StatuslineFilename" or "StatuslineFilenameInactive")
	local mode_group = is_active_win and build_mode_group() or "StatuslineModeInactive"
	local pieces = {
		wrap("    " .. (modified and "•" or "◦") .. " ", mode_group),
		wrap(" " .. name .. " ", file_hl),
	}

	if is_active_win then
		if
			not vim.api.nvim_get_option_value("modifiable", { buf = buf })
			or vim.api.nvim_get_option_value("readonly", { buf = buf })
		then
			table.insert(pieces, wrap(CIRCLE, "StatuslineFlags"))
		end

		local diag = render_diagnostics(buf)
		local git = render_git(buf)
		local right = diag .. git

		table.insert(pieces, fill_between(winid, table.concat(pieces), right))
		table.insert(pieces, diag)
		table.insert(pieces, git)
	end

	return table.concat(pieces)
end

function M.setup()
	update_highlights()
	vim.o.statusline = "%!v:lua.require('statusline').render()"
	M.refresh_git_cache(true)

	local group = vim.api.nvim_create_augroup("CustomStatusline", { clear = true })
	vim.api.nvim_create_autocmd({
		"ModeChanged",
		"WinEnter",
		"WinLeave",
		"DiagnosticChanged",
	}, {
		group = group,
		callback = function()
			vim.cmd.redrawstatus()
		end,
	})

	vim.api.nvim_create_autocmd({
		"BufEnter",
		"BufWritePost",
		"DirChanged",
		"VimEnter",
	}, {
		group = group,
		callback = function()
			M.refresh_git_cache(true)
			vim.cmd.redrawstatus()
		end,
	})

	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = "GitsignsUpdate",
		callback = function()
			M.refresh_git_cache(true)
			vim.cmd.redrawstatus()
		end,
	})

	vim.api.nvim_create_autocmd("ColorScheme", {
		group = group,
		callback = function()
			update_highlights()
		end,
	})
end

M.setup()

return M
