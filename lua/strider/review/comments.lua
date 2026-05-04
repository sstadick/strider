local picker = require("strider.picker")
local render = require("strider.review.render")
local ui = require("strider.ui")

local M = {}

function M.lines(comments)
	local lines = {}
	for index, comment in ipairs(comments or {}) do
		table.insert(lines, string.format("%d. %s:%d-%d", index, comment.path, comment.startLine, comment.endLine))
		table.insert(lines, comment.text)
	end
	return lines
end

function M.unresolved(review)
	local items = {}
	for _, comment in ipairs((review and review.comments) or {}) do
		if not comment.resolved then
			table.insert(items, comment)
		end
	end
	return items
end

function M.pending_comment_lines(deps)
	local review = deps.review_state()
	if not review or not review.pending_comments then
		return nil
	end
	return review.pending_comments
end

function M.mark_summary_forwarded(summary, deps)
	local review = deps.review_state()
	if not review then
		return false
	end
	local text = vim.trim(summary or "")
	if text ~= "" then
		review.summary = text
	end
	review.awaiting_summary = false
	review.summary_confirming = false
	review.summary_forwarded = true
	deps.render()
	return true
end

function M.add_comment(text, range, deps)
	local review = deps.active_review()
	local item = deps.current_item(review)
	if not review or not item then
		ui.notify("No active review item to comment on", vim.log.levels.WARN)
		return nil
	end

	local comment = {
		id = string.format("comment-%d", #review.comments + 1),
		itemId = item.id,
		path = item.path,
		startLine = range and range.startLine or item.startLine,
		endLine = range and range.endLine or item.endLine,
		text = text,
		resolved = false,
		source = "local",
		externalId = nil,
	}

	table.insert(review.comments, comment)
	item.status = "commented"
	ui.add_comment_marker(comment.path, comment.startLine)
	deps.render()
	return comment
end

function M.open_comment_editor(range, on_submit, opts, deps)
	opts = opts or {}
	ui.open_comment_editor(function(text)
		local comment = M.add_comment(text, range, deps)
		if comment and on_submit then
			on_submit(comment)
		end
	end, {
		prefill = opts.prefill,
		hint_lines = opts.hint_lines,
	})
end

function M.comment_picker(deps)
	local session = deps.review_session()
	if not session then
		ui.notify("No active Strider session", vim.log.levels.WARN)
		return false
	end
	local review = deps.active_review() or session.review
	local comments = (review and review.comments) or {}
	if #comments == 0 then
		ui.notify("No Strider review comments recorded", vim.log.levels.WARN)
		return false
	end

	local items = {}
	for index, comment in ipairs(comments) do
		table.insert(items, {
			label = string.format(
				"%d. %s:%d-%d %s",
				index,
				vim.fn.fnamemodify(comment.path, ":."),
				comment.startLine,
				comment.endLine,
				comment.text
			),
			value = comment,
		})
	end

	return picker.select("Strider Comments", items, function(entry)
		local comment = entry.value
		ui.jump_to_file(comment.path, comment.startLine)
		ui.highlight_range(comment.path, comment.startLine, comment.endLine, deps.review_lane)
	end)
end

function M.item_picker(deps)
	local session = deps.review_session()
	local review = deps.active_review() or (session and session.review)
	if not review then
		ui.notify("No Strider review session available", vim.log.levels.WARN)
		return false
	end

	local items = {}
	if review.plan_message and review.plan_message ~= "" then
		table.insert(items, { label = "[0] Synopsis", value = { index = 0, item = nil } })
	end
	for index, item in ipairs(review.items) do
		table.insert(items, {
			label = render.item_label(item, index, #review.items),
			value = { index = index, item = item },
		})
	end

	return picker.select("Strider Review Items", items, function(entry)
		review.current_index = entry.value.index
		if entry.value.index == 0 then
			ui.clear_stop_annotations()
			deps.render()
		else
			deps.focus_item(entry.value.item)
		end
	end)
end

return M
