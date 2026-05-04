local context = require("strider.context")
local comments = require("strider.review.comments")
local questions = require("strider.review.questions")
local plan_helpers = require("strider.review.plan")
local render = require("strider.review.render")
local state = require("strider.state")
local ui = require("strider.ui")

local M = {}

local REVIEW_LANE = "review"

local function review_session()
	return state.get_session(REVIEW_LANE)
end

local function active_review()
	local session = review_session()
	if not session then
		return nil
	end
	local review = session.review
	if review and review.active then
		return review
	end
end

local function current_item(review)
	review = review or active_review()
	if not review then
		return nil
	end
	if not review.current_index or review.current_index < 1 then
		return nil
	end
	return review.items[review.current_index]
end

local function review_state()
	local session = review_session()
	return session and session.review or nil
end

-- Deduplicates render calls within the same event loop tick. Multiple
-- mutations in a single synchronous chain (e.g. focus_item + ingest_plan)
-- only rebuild the sidebar once.
local render_scheduled = false

function M.render()
	local review = review_state()
	if not review then
		ui.hide_review()
		return false
	end
	if render_scheduled then
		return true
	end
	render_scheduled = true
	vim.schedule(function()
		render_scheduled = false
		local r = review_state()
		if not r then
			ui.hide_review()
			return
		end
		local session = review_session()
		ui.set_review_lines(render.panel_lines(r, { cwd = session and session.cwd }))
	end)
	return true
end

local function question_deps()
	return {
		active_review = active_review,
		current_item = current_item,
		render = M.render,
		review_state = review_state,
	}
end

local function review_deps()
	local deps = question_deps()
	deps.focus_item = M.focus_item
	deps.review_lane = REVIEW_LANE
	deps.review_session = review_session
	return deps
end

function M.capture_assistant_text(text, opts)
	return questions.capture_assistant_text(text, opts, question_deps())
end

function M.has_active_review()
	return active_review() ~= nil
end

function M.is_awaiting_summary()
	local review = review_state()
	return review ~= nil and review.awaiting_summary == true
end

function M.current_item()
	return current_item(active_review())
end

function M.focus_item(item)
	if not item then
		return false
	end
	ui.jump_to_file(item.path, item.startLine)
	ui.highlight_range(item.path, item.startLine, item.endLine, REVIEW_LANE)
	-- Swap inline annotations: clear prior stop's, render this one's.
	-- Each step clears the annotations of the previous step (by design).
	-- Any pending ranged-question answer also gets cleared — the user
	-- moved on.
	ui.clear_stop_annotations()
	local review = review_state()
	if review then
		review.pending_question = nil
	end
	ui.set_stop_annotations(item)
	M.render()
	return true
end

function M.begin_ranged_question(range, text)
	return questions.begin_ranged_question(range, text, question_deps())
end

function M.begin_item_question(text)
	return questions.begin_item_question(text, question_deps())
end

function M.capture_ranged_question_answer(text, opts)
	return questions.capture_ranged_question_answer(text, opts, question_deps())
end

-- Deterministic selection/diff plans and model stop normalization live in review.plan.
function M.plan_from_range(path, start_line, end_line)
	local session = review_session()
	local cwd = session and session.cwd or vim.fn.getcwd()
	return plan_helpers.plan_from_range(cwd, path, start_line, end_line)
end

function M.plan_from_diff(cwd, base)
	return plan_helpers.plan_from_diff(cwd, base)
end

function M._ranges_cover(target_ranges, stop_ranges)
	return plan_helpers.ranges_cover(target_ranges, stop_ranges)
end

-- Start a free-scope review in "planning" state. The plan itself arrives
-- later via M.ingest_plan (driven by the strider_plan tool). The sidebar
-- and status widget update immediately so the user sees activity from
-- keystroke zero.
function M.start_planning(focus, opts)
	opts = opts or {}
	local session = review_session()
	if not session then
		ui.notify("No active Strider session", vim.log.levels.WARN)
		return false
	end

	ui.clear_comment_markers()
	ui.clear_stop_annotations()
	session.review = {
		active = true,
		accepted_stops = {},
		awaiting_summary = false,
		comments = {},
		current_index = 0,
		focus = focus,
		goal = focus,
		items = {},
		planned = true,
		plan_message = nil,
		planning = true,
		scope = nil,
		source = opts.source or "review",
		start_context = opts.start_context,
		context_source = opts.context_source,
		summary = nil,
		title = opts.title or "Strider review",
	}
	-- Optimistically seed the status widget so the user sees "planning..."
	-- immediately, before the pi extension's setWidget roundtrip lands.
	state.set_widget({ "Planning review..." }, REVIEW_LANE)
	state.set_status("strider", "plan active", REVIEW_LANE)
	ui.show_review()
	M.render()
	return true
end

-- Ingest a model-produced plan and activate its first stop.
function M.ingest_plan(args)
	local review = active_review()
	if not review or not review.planning then
		return nil
	end
	local session = review_session()
	if not session then
		return nil
	end
	args = args or {}

	local stops = {}
	for _, raw in ipairs(args.stops or {}) do
		local stop = plan_helpers.normalize_stop(session.cwd, raw)
		if stop then
			table.insert(stops, stop)
		end
	end
	if #stops == 0 then
		return nil
	end

	review.scope = args.scope or "free"
	review.base = args.base
	review.items = stops
	review.planning = false
	review.coverage_ok = true -- §5 coverage validation lands in a later step

	local has_msg0 = review.plan_message and review.plan_message ~= ""
	if has_msg0 then
		review.current_index = 0
		ui.clear_stop_annotations()
		M.render()
	else
		review.current_index = 1
		M.focus_item(stops[1])
		M.render()
	end
	return has_msg0 and nil or stops[1]
end

-- Append more stops to an active free-scope review. No-op for
-- selection/diff. The model calls this via the strider_append_stops tool
-- when it discovers an additional area to visit mid-review.
function M.ingest_append_stops(args)
	local review = active_review()
	if not review or not review.planned or review.planning then
		return 0
	end
	if review.scope ~= "free" then
		return 0
	end
	local session = review_session()
	if not session then
		return 0
	end
	args = args or {}

	local added = 0
	for _, raw in ipairs(args.stops or {}) do
		local stop = plan_helpers.normalize_stop(session.cwd, raw)
		if stop then
			table.insert(review.items, stop)
			added = added + 1
		end
	end
	if added > 0 then
		M.render()
	end
	return added
end

function M.is_planning()
	local review = active_review()
	return review ~= nil and review.planning == true
end

-- Entry point for reviews whose plan is constructed deterministically on
-- the Lua side (selection, and eventually diff). Items come from
-- plan_from_* helpers and carry the `why` field.
function M.start_planned(scope, opts)
	opts = opts or {}
	local session = review_session()
	if not session then
		ui.notify("No active Strider session", vim.log.levels.WARN)
		return nil
	end

	local plan
	if scope == "selection" then
		local path = opts.path or context.current_buffer_path()
		if not path or not opts.startLine or not opts.endLine then
			return nil
		end
		plan = M.plan_from_range(path, opts.startLine, opts.endLine)
	end

	if not plan or #plan.stops == 0 then
		return nil
	end

	-- `summary` is the presentation alias for `why` that panel_lines shows
	-- as "Synopsis:". Plan-from-range helpers set `why`; mirror it here so
	-- the sidebar renders a non-empty synopsis for selection stops.
	for _, stop in ipairs(plan.stops) do
		stop.summary = stop.why
	end

	ui.clear_comment_markers()
	ui.clear_stop_annotations()
	local source = opts.resolved_source or scope
	session.review = {
		active = true,
		accepted_stops = {},
		awaiting_summary = false,
		base = opts.resolved_base or plan.base,
		comments = {},
		coverage_ok = plan.coverage_ok,
		current_index = 1,
		focus = opts.focus,
		goal = opts.focus,
		items = plan.stops,
		planned = true,
		plan_message = nil,
		scope = plan.scope,
		source = source,
		start_context = opts.start_context,
		context_source = opts.context_source,
		summary = nil,
		title = opts.title or ("Strider review: " .. source),
	}
	ui.show_review()
	M.focus_item(plan.stops[1])
	return plan.stops[1]
end

function M.build_prompt(focus)
	local review = active_review()
	local item = current_item(review)
	if not review or not item then
		return nil
	end

	local user_focus = focus or review.focus or review.goal or "Walk me through this review item."
	local lines = {
		review.goal and ("Review goal: " .. review.goal) or nil,
		string.format("Review source: %s", review.source),
		string.format("Review stop: %d of %d", review.current_index, #review.items),
		string.format("File: %s", item.path),
		string.format("Lines: %d-%d", item.startLine, item.endLine),
		item.title and ("Title: " .. item.title) or nil,
		item.why and ("Why this stop: " .. item.why) or nil,
		"Stay focused on this stop.",
		"Keep the explanation compact and low-chrome.",
		"Avoid generic sections like 'Requirements' or 'Overview' unless the user explicitly asks for them.",
		"You may inspect nearby code if needed, but keep the explanation centered on this range.",
		item.excerpt and "<REVIEW_EXCERPT>\n" .. item.excerpt .. "\n</REVIEW_EXCERPT>" or nil,
		"User focus: " .. user_focus,
	}
	return table.concat(
		vim.tbl_filter(function(line)
			return line ~= nil and line ~= ""
		end, lines),
		"\n"
	)
end

function M.capture_plan_message(text)
	local review = active_review()
	if not review then
		return false
	end
	review.plan_message = text
	-- If ingest_plan already ran and landed on stop 1, navigate back to
	-- message 0 so the user sees the plan prose first.
	if not review.planning and (review.current_index or 0) > 0 then
		review.current_index = 0
		ui.clear_stop_annotations()
	end
	M.render()
	return true
end

function M.has_plan_message()
	local review = active_review()
	return review ~= nil and review.plan_message ~= nil and review.plan_message ~= ""
end

function M.advance(direction)
	local review = active_review()
	if not review then
		return nil, false, false
	end

	local min_index = M.has_plan_message() and 0 or 1
	local next_index = (review.current_index or 0) + direction
	if next_index < min_index then
		return nil, false, false -- before start; did not move
	end
	if next_index > #review.items then
		return nil, true, false -- past end; did not move
	end

	local previous = current_item(review)
	if previous and (previous.status == nil or previous.status == "pending") then
		previous.status = "reviewed"
	end
	review.current_index = next_index

	-- Index 0 is message 0 (no file/range). Clear annotations and re-render
	-- instead of calling focus_item.
	if next_index == 0 then
		ui.clear_stop_annotations()
		M.render()
		return nil, false, true -- moved to message 0
	end

	local item = current_item(review)
	M.focus_item(item)
	return item, false, true -- moved to a regular stop
end

function M.accept_current_stop(opts)
	opts = opts or {}
	local review = active_review()
	local item = current_item(review)
	if not review or not item then
		if not opts.quiet then
			ui.notify("No active review stop to accept", vim.log.levels.WARN)
		end
		return false
	end

	item.status = "accepted"
	review.accepted_stops = review.accepted_stops or {}
	review.accepted_stops[item.id] = true
	state.record_review_acceptance(item, REVIEW_LANE)
	M.render()
	if not opts.quiet then
		ui.notify("Accepted review stop", vim.log.levels.INFO)
	end
	return true
end

function M.finish()
	local review = active_review()
	if not review then
		return nil
	end

	local pending_comments = comments.unresolved(review)
	review.active = false
	ui.clear_stop_annotations()
	if #pending_comments == 0 then
		review.awaiting_summary = false
		review.pending_comments = nil
		review.summary = "Review complete. No unresolved comments."
		M.render()
		return nil
	end

	local lines = {
		string.format("Review source: %s", review.source),
		"The interactive review is complete.",
		"These unresolved review comments should now feed back into the agent as follow-up context.",
		"Please summarize the concerns, answer any implied open questions, and propose the smallest useful next patches or work items.",
		"<REVIEW_COMMENTS>",
	}
	local rendered_comments = comments.lines(pending_comments)
	vim.list_extend(lines, rendered_comments)
	table.insert(lines, "</REVIEW_COMMENTS>")
	review.awaiting_summary = true
	review.pending_comments = rendered_comments
	review.summary = nil
	M.render()
	return table.concat(lines, "\n")
end

function M.pending_comment_lines()
	return comments.pending_comment_lines(review_deps())
end

function M.summary_text()
	local review = review_state()
	return review and review.summary or nil
end

function M.summary_forwarded()
	local review = review_state()
	return review ~= nil and review.summary_forwarded == true
end

function M.begin_summary_confirmation(summary)
	local review = review_state()
	if not review then
		return false
	end
	local text = vim.trim(summary or "")
	if text ~= "" then
		review.summary = text
	end
	review.awaiting_summary = false
	review.summary_forwarded = false
	review.summary_confirming = true
	M.render()
	return true
end

function M.end_summary_confirmation()
	local review = review_state()
	if not review then
		return false
	end
	review.summary_confirming = false
	M.render()
	return true
end

function M.mark_summary_forwarded(summary)
	return comments.mark_summary_forwarded(summary, review_deps())
end

function M.add_comment(text, range)
	return comments.add_comment(text, range, review_deps())
end

function M.open_comment_editor(range, on_submit, opts)
	return comments.open_comment_editor(range, on_submit, opts, review_deps())
end

function M.comment_picker()
	return comments.comment_picker(review_deps())
end

function M.item_picker()
	return comments.item_picker(review_deps())
end

return M
