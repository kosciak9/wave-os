local M = {}

local recent_dirs = require("recent_dirs")
local starter = require("mini.starter")

local function recent_dir_items()
	local items = {}

	for _, dir in ipairs(recent_dirs.list()) do
		local item_dir = dir

		table.insert(items, {
			name = recent_dirs.display_name(item_dir),
			section = "Recent directories",
			action = function()
				MiniStarter.close()
				vim.cmd.cd(vim.fn.fnameescape(item_dir))
				require("telescope.builtin").find_files()
			end,
		})
	end

	if #items == 0 then
		return {
			{ name = "No recent directories yet", action = "", section = "Recent directories" },
		}
	end

	return items
end

local function map_starter_keys()
	vim.keymap.set("n", "j", function()
		MiniStarter.update_current_item("next")
	end, {
		buffer = true,
		desc = "Next starter item",
		nowait = true,
		silent = true,
	})

	vim.keymap.set("n", "k", function()
		MiniStarter.update_current_item("prev")
	end, {
		buffer = true,
		desc = "Previous starter item",
		nowait = true,
		silent = true,
	})

	for index = 1, 9 do
		vim.keymap.set("n", tostring(index), function()
			local query = tostring(index) .. "."
			local items = MiniStarter.content_to_items(MiniStarter.get_content())

			for _, item in ipairs(items) do
				if item.name:sub(1, #query) == query then
					MiniStarter.set_query(query)
					MiniStarter.eval_current_item()
					return
				end
			end
		end, {
			buffer = true,
			desc = ("Open starter item %d"):format(index),
			nowait = true,
			silent = true,
		})
	end

	vim.keymap.set("n", "<2-LeftMouse>", "<LeftMouse><Cmd>lua MiniStarter.eval_current_item()<CR>", {
		buffer = true,
		desc = "Open starter item",
		silent = true,
	})
end

function M.setup()
	recent_dirs.setup({ limit = 20 })

	starter.setup({
		footer = "",
		items = { recent_dir_items },
		query_updaters = "abcdefghilmnopqrstuvwxyz_.-",
		content_hooks = {
			starter.gen_hook.indexing("all"),
			starter.gen_hook.aligning("center", "center"),
		},
	})

	vim.api.nvim_create_autocmd("User", {
		pattern = "MiniStarterOpened",
		callback = map_starter_keys,
	})
end

return M
