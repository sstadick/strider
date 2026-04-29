local M = {}

M.groups = {
	added_chunk = "StriderChunkAddedGutter",
	removed_chunk = "StriderChunkRemovedGutter",
	comment = "StriderCommentGutter",
	annotation = "StriderAnnotation",
	log_assistant = "StriderLogAssistant",
	log_user = "StriderLogUser",
	log_tool = "StriderLogTool",
	log_thinking = "StriderLogThinking",
	log_rule = "StriderLogRule",
	log_error = "StriderLogError",
	log_path = "StriderLogPath",
	log_muted = "StriderLogMuted",
	log_tool_output = "StriderLogToolOutput",
	log_tool_output_ellipsis = "StriderLogToolOutputEllipsis",
	log_tool_output_gutter = "StriderLogToolOutputGutter",
	log_tool_output_meta = "StriderLogToolOutputMeta",
	log_tool_output_error = "StriderLogToolOutputError",
	log_assistant_bg = "StriderLogAssistantBg",
	log_user_bg = "StriderLogUserBg",
	log_error_bg = "StriderLogErrorBg",
	log_diff_add = "StriderLogDiffAdd",
	log_diff_remove = "StriderLogDiffRemove",
	log_diff_context = "StriderLogDiffContext",
	log_diff_stats = "StriderLogDiffStats",
	log_diff_add_sign = "StriderLogDiffAddSign",
	log_diff_remove_sign = "StriderLogDiffRemoveSign",
	log_diff_line_number = "StriderLogDiffLineNumber",
	log_diff_gutter = "StriderLogDiffGutter",
	compose_working = "StriderComposeWorking",
	compose_working_soft = "StriderComposeWorkingSoft",
	compose_working_shine = "StriderComposeWorkingShine",
}

local G = M.groups
local installed = false

local function set(group, spec)
	vim.api.nvim_set_hl(0, group, vim.tbl_extend("force", { default = true }, spec))
end

local function hl_attr(group, attr)
	local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
	if not ok or type(hl) ~= "table" then
		return nil
	end
	local value = hl[attr]
	return type(value) == "number" and value or nil
end

local function rgb_channels(color)
	return {
		r = math.floor(color / 65536) % 256,
		g = math.floor(color / 256) % 256,
		b = color % 256,
	}
end

local function blend_to_hex(base, accent, amount)
	local a = rgb_channels(base)
	local b = rgb_channels(accent)
	local function mix(from, to)
		return math.floor(from + (to - from) * amount + 0.5)
	end
	return string.format("#%02x%02x%02x", mix(a.r, b.r), mix(a.g, b.g), mix(a.b, b.b))
end

local function theme_user_log_bg()
	local base = hl_attr("Normal", "bg") or hl_attr("NormalFloat", "bg")
	if not base then
		return nil
	end
	local candidates = {
		{ "Visual", "bg" },
		{ "PmenuSel", "bg" },
		{ "CursorLine", "bg" },
		{ "Search", "bg" },
		{ "Question", "fg" },
		{ "Identifier", "fg" },
		{ "Normal", "fg" },
	}
	for _, item in ipairs(candidates) do
		local accent = hl_attr(item[1], item[2])
		if accent and accent ~= base then
			return blend_to_hex(base, accent, 0.10)
		end
	end
end

local function install_marker_groups()
	set(G.added_chunk, { fg = "#73C991" })
	set(G.removed_chunk, { fg = "#F14C4C" })
	set(G.comment, { fg = "#D7BA7D" })
	set(G.annotation, { link = "Comment" })
end

local function install_compose_groups()
	set(G.compose_working, { link = "WinBar" })
	set(G.compose_working_soft, { fg = "#9CA3AF" })
	set(G.compose_working_shine, { fg = "#73C991", bold = true })
end

local function install_log_label_groups()
	set(G.log_assistant, { fg = "#73C991", bold = true })
	set(G.log_user, { fg = "#7BB5FF", bold = true })
	set(G.log_tool, { link = "Normal" })
	set(G.log_thinking, { fg = "#6B7280", italic = true })
	set(G.log_rule, { link = "NonText" })
	set(G.log_error, { fg = "#F14C4C", bold = true })
	set(G.log_path, { fg = "#7BB5FF" })
	set(G.log_muted, { link = "NonText" })
end

local function install_log_background_groups()
	set(G.log_assistant_bg, { link = "Normal" })
	local user_bg = theme_user_log_bg()
	set(G.log_user_bg, user_bg and { bg = user_bg } or { link = "Normal" })
	set(G.log_error_bg, { bg = "#361a1a" })
end

local function install_diff_groups()
	set(G.log_diff_add, { bg = "#1f3326" })
	set(G.log_diff_remove, { bg = "#3a2024" })
	set(G.log_diff_context, { link = "NonText" })
	set(G.log_diff_stats, { link = "NonText" })
	set(G.log_diff_add_sign, { fg = "#73C991", bold = true })
	set(G.log_diff_remove_sign, { fg = "#F14C4C", bold = true })
	set(G.log_diff_line_number, { link = "LineNr" })
	set(G.log_diff_gutter, { link = "NonText" })
end

local function install_tool_output_groups()
	set(G.log_tool_output, { fg = "#9CA3AF" })
	set(G.log_tool_output_ellipsis, { fg = "#6B7280", italic = true })
	set(G.log_tool_output_gutter, { fg = "#6B7280" })
	set(G.log_tool_output_meta, { link = "NonText" })
	set(G.log_tool_output_error, { fg = "#F14C4C" })
end

function M.ensure()
	if installed then
		return
	end
	installed = true
	install_marker_groups()
	install_compose_groups()
	install_log_label_groups()
	install_log_background_groups()
	install_diff_groups()
	install_tool_output_groups()
end

function M.reset()
	installed = false
	M.ensure()
end

vim.api.nvim_create_autocmd("ColorScheme", {
	group = vim.api.nvim_create_augroup("StriderHighlights", { clear = true }),
	callback = M.reset,
})

return M
