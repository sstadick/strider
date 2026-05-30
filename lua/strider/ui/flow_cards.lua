local card_names = require("strider.ui.card_names")
local chat_card = require("strider.ui.chat_card")
local highlights = require("strider.ui.highlights")
local markdown_render = require("strider.ui.markdown_render")
local q_cards = require("strider.ui.q_cards")
local q_compose = require("strider.ui.q_card_compose")
local state = require("strider.state")
local M = {}
local ns = vim.api.nvim_create_namespace("strider-flow-cards")
local G = highlights.groups
local log_user_hl = G.log_user
local log_followup_hl = G.log_followup
local log_rule_hl = G.log_rule
local log_muted_hl = G.log_muted
local compose_working_hl = G.compose_working
local FOLDED_HEIGHT = 3
local STACK_GAP = 1
local STACK_MARGIN_BOTTOM = 2
local FOLDED_ZINDEX = 40
local EXPANDED_ZINDEX = 70
local EXPANDED_TOP_MARGIN = 1
local EXPANDED_BOTTOM_MARGIN = 3
local Q_COMPOSE_HEIGHT = 6
local Q_SPLIT_GAP = 0
local WORKING_LABEL = "Working"
local augroup = nil
local function normalize_lane(lane)
	return state.normalize_lane(lane)
end
local function escape_status_text(text)
	local escaped = (text or ""):gsub("%%", "%%%%")
	return escaped
end
local function format_elapsed(start_ns)
	if not start_ns then
		return nil
	end
	local elapsed_s = (vim.uv.hrtime() - start_ns) / 1e9
	if elapsed_s < 60 then
		return string.format("%ds", math.floor(elapsed_s))
	end
	if elapsed_s < 3600 then
		return string.format("%dm%02ds", math.floor(elapsed_s / 60), math.floor(elapsed_s % 60))
	end
	return string.format("%dh%02dm", math.floor(elapsed_s / 3600), math.floor((elapsed_s % 3600) / 60))
end
local function stop_command(lane)
	return state.is_flow_lane(lane) and ":StriderStopFlow" or ":StriderStop"
end
local function stop_hint(lane)
	return stop_command(lane) .. " to interrupt"
end
local function working_label()
	highlights.ensure()
	return string.format("%%#%s#%s%%*", compose_working_hl, WORKING_LABEL)
end
local function configure_scratch_buffer(buf, filetype)
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = true
	if filetype then
		vim.bo[buf].filetype = filetype
		if filetype == "markdown" then
			markdown_render.keep_conceal(buf)
		end
	end
end
local function ensure_card_state(session)
	session.flow_cards = session.flow_cards or {}
	session.flow_card_seq = session.flow_card_seq or 0
	return session.flow_cards
end
local function next_card_id(session)
	session.flow_card_seq = (session.flow_card_seq or 0) + 1
	return string.format("flow-card-%d", session.flow_card_seq)
end
local function card_by_id(session, id)
	if not session or not id then
		return nil
	end
	for _, card in ipairs(ensure_card_state(session)) do
		if card.id == id then
			return card
		end
	end
	return nil
end
local function card_buffer_name(card, lane)
	if card.buffer_name then
		return card.buffer_name
	end
	local seq = card.seq or tostring(card.id):match("(%d+)$") or "1"
	return string.format("strider://flow-card/%s/%s", card.kind or "card", seq)
end
local function ensure_card_buffer(card, lane)
	if card.buf and vim.api.nvim_buf_is_valid(card.buf) then
		return card.buf
	end
	local name = card_buffer_name(card, lane)
	local existing = vim.fn.bufnr(name)
	local buf = existing > 0 and existing or vim.api.nvim_create_buf(false, true)
	pcall(vim.api.nvim_buf_set_name, buf, name)
	configure_scratch_buffer(buf, "markdown")
	vim.bo[buf].bufhidden = "hide"
	card.buf = buf
	vim.b[buf].strider_flow_card = card.id
	vim.b[buf].strider_flow_card_kind = card.kind
	if card.kind == "q" then
		vim.b[buf].strider_q_answer = true
		q_compose.attach_answer(card)
	end
	local function fold_card()
		local current = vim.api.nvim_get_current_win()
		local current_is_regular = vim.api.nvim_win_get_buf(current) == buf
			and vim.api.nvim_win_get_config(current).relative == ""
		local session = state.get_session(lane)
		if session then
			session.active_flow_card_id = nil
		end
		if current_is_regular and pcall(vim.api.nvim_win_close, current, true) then
			M.refresh_layouts()
			return
		end
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_get_buf(win) ~= buf and vim.api.nvim_win_get_config(win).relative == "" then
				pcall(vim.api.nvim_set_current_win, win)
				break
			end
		end
		M.refresh_layouts()
	end
	local function map(lhs, rhs, desc)
		vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
	end
	for _, lhs in ipairs({ "q", "<Esc>" }) do
		map(lhs, fold_card, "Fold Strider flow card")
	end
	map("d", function()
		M.dismiss_card(card.id, lane)
	end, "Dismiss Strider flow card")
	map("o", function()
		M.open_card_log(card.id, lane)
	end, "Open Strider flow card log")
	map("]c", function()
		M.focus_relative(card.id, lane, 1)
	end, "Next Strider flow card")
	map("[c", function()
		M.focus_relative(card.id, lane, -1)
	end, "Previous Strider flow card")
	return buf
end
local sync_legacy_q = q_cards.sync_legacy
local function card_window(card)
	if not card then
		return nil
	end
	if card.win and vim.api.nvim_win_is_valid(card.win) then
		if vim.api.nvim_win_get_config(card.win).relative ~= "" then
			return card.win
		end
		card.win = nil
	end
	local buf = card.buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return nil
	end
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative ~= "" then
			card.win = win
			return win
		end
	end
	card.win = nil
	return nil
end
local function regular_card_windows(card)
	local buf = card and card.buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return {}
	end
	local wins = {}
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative == "" then
			table.insert(wins, win)
		end
	end
	return wins
end
local function focus_regular_window(exclude_buf)
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local regular = vim.api.nvim_win_get_config(win).relative == ""
		if regular and vim.api.nvim_win_get_buf(win) ~= exclude_buf then
			pcall(vim.api.nvim_set_current_win, win)
			return true
		end
	end
	return false
end
local function current_card_id(session)
	local current = vim.api.nvim_get_current_win()
	for _, card in ipairs(ensure_card_state(session)) do
		local win = card_window(card)
		if win and win == current then
			return card.id
		end
	end
	return nil
end
local function card_is_expanded(session, card)
	return session and card and session.active_flow_card_id == card.id
end
local function ui_size()
	return vim.api.nvim_list_uis()[1] or { width = 120, height = 30 }
end
local function card_width(width)
	return math.min(88, math.max(42, math.floor(width * 0.42)))
end
local function folded_row(ui_height, stack_index)
	local step = FOLDED_HEIGHT + 2 + STACK_GAP
	return math.max(ui_height - FOLDED_HEIGHT - STACK_MARGIN_BOTTOM - step * (stack_index - 1), 0)
end
local lane_stack_rank = { flow = 1, q = 2 }
local function expanded_height(info)
	return math.max(FOLDED_HEIGHT, info.height - EXPANDED_BOTTOM_MARGIN - 1)
end
local function folded_card_count(session)
	if not session then
		return 0
	end
	local count = 0
	for _, card in ipairs(ensure_card_state(session)) do
		if not card.dismissed and not card_is_expanded(session, card) then
			count = count + 1
		end
	end
	return count
end
local function stack_base_offset(lane)
	local offset = chat_card.is_visible() and 1 or 0
	local rank = lane_stack_rank[lane] or 1
	for other, other_rank in pairs(lane_stack_rank) do
		if other_rank < rank then
			offset = offset + folded_card_count(state.get_session(other))
		end
	end
	return offset
end
local function card_config(session, card, stack_index)
	local info = ui_size()
	local expanded = card_is_expanded(session, card)
	local width = card_width(info.width)
	local height = expanded and expanded_height(info) or FOLDED_HEIGHT
	if expanded and card.kind == "q" then
		height = math.max(6, height - Q_COMPOSE_HEIGHT - Q_SPLIT_GAP - 2)
	end
	local folded_index = (stack_index or 1) + stack_base_offset(session.lane)
	return {
		relative = "editor",
		anchor = "NW",
		row = expanded and EXPANDED_TOP_MARGIN or folded_row(info.height, folded_index),
		col = math.max(info.width - width - 1, 0),
		width = width,
		height = height,
		border = "rounded",
		title = " " .. (card.name or card.title or "Strider flow") .. " ",
		title_pos = "left",
		style = "minimal",
		focusable = true,
		zindex = expanded and EXPANDED_ZINDEX or FOLDED_ZINDEX,
	}
end
local function compose_config(answer_config)
	return {
		relative = "editor",
		anchor = "NW",
		row = answer_config.row + answer_config.height + 2 + Q_SPLIT_GAP,
		col = answer_config.col,
		width = answer_config.width,
		height = Q_COMPOSE_HEIGHT,
		border = "rounded",
		title = " StriderQ follow-up ",
		title_pos = "left",
		style = "minimal",
		focusable = true,
		zindex = EXPANDED_ZINDEX + 1,
	}
end
local function configure_card_window(win)
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].foldcolumn = "0"
	vim.wo[win].cursorline = false
	vim.wo[win].winhighlight = "NormalFloat:Normal,FloatBorder:FloatBorder"
	markdown_render.apply_to_window(win)
end
local function configure_answer_split(win)
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].foldcolumn = "0"
	vim.wo[win].cursorline = false
	vim.wo[win].winfixwidth = true
	markdown_render.apply_to_window(win)
end
local function preview_text(text)
	local preview = vim.trim((text or ""):gsub("%s+", " "))
	if preview == "" then
		preview = "(no question)"
	end
	if vim.fn.strchars(preview) > 74 then
		preview = vim.fn.strcharpart(preview, 0, 73) .. "…"
	end
	return preview
end
local function generic_card_lines(card, expanded)
	local lines = {}
	table.insert(lines, "› " .. preview_text(card.prompt))
	table.insert(
		lines,
		"────────────────────────────────"
	)
	if expanded and card.body_lines and #card.body_lines > 0 then
		vim.list_extend(lines, card.body_lines)
	else
		table.insert(lines, card.summary or "Waiting for Strider…")
	end
	return lines, 1, 1, 2
end
local function q_marker(line)
	if vim.startswith(line, "↳ ") then
		return "↳ ", log_followup_hl
	end
	if vim.startswith(line, "› ") then
		return "› ", log_user_hl
	end
	return nil, nil
end
local function highlight_q_rows(buf, lines)
	for row = 0, #lines - 1 do
		local line = lines[row + 1] or ""
		local marker, marker_hl = q_marker(line)
		if marker then
			pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, {
				end_row = row + 1,
				hl_group = log_user_hl,
				priority = 10,
			})
			pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, {
				end_col = #marker,
				hl_group = marker_hl,
				priority = 12,
			})
		elseif line:match("^─") then
			pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, {
				end_row = row + 1,
				hl_group = log_rule_hl,
				priority = 10,
			})
		end
	end
end
local function highlight_generic_prompt(buf, question_count, separator_row)
	for row = 0, question_count - 1 do
		pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, {
			end_row = row + 1,
			hl_group = log_user_hl,
			priority = 10,
		})
	end
	pcall(vim.api.nvim_buf_set_extmark, buf, ns, separator_row, 0, {
		end_row = separator_row + 1,
		hl_group = log_rule_hl,
		priority = 10,
	})
end
local function render_card(session, card, force_expanded)
	local buf = ensure_card_buffer(card, session.lane)
	local expanded = force_expanded or card_is_expanded(session, card) or #regular_card_windows(card) > 0
	local lines, question_count, separator_row, body_row
	if card.kind == "q" then
		lines, question_count, separator_row, body_row = q_cards.lines(card, expanded)
	else
		lines, question_count, separator_row, body_row = generic_card_lines(card, expanded)
	end

	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	if card.kind == "q" then
		highlight_q_rows(buf, lines)
	else
		highlight_generic_prompt(buf, question_count, separator_row)
	end
	if card.status == "running" and vim.trim(card.answer_text or "") == "" then
		pcall(vim.api.nvim_buf_set_extmark, buf, ns, body_row, 0, {
			end_row = body_row + 1,
			hl_group = log_muted_hl,
			priority = 10,
		})
	end
	vim.bo[buf].modifiable = false
	pcall(function()
		vim.bo[buf].modified = false
	end)
end
local function card_winbar(card, lane)
	local session = state.get_session(lane)
	if session and session.progress and card.status == "running" then
		local elapsed = format_elapsed(session.progress.started_at) or "0s"
		local title = session.progress.title or (card.title or "Strider flow") .. " running..."
		local left = working_label() .. escape_status_text(string.format(" (%s) · %s", elapsed, title))
		return left .. "%=" .. escape_status_text(stop_hint(lane))
	end
	local expanded = card_is_expanded(session, card) or #regular_card_windows(card) > 0
	if card.status ~= "running" then
		local text = card.title or "Strider flow"
		if card.kind == "q" then
			text = card.status == "success" and "StriderQ answer ready" or "StriderQ stopped"
		end
		local hint = card.kind == "q" and "a follow-up · q close · d dismiss · o log" or "q/Esc fold · d/:q dismiss"
		return escape_status_text(text) .. (expanded and "%=" .. escape_status_text(hint) or "")
	end
	return escape_status_text(card.title or "Strider flow")
end
local function open_card_window(session, card)
	local buf = ensure_card_buffer(card, session.lane)
	local win = card_window(card)
	if win and vim.api.nvim_win_is_valid(win) then
		pcall(vim.api.nvim_win_set_config, win, card_config(session, card, 1))
	else
		win = vim.api.nvim_open_win(buf, false, card_config(session, card, 1))
	end
	configure_card_window(win)
	card.win = win
	sync_legacy_q(session, card)
	return win
end
local function latest_card(session, kind)
	local best = nil
	for _, card in ipairs(ensure_card_state(session)) do
		local matches = not card.dismissed and (not kind or card.kind == kind)
		if matches and (not best or (card.started_at or 0) > (best.started_at or 0)) then
			best = card
		end
	end
	return best
end
local function close_card_surfaces(card)
	if card.kind == "q" then
		q_compose.close(card)
	end
	local win = card_window(card)
	if win then
		pcall(vim.api.nvim_win_close, win, true)
	end
	for _, regular in ipairs(regular_card_windows(card)) do
		pcall(vim.api.nvim_win_close, regular, true)
	end
	card.win = nil
end
local ctx = {
	card_by_id = card_by_id,
	card_config = card_config,
	card_is_expanded = card_is_expanded,
	card_names = card_names,
	card_window = card_window,
	card_winbar = card_winbar,
	close_card_surfaces = close_card_surfaces,
	compose_config = compose_config,
	configure_answer_split = configure_answer_split,
	current_card_id = current_card_id,
	ensure_card_buffer = ensure_card_buffer,
	ensure_card_state = ensure_card_state,
	focus_regular_window = focus_regular_window,
	latest_card = latest_card,
	next_card_id = next_card_id,
	normalize_lane = normalize_lane,
	open_card_window = open_card_window,
	q_cards = q_cards,
	q_compose = q_compose,
	regular_card_windows = regular_card_windows,
	render_card = render_card,
	state = state,
	sync_legacy_q = sync_legacy_q,
}

require("strider.ui.flow_card_actions").attach(M, ctx)
require("strider.ui.flow_card_q_actions").attach(M, ctx)

return M
