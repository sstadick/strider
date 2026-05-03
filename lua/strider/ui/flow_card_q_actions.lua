local M = {}

function M.attach(api, ctx)
	local function q_card_count(session)
		local count = 0
		for _, card in ipairs(ctx.ensure_card_state(session)) do
			if card.kind == "q" then
				count = count + 1
			end
		end
		return count
	end
	local function start_q_turn(card, prompt, opts)
		opts = opts or {}
		ctx.q_compose.clear(card)
		ctx.q_cards.start_turn(card, prompt)
		card.title = "StriderQ"
		if not opts.preserve_name then
			card.name = ctx.card_names.default("q", card.seq, prompt)
		end
		return card
	end
	local function create_q_card(prompt, lane, session, opts)
		opts = opts or {}
		local started = vim.uv.hrtime()
		local seq = opts.seq or (q_card_count(session) + 1)
		local id = api.create_card("q", {
			title = "StriderQ",
			prompt = prompt or "",
			operation = "q",
			started_at = started,
			seq = seq,
			turns = { { prompt = prompt or "", answer_text = "", status = "running", started_at = started } },
			current_turn_index = 1,
			buffer_name = q_card_count(session) == 0 and ctx.q_cards.answer_name(lane) or nil,
			model_label = opts.model_label,
			worker_lane = opts.worker_lane,
		}, lane)
		local card = ctx.card_by_id(session, id)
		session.q_answer_card_id = id
		ctx.sync_legacy_q(session, card)
		return card
	end
	local function ensure_q_card(prompt, lane, opts)
		opts = opts or {}
		lane = ctx.normalize_lane(lane)
		local session = ctx.state.get_session(lane)
		if not session then
			return nil
		end
		local card = opts.card_id and ctx.card_by_id(session, opts.card_id) or nil
		if not card and not opts.new then
			card = ctx.card_by_id(session, session.q_answer_card_id)
		end
		if not card then
			return create_q_card(prompt, lane, session, opts)
		end
		if opts.worker_lane then
			card.worker_lane = opts.worker_lane
		end
		if opts.model_label then
			card.model_label = opts.model_label
		end
		session.q_answer_card_id = card.id
		start_q_turn(card, prompt, opts)
		ctx.sync_legacy_q(session, card)
		return card
	end
	function api.ensure_q_answer_buffer(lane)
		lane = ctx.normalize_lane(lane)
		local session = ctx.state.get_session(lane)
		if not session then
			return nil
		end
		local card = ctx.card_by_id(session, session.q_answer_card_id) or ensure_q_card(session.q_answer_prompt, lane)
		if not card then
			return nil
		end
		local buf = ctx.ensure_card_buffer(card, lane)
		ctx.sync_legacy_q(session, card)
		return buf
	end
	function api.create_q_answer(prompt, lane, opts)
		ctx.ensure_autocmds()
		lane = ctx.normalize_lane(lane)
		local session = ctx.state.get_session(lane)
		if not session then
			return nil
		end
		local card = ensure_q_card(prompt, lane, opts)
		if not card then
			return nil
		end
		ctx.render_card(session, card)
		return card.id
	end
	function api.open_q_answer(prompt, lane, opts)
		ctx.ensure_autocmds()
		lane = ctx.normalize_lane(lane)
		local session = ctx.state.get_session(lane)
		if not session then
			return nil
		end
		local card = ensure_q_card(prompt, lane, opts)
		if not card then
			return nil
		end
		ctx.render_card(session, card)
		ctx.open_card_window(session, card)
		api.refresh_layouts()
		return card.id
	end
	function api.open_q_answer_split(id, lane)
		ctx.ensure_autocmds()
		lane = ctx.normalize_lane(lane)
		local session = ctx.state.get_session(lane)
		if not session then
			return nil
		end
		local card = ctx.card_by_id(session, id) or ctx.latest_card(session, "q")
		if not card then
			return nil
		end
		local buf = ctx.ensure_card_buffer(card, lane)
		ctx.render_card(session, card, true)
		local win = ctx.regular_card_windows(card)[1]
		if win and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_set_current_win(win)
		else
			vim.cmd("botright vsplit")
			win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(win, buf)
			local width = math.min(math.max(math.floor(vim.o.columns * 0.38), 44), 82)
			pcall(vim.api.nvim_win_set_width, win, width)
		end
		ctx.configure_answer_split(win)
		pcall(function()
			vim.wo[win].winbar = ctx.card_winbar(card, lane)
		end)
		pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
		return win
	end
	local function q_card_for_update(session, card_id)
		return ctx.card_by_id(session, card_id) or ctx.card_by_id(session, session.q_answer_card_id)
	end
	function api.update_q_answer(text, lane, card_id)
		lane = ctx.normalize_lane(lane)
		local session = ctx.state.get_session(lane)
		if not session then
			return
		end
		local card = q_card_for_update(session, card_id)
		if not card then
			return
		end
		ctx.q_cards.update_turn(card, text)
		ctx.render_card(session, card)
		ctx.sync_legacy_q(session, card)
		api.reflow(lane)
	end
	function api.finish_q_answer(text, status, lane, card_id)
		lane = ctx.normalize_lane(lane)
		local session = ctx.state.get_session(lane)
		if not session then
			return
		end
		local card = q_card_for_update(session, card_id)
		if not card then
			return
		end
		ctx.q_cards.finish_turn(card, text, status or "success")
		ctx.render_card(session, card)
		ctx.sync_legacy_q(session, card)
		api.reflow(lane)
	end
	function api.refresh_q_answer_winbar(lane)
		api.refresh_winbars(lane)
	end
	function api.refresh_q_answer_layouts()
		api.refresh_layouts()
	end
end

return M
