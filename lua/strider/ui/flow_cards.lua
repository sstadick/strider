local card_names = require("strider.ui.card_names")
local chat_card = require("strider.ui.chat_card")
local highlights = require("strider.ui.highlights")
local q_cards = require("strider.ui.q_cards")
local q_compose = require("strider.ui.q_card_compose")
local state = require("strider.state")
local M = {}
local ns = vim.api.nvim_create_namespace("strider-flow-cards")
local G = highlights.groups
local log_user_hl = G.log_user
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
		local session = state.get_session(lane)
		if session then
			session.active_flow_card_id = nil
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
		return card.win
	end
	local buf = card.buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return nil
	end
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		if vim.api.nvim_win_is_valid(win) then
			card.win = win
			return win
		end
	end
	card.win = nil
	return nil
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
local lane_stack_rank = { flow = 1, q = 2, patch = 3 }
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
local function render_card(session, card)
	local buf = ensure_card_buffer(card, session.lane)
	local expanded = card_is_expanded(session, card)
	local lines, question_count, separator_row, body_row
	if card.kind == "q" then
		lines, question_count, separator_row, body_row = q_cards.lines(card, expanded)
	else
		lines, question_count, separator_row, body_row = generic_card_lines(card, expanded)
	end

	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
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
	local expanded = card_is_expanded(session, card)
	if card.status ~= "running" then
		local text = card.title or "Strider flow"
		if card.kind == "q" then
			text = card.status == "success" and "StriderQ answer ready" or "StriderQ stopped"
		end
		if card.kind == "patch" then
			text = card.status == "success" and "StriderPatch complete" or "StriderPatch stopped"
		end
		local hint = card.kind == "q" and "i follow-up · q/Esc fold · d/:q dismiss"
			or "q/Esc fold · d/:q dismiss"
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
	card.win = nil
end
local function clear_legacy_q(session)
	session.q_answer_card_id = nil
	session.q_answer_buf = nil
	session.q_answer_win = nil
	session.q_answer_prompt = nil
	session.q_answer_text = nil
	session.q_answer_done = false
	session.q_answer_status = nil
end
local function sync_latest_q(session)
	local card = latest_card(session, "q")
	if not card then
		clear_legacy_q(session)
		return
	end
	session.q_answer_card_id = card.id
	sync_legacy_q(session, card)
end
local function sorted_cards(session)
	local cards = vim.tbl_filter(function(card)
		return not card.dismissed
	end, ensure_card_state(session))
	table.sort(cards, function(a, b)
		return (a.started_at or 0) < (b.started_at or 0)
	end)
	return cards
end
function M.focus_relative(id, lane, delta)
	lane = normalize_lane(lane)
	local session = state.get_session(lane)
	if not session then
		return false
	end
	local cards = sorted_cards(session)
	if #cards == 0 then
		return false
	end
	local index = 1
	for i, card in ipairs(cards) do
		if card.id == id then
			index = i
			break
		end
	end
	local target = cards[((index - 1 + delta) % #cards) + 1]
	return target and M.focus_card(target.id, lane) or false
end
function M.reflow(lane)
	lane = normalize_lane(lane)
	local session = state.get_session(lane)
	if not session then
		return
	end
	local focused = current_card_id(session)
	if focused then
		session.active_flow_card_id = focused
	end
	local active = card_by_id(session, session.active_flow_card_id)
	if active and not card_window(active) then
		session.active_flow_card_id = nil
	end
	local stack_index = 1
	local cards = sorted_cards(session)
	for i = #cards, 1, -1 do
		local card = cards[i]
		local win = card_window(card)
		if win and vim.api.nvim_win_is_valid(win) then
			render_card(session, card)
			local config = card_config(session, card, stack_index)
			pcall(vim.api.nvim_win_set_config, win, config)
			if not (card.kind == "q" and card_is_expanded(session, card)) then
				pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
			end
			if card.kind == "q" and card_is_expanded(session, card) then
				q_compose.open(card, compose_config(config))
			elseif card.kind == "q" then
				q_compose.close(card)
			end
			pcall(function()
				vim.wo[win].winbar = card_winbar(card, lane)
			end)
			sync_legacy_q(session, card)
			if not card_is_expanded(session, card) then
				stack_index = stack_index + 1
			end
		else
			if card.kind == "q" then
				q_compose.close(card)
			end
			card.win = nil
			sync_legacy_q(session, card)
		end
	end
end
function M.refresh_layouts()
	for _, lane in ipairs(state.lanes()) do
		M.reflow(lane)
	end
end
function M.refresh_winbars(lane)
	lane = normalize_lane(lane)
	local session = state.get_session(lane)
	if not session then
		return
	end
	for _, card in ipairs(ensure_card_state(session)) do
		local win = card_window(card)
		if win and vim.api.nvim_win_is_valid(win) then
			pcall(function()
				vim.wo[win].winbar = card_winbar(card, lane)
			end)
		end
	end
end
local function schedule_dismiss_closed_card(winid)
	if not winid then
		return false
	end
	for _, lane in ipairs(state.lanes()) do
		local session = state.get_session(lane)
		for _, card in ipairs(session and ensure_card_state(session) or {}) do
			local closed_card = card.win == winid
			local closed_compose = card.compose_win == winid and not card.compose_closing
			if not card.dismissed and (closed_card or closed_compose) then
				local id = card.id
				vim.schedule(function()
					local current = card_by_id(state.get_session(lane), id)
					if current and not current.dismissed then
						M.dismiss_card(id, lane)
					end
				end)
				return true
			end
		end
	end
	return false
end

local function schedule_layout_refresh()
	vim.schedule(function()
		M.refresh_layouts()
	end)
end

local function ensure_autocmds()
	if augroup then
		return
	end
	augroup = vim.api.nvim_create_augroup("StriderFlowCardsLayout", { clear = true })
	vim.api.nvim_create_autocmd({ "WinEnter", "WinLeave", "BufEnter", "VimResized" }, {
		group = augroup,
		callback = schedule_layout_refresh,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = augroup,
		callback = function(args)
			if schedule_dismiss_closed_card(tonumber(args.match)) then
				return
			end
			schedule_layout_refresh()
		end,
	})
end
function M.get_card(id, lane)
	lane = normalize_lane(lane)
	return card_by_id(state.get_session(lane), id)
end
function M.open_card(id, lane)
	ensure_autocmds()
	lane = normalize_lane(lane)
	local session = state.get_session(lane)
	local card = card_by_id(session, id)
	if not card then
		return nil
	end
	render_card(session, card)
	local win = open_card_window(session, card)
	M.refresh_layouts()
	return win
end
function M.toggle_q_answer(lane)
	ensure_autocmds()
	lane = normalize_lane(lane)
	local session = state.get_session(lane)
	if not session then
		return false, "No StriderQ card yet"
	end
	local card = latest_card(session, "q") or card_by_id(session, session.q_answer_card_id)
	if not card then
		return false, "No StriderQ card yet"
	end
	local win = card_window(card)
	if card_is_expanded(session, card) and win then
		session.active_flow_card_id = nil
		focus_regular_window(card.buf)
		M.refresh_layouts()
		return true
	end
	session.active_flow_card_id = card.id
	render_card(session, card)
	win = open_card_window(session, card)
	M.refresh_layouts()
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_set_current_win(win)
		q_compose.focus(card)
	end
	return true
end
function M.focus_card(id, lane)
	ensure_autocmds()
	lane = normalize_lane(lane)
	local session = state.get_session(lane)
	local card = card_by_id(session, id)
	if not card then
		return false
	end
	session.active_flow_card_id = card.id
	render_card(session, card)
	local win = open_card_window(session, card)
	M.refresh_layouts()
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_set_current_win(win)
	end
	if card.kind == "q" then
		q_compose.focus(card, { insert = true })
	end
	return true
end
function M.dismiss_card(id, lane)
	lane = normalize_lane(lane)
	local session = state.get_session(lane)
	local card = card_by_id(session, id)
	if not card then
		return false
	end
	card.dismissed = true
	if session.active_flow_card_id == id then
		session.active_flow_card_id = nil
	end
	close_card_surfaces(card)
	focus_regular_window(card.buf)
	if card.kind == "q" then
		sync_latest_q(session)
	end
	M.refresh_layouts()
	return true
end
function M.open_card_log(id, lane)
	local card = card_by_id(state.get_session(lane), id)
	local log_lane = card and card.worker_lane or lane
	local ok, ui = pcall(require, "strider.ui")
	if ok and ui and ui.open_log then
		ui.open_log({}, log_lane)
		return true
	end
	return false
end
function M.clear_completed(opts)
	opts = opts or {}
	local count = 0
	for _, lane in ipairs(state.lanes()) do
		local session = state.get_session(lane)
		for _, card in ipairs(session and ensure_card_state(session) or {}) do
			if not card.dismissed and (opts.all or card.status ~= "running") then
				if M.dismiss_card(card.id, lane) then
					count = count + 1
				end
			end
		end
	end
	return count
end
function M.create_card(kind, opts, lane)
	ensure_autocmds()
	lane = normalize_lane(lane)
	local session = state.get_session(lane)
	if not session then
		return nil
	end
	opts = opts or {}
	local id = opts.id or next_card_id(session)
	local seq = opts.seq or tonumber(tostring(id):match("(%d+)$")) or (#ensure_card_state(session) + 1)
	local card = vim.tbl_extend("force", {
		id = id,
		seq = seq,
		kind = kind,
		lane = lane,
		compose_lane = lane,
		name = opts.name or card_names.default(kind, seq, opts.prompt),
		operation = opts.operation or kind,
		title = opts.title or "Strider flow",
		prompt = opts.prompt or "",
		status = opts.status or "running",
		answer_text = opts.answer_text or "",
		body_lines = opts.body_lines,
		summary = opts.summary,
		started_at = opts.started_at or vim.uv.hrtime(),
		finished_at = opts.finished_at,
		buffer_name = opts.buffer_name,
	}, opts)
	table.insert(ensure_card_state(session), card)
	ensure_card_buffer(card, lane)
	sync_legacy_q(session, card)
	return card.id
end
function M.update_card(id, fields, lane)
	lane = normalize_lane(lane)
	local session = state.get_session(lane)
	local card = card_by_id(session, id)
	if not card then
		return nil
	end
	for key, value in pairs(fields or {}) do
		card[key] = value
	end
	render_card(session, card)
	sync_legacy_q(session, card)
	M.reflow(lane)
	return card
end
local function q_card_count(session)
	local count = 0
	for _, card in ipairs(ensure_card_state(session)) do
		if card.kind == "q" then
			count = count + 1
		end
	end
	return count
end
local function start_q_turn(card, prompt, opts)
	opts = opts or {}
	q_compose.clear(card)
	q_cards.start_turn(card, prompt)
	card.title = "StriderQ"
	if not opts.preserve_name then
		card.name = card_names.default("q", card.seq, prompt)
	end
	return card
end
local function create_q_card(prompt, lane, session, opts)
	opts = opts or {}
	local started = vim.uv.hrtime()
	local seq = opts.seq or (q_card_count(session) + 1)
	local id = M.create_card("q", {
		title = "StriderQ",
		prompt = prompt or "",
		operation = "q",
		started_at = started,
		seq = seq,
		turns = { { prompt = prompt or "", answer_text = "", status = "running", started_at = started } },
		current_turn_index = 1,
		buffer_name = q_card_count(session) == 0 and q_cards.answer_name(lane) or nil,
		worker_lane = opts.worker_lane,
	}, lane)
	local card = card_by_id(session, id)
	session.q_answer_card_id = id
	sync_legacy_q(session, card)
	return card
end
local function ensure_q_card(prompt, lane, opts)
	opts = opts or {}
	lane = normalize_lane(lane)
	local session = state.get_session(lane)
	if not session then
		return nil
	end
	local card = opts.card_id and card_by_id(session, opts.card_id) or nil
	if not card and not opts.new then
		card = card_by_id(session, session.q_answer_card_id)
	end
	if not card then
		return create_q_card(prompt, lane, session, opts)
	end
	if opts.worker_lane then
		card.worker_lane = opts.worker_lane
	end
	session.q_answer_card_id = card.id
	start_q_turn(card, prompt, opts)
	sync_legacy_q(session, card)
	return card
end
function M.ensure_q_answer_buffer(lane)
	lane = normalize_lane(lane)
	local session = state.get_session(lane)
	if not session then
		return nil
	end
	local card = card_by_id(session, session.q_answer_card_id) or ensure_q_card(session.q_answer_prompt, lane)
	if not card then
		return nil
	end
	local buf = ensure_card_buffer(card, lane)
	sync_legacy_q(session, card)
	return buf
end
function M.open_q_answer(prompt, lane, opts)
	ensure_autocmds()
	lane = normalize_lane(lane)
	local session = state.get_session(lane)
	if not session then
		return nil
	end
	local card = ensure_q_card(prompt, lane, opts)
	if not card then
		return nil
	end
	render_card(session, card)
	open_card_window(session, card)
	M.refresh_layouts()
	return card.id
end
local function q_card_for_update(session, card_id)
	return card_by_id(session, card_id) or card_by_id(session, session.q_answer_card_id)
end
function M.update_q_answer(text, lane, card_id)
	lane = normalize_lane(lane)
	local session = state.get_session(lane)
	if not session then
		return
	end
	local card = q_card_for_update(session, card_id)
	if not card then
		return
	end
	q_cards.update_turn(card, text)
	render_card(session, card)
	sync_legacy_q(session, card)
	M.reflow(lane)
end
function M.finish_q_answer(text, status, lane, card_id)
	lane = normalize_lane(lane)
	local session = state.get_session(lane)
	if not session then
		return
	end
	local card = q_card_for_update(session, card_id)
	if not card then
		return
	end
	q_cards.finish_turn(card, text, status or "success")
	render_card(session, card)
	sync_legacy_q(session, card)
	M.reflow(lane)
end
function M.refresh_q_answer_winbar(lane)
	M.refresh_winbars(lane)
end
function M.refresh_q_answer_layouts()
	M.refresh_layouts()
end
return M
