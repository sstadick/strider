local ui = require("strider.ui")

local M = {}

local function item_by_id(review, id)
	if not review or not id then
		return nil
	end
	for _, item in ipairs(review.items or {}) do
		if item.id == id then
			return item
		end
	end
	return nil
end

local function pending_item_followup(review)
	local pending = review and review.pending_item_question
	if not pending then
		return nil, nil
	end
	local item = item_by_id(review, pending.stop_item_id) or review.items[pending.stop_index or 0]
	local followup = item and item.followups and item.followups[pending.followup_index]
	return item, followup
end

local function capture_item_question_answer(review, text, opts, deps)
	local item, followup = pending_item_followup(review)
	if not followup then
		if not opts.partial then
			review.pending_item_question = nil
		end
		return false
	end
	followup.answer = text or ""
	followup.pending = opts.partial == true
	if not opts.partial then
		review.pending_item_question = nil
		if item and (item.status == nil or item.status == "pending") then
			item.status = "reviewed"
		end
	end
	deps.render()
	return true
end

local function mark_current_item_reviewed(review, deps)
	local item = deps.current_item(review)
	if item and (item.status == nil or item.status == "pending") then
		item.status = "reviewed"
	end
end

function M.capture_ranged_question_answer(text, opts, deps)
	opts = opts or {}
	local review = deps.active_review()
	if not review or not review.pending_question then
		return false
	end
	local pq = review.pending_question
	local item = deps.current_item(review)
	if not item or item.id ~= pq.stop_item_id then
		if not opts.partial then
			review.pending_question = nil
		end
		return false
	end

	local synthetic = {
		path = pq.path,
		startLine = pq.startLine,
		endLine = pq.endLine,
		annotations = {
			{
				kind = "block",
				startLine = pq.startLine,
				endLine = pq.endLine,
				text = text,
			},
		},
	}
	ui.clear_stop_annotations()
	ui.set_stop_annotations(item)
	ui.set_stop_annotations(synthetic)

	if not opts.partial then
		review.pending_question = nil
	end
	return true
end

function M.capture_assistant_text(text, opts, deps)
	opts = opts or {}
	local review = deps.review_state()
	if not review then
		return false
	end
	if review.awaiting_summary then
		review.summary = text
		if not opts.partial then
			review.awaiting_summary = false
		end
		deps.render()
		return true
	end
	if review.pending_question then
		return M.capture_ranged_question_answer(text, opts, deps)
	end
	if review.pending_item_question then
		return capture_item_question_answer(review, text, opts, deps)
	end
	if not opts.partial then
		mark_current_item_reviewed(review, deps)
	end
	return true
end

function M.begin_ranged_question(range, text, deps)
	local review = deps.active_review()
	if not review or not range then
		return false
	end
	local item = deps.current_item(review)
	review.pending_question = {
		path = range.path,
		startLine = range.startLine,
		endLine = range.endLine,
		stop_index = review.current_index,
		question = text,
		stop_item_id = item and item.id or nil,
	}
	return true
end

function M.begin_item_question(text, deps)
	local review = deps.active_review()
	local item = deps.current_item(review)
	if not review or not item then
		return false
	end
	item.followups = item.followups or {}
	table.insert(item.followups, {
		answer = "",
		pending = true,
		question = text,
	})
	review.pending_item_question = {
		followup_index = #item.followups,
		stop_index = review.current_index,
		stop_item_id = item.id,
	}
	deps.render()
	return true
end

return M
