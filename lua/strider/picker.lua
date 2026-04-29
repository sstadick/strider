local M = {}

function M.available()
	return pcall(require, "telescope.pickers") or pcall(require, "fzf-lua")
end

local function to_labels(items)
	local labels = {}
	for _, item in ipairs(items or {}) do
		table.insert(labels, item.label)
	end
	return labels
end

local function telescope_select(title, items, on_select)
	local ok, pickers = pcall(require, "telescope.pickers")
	if not ok then
		return false
	end

	vim.api.nvim_create_autocmd("FileType", {
		once = true,
		pattern = "TelescopeResults",
		callback = function(args)
			local win = vim.fn.bufwinid(args.buf)
			if win ~= -1 and vim.api.nvim_win_is_valid(win) then
				vim.wo[win].wrap = true
				vim.wo[win].linebreak = true
			end
		end,
	})

	local labels = to_labels(items)
	local lookup = {}
	for _, item in ipairs(items) do
		lookup[item.label] = item
	end

	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	pickers
		.new({}, {
			prompt_title = title,
			finder = finders.new_table({ results = labels }),
			layout_strategy = "vertical",
			layout_config = {
				height = 0.9,
				width = 0.95,
			},
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					local label = selection and selection[1]
					local item = label and lookup[label]
					if item then
						on_select(item)
					end
				end)
				return true
			end,
		})
		:find()
	return true
end

local function fzf_select(title, items, on_select)
	local ok, fzf = pcall(require, "fzf-lua")
	if not ok then
		return false
	end

	local labels = to_labels(items)
	local lookup = {}
	for _, item in ipairs(items) do
		lookup[item.label] = item
	end

	fzf.fzf_exec(labels, {
		prompt = title .. "> ",
		actions = {
			["default"] = function(selected)
				local label = selected and selected[1]
				local item = label and lookup[label]
				if item then
					on_select(item)
				end
			end,
		},
	})
	return true
end

function M.select(title, items, on_select)
	if not items or #items == 0 then
		return false
	end
	if telescope_select(title, items, on_select) then
		return true
	end
	if fzf_select(title, items, on_select) then
		return true
	end
	vim.ui.select(items, {
		prompt = title,
		format_item = function(item)
			return item.label
		end,
	}, function(item)
		if item then
			on_select(item)
		end
	end)
	return true
end

return M
