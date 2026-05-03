local M = {}
local augroup = nil

local function clear_legacy_q(session)
	session.q_answer_card_id = nil
	session.q_answer_buf = nil
	session.q_answer_win = nil
	session.q_answer_prompt = nil
	session.q_answer_text = nil
	session.q_answer_done = false
	session.q_answer_status = nil
end

local function sync_latest_q(ctx, session)
	local card = ctx.latest_card(session, "q")
	if not card then
		clear_legacy_q(session)
		return
	end
	session.q_answer_card_id = card.id
	ctx.sync_legacy_q(session, card)
end

local function sorted_cards(ctx, session)
	local cards = vim.tbl_filter(function(card)
		return not card.dismissed
	end, ctx.ensure_card_state(session))
	table.sort(cards, function(a, b)
		return (a.started_at or 0) < (b.started_at or 0)
	end)
	return cards
end

function M.attach(api, ctx)
	function api.focus_relative(id, lane, delta)
		lane = ctx.normalize_lane(lane)
		local session = ctx.state.get_session(lane)
		if not session then
			return false
		end
		local cards = sorted_cards(ctx, session)
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
		return target and api.focus_card(target.id, lane) or false
	end
	function api.reflow(lane)
		lane = ctx.normalize_lane(lane)
		local session = ctx.state.get_session(lane)
		if not session then
			return
		end
		local focused = ctx.current_card_id(session)
		if focused then
			session.active_flow_card_id = focused
		end
		local active = ctx.card_by_id(session, session.active_flow_card_id)
		if active and not ctx.card_window(active) then
			session.active_flow_card_id = nil
		end
		local stack_index = 1
		local cards = sorted_cards(ctx, session)
		for i = #cards, 1, -1 do
			local card = cards[i]
			local win = ctx.card_window(card)
			if win and vim.api.nvim_win_is_valid(win) then
				ctx.render_card(session, card)
				local config = ctx.card_config(session, card, stack_index)
				pcall(vim.api.nvim_win_set_config, win, config)
				if not (card.kind == "q" and ctx.card_is_expanded(session, card)) then
					pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
				end
				if card.kind == "q" and ctx.card_is_expanded(session, card) then
					ctx.q_compose.open(card, ctx.compose_config(config))
				elseif card.kind == "q" then
					ctx.q_compose.close(card)
				end
				pcall(function()
					vim.wo[win].winbar = ctx.card_winbar(card, lane)
				end)
				ctx.sync_legacy_q(session, card)
				if not ctx.card_is_expanded(session, card) then
					stack_index = stack_index + 1
				end
			else
				if card.kind == "q" then
					ctx.q_compose.close(card)
				end
				card.win = nil
				ctx.sync_legacy_q(session, card)
			end
			local regular_wins = ctx.regular_card_windows(card)
			if #regular_wins > 0 then
				ctx.render_card(session, card, true)
				for _, regular in ipairs(regular_wins) do
					ctx.configure_answer_split(regular)
					pcall(function()
						vim.wo[regular].winbar = ctx.card_winbar(card, lane)
					end)
				end
			end
		end
	end
	function api.refresh_layouts()
		for _, lane in ipairs(ctx.state.lanes()) do
			api.reflow(lane)
		end
	end
	function api.refresh_winbars(lane)
		lane = ctx.normalize_lane(lane)
		local session = ctx.state.get_session(lane)
		if not session then
			return
		end
		for _, card in ipairs(ctx.ensure_card_state(session)) do
			local win = ctx.card_window(card)
			if win and vim.api.nvim_win_is_valid(win) then
				pcall(function()
					vim.wo[win].winbar = ctx.card_winbar(card, lane)
				end)
			end
			for _, regular in ipairs(ctx.regular_card_windows(card)) do
				pcall(function()
					vim.wo[regular].winbar = ctx.card_winbar(card, lane)
				end)
			end
		end
	end
	local function schedule_dismiss_closed_card(winid)
		if not winid then
			return false
		end
		for _, lane in ipairs(ctx.state.lanes()) do
			local session = ctx.state.get_session(lane)
			for _, card in ipairs(session and ctx.ensure_card_state(session) or {}) do
				local closed_card = card.win == winid
				local closed_compose = card.compose_win == winid and not card.compose_closing
				if not card.dismissed and (closed_card or closed_compose) then
					local id = card.id
					vim.schedule(function()
						local current = ctx.card_by_id(ctx.state.get_session(lane), id)
						if current and not current.dismissed then
							api.dismiss_card(id, lane)
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
			api.refresh_layouts()
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
	function api.get_card(id, lane)
		lane = ctx.normalize_lane(lane)
		return ctx.card_by_id(ctx.state.get_session(lane), id)
	end
	function api.open_card(id, lane)
		ensure_autocmds()
		lane = ctx.normalize_lane(lane)
		local session = ctx.state.get_session(lane)
		local card = ctx.card_by_id(session, id)
		if not card then
			return nil
		end
		ctx.render_card(session, card)
		local win = ctx.open_card_window(session, card)
		api.refresh_layouts()
		return win
	end
	function api.toggle_q_answer(lane)
		ensure_autocmds()
		lane = ctx.normalize_lane(lane)
		local session = ctx.state.get_session(lane)
		if not session then
			return false, "No StriderQ card yet"
		end
		local card = ctx.latest_card(session, "q") or ctx.card_by_id(session, session.q_answer_card_id)
		if not card then
			return false, "No StriderQ card yet"
		end
		local win = ctx.card_window(card)
		if ctx.card_is_expanded(session, card) and win then
			session.active_flow_card_id = nil
			ctx.focus_regular_window(card.buf)
			api.refresh_layouts()
			return true
		end
		session.active_flow_card_id = card.id
		ctx.render_card(session, card)
		win = ctx.open_card_window(session, card)
		api.refresh_layouts()
		if win and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_set_current_win(win)
			ctx.q_compose.focus(card)
		end
		return true
	end
	function api.focus_card(id, lane)
		ensure_autocmds()
		lane = ctx.normalize_lane(lane)
		local session = ctx.state.get_session(lane)
		local card = ctx.card_by_id(session, id)
		if not card then
			return false
		end
		if card.kind == "q" then
			return api.open_q_answer_split(card.id, lane) ~= nil
		end
		session.active_flow_card_id = card.id
		ctx.render_card(session, card)
		local win = ctx.open_card_window(session, card)
		api.refresh_layouts()
		if win and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_set_current_win(win)
		end
		return true
	end
	function api.dismiss_card(id, lane)
		lane = ctx.normalize_lane(lane)
		local session = ctx.state.get_session(lane)
		local card = ctx.card_by_id(session, id)
		if not card then
			return false
		end
		card.dismissed = true
		if session.active_flow_card_id == id then
			session.active_flow_card_id = nil
		end
		ctx.close_card_surfaces(card)
		ctx.focus_regular_window(card.buf)
		if card.kind == "q" then
			sync_latest_q(ctx, session)
		end
		api.refresh_layouts()
		return true
	end
	function api.open_card_log(id, lane)
		local card = ctx.card_by_id(ctx.state.get_session(lane), id)
		local log_lane = card and card.worker_lane or lane
		local ok, ui = pcall(require, "strider.ui")
		if ok and ui and ui.open_log then
			ui.open_log({}, log_lane)
			return true
		end
		return false
	end
	function api.clear_completed(opts)
		opts = opts or {}
		local count = 0
		for _, lane in ipairs(ctx.state.lanes()) do
			local session = ctx.state.get_session(lane)
			for _, card in ipairs(session and ctx.ensure_card_state(session) or {}) do
				if not card.dismissed and (opts.all or card.status ~= "running") then
					if api.dismiss_card(card.id, lane) then
						count = count + 1
					end
				end
			end
		end
		return count
	end
	function api.create_card(kind, opts, lane)
		ensure_autocmds()
		lane = ctx.normalize_lane(lane)
		local session = ctx.state.get_session(lane)
		if not session then
			return nil
		end
		opts = opts or {}
		local id = opts.id or ctx.next_card_id(session)
		local seq = opts.seq or tonumber(tostring(id):match("(%d+)$")) or (#ctx.ensure_card_state(session) + 1)
		local card = vim.tbl_extend("force", {
			id = id,
			seq = seq,
			kind = kind,
			lane = lane,
			compose_lane = lane,
			name = opts.name or ctx.card_names.default(kind, seq, opts.prompt),
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
		table.insert(ctx.ensure_card_state(session), card)
		ctx.ensure_card_buffer(card, lane)
		ctx.sync_legacy_q(session, card)
		return card.id
	end
	function api.update_card(id, fields, lane)
		lane = ctx.normalize_lane(lane)
		local session = ctx.state.get_session(lane)
		local card = ctx.card_by_id(session, id)
		if not card then
			return nil
		end
		for key, value in pairs(fields or {}) do
			card[key] = value
		end
		ctx.render_card(session, card)
		ctx.sync_legacy_q(session, card)
		api.reflow(lane)
		return card
	end

	ctx.ensure_autocmds = ensure_autocmds
end

return M
