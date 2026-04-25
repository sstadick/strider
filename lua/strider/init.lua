local review = require("strider.review")
local rpc = require("strider.rpc")
local search = require("strider.search")
local state = require("strider.state")
local status = require("strider.status")
local ui = require("strider.ui")

local M = {}

local MAIN_LANE = "main"
local FLOW_LANE = "flow"
local REVIEW_LANE = "review"

-- Cached CWD + hrtime to short-circuit ensure_backend's per-lane cwd check.
-- CWD changes are user-initiated and rare; avoid calling getcwd() + comparing
-- every lane's session on every send().
local cached_cwd = nil
local cached_cwd_ns = 0
local CWD_CACHE_NS = 500e6  -- 500ms in nanoseconds

local function current_cwd()
  local now = vim.uv.hrtime()
  if cached_cwd and (now - cached_cwd_ns) < CWD_CACHE_NS then
    return cached_cwd
  end
  cached_cwd = vim.fn.getcwd()
  cached_cwd_ns = now
  return cached_cwd
end

local function invalidate_cwd_cache()
  cached_cwd = nil
end

local function ensure_backend(lane)
  lane = state.normalize_lane(lane)
  local cwd = current_cwd()
  for _, session_lane in ipairs(state.lanes()) do
    local session = state.get_session(session_lane)
    if session and session.cwd ~= cwd then
      rpc.stop(session_lane)
      state.clear_session(session_lane)
    end
  end
  return rpc.start(cwd, lane)
end

local function ensure_session(lane)
  return state.ensure_session(lane, current_cwd())
end

local function activity_title(operation)
  local titles = {
    patch = "Strider patch running...",
    plan = "Strider planning review...",
    q = "Strider Q running...",
    review = "Strider review running...",
    search = "Strider search running...",
    prompt = "Strider prompt running...",
  }
  return titles[operation] or "Strider running..."
end

local function activity_target(operation, lane)
  if lane == REVIEW_LANE and (operation == "review" or operation == "plan")
      and (review.has_active_review() or review.is_awaiting_summary()) then
    return "review"
  end
  return "log"
end

local function lane_title(lane)
  if lane == FLOW_LANE then
    return "Strider flow"
  end
  if lane == REVIEW_LANE then
    return "Strider review"
  end
  return "Strider chat"
end

local function warn_if_lane_busy(lane)
  lane = state.normalize_lane(lane)
  local pending = state.peek_pending_request(lane)
  if not pending then
    return false
  end
  local suffix = pending.operation and string.format(" (%s)", pending.operation) or ""
  ui.notify(string.format("%s is already running%s; wait for it to finish.", lane_title(lane), suffix), vim.log.levels.WARN)
  return true
end

local function send(command, user_text, opts)
  opts = opts or {}
  local lane = state.normalize_lane(opts.lane)
  if warn_if_lane_busy(lane) then
    return false
  end
  if not ensure_backend(lane) then
    return false
  end
  if opts.open_log then
    -- Don't steal focus from whatever the user is currently doing (e.g.
    -- composing in strider://compose). If the log isn't visible yet,
    -- opening it should be silent.
    ui.open_log({ preserve_focus = true }, lane)
  end
  local operation = opts.operation or nil
  state.clear_error(lane)
  state.set_pending_request(operation, opts.metadata, lane)
  if operation then
    ui.start_activity(activity_title(operation), activity_target(operation, lane), operation, lane)
  end
  ui.refresh_compose_winbar(lane)
  ui.refresh_compose_hint()
  local ok = rpc.send_prompt(command, lane)
  if not ok then
    state.set_pending_request(nil, nil, lane)
    ui.finish_activity("Strider request failed to start", "error", lane)
    ui.refresh_compose_hint()
    return false
  end
  if user_text and user_text ~= "" then
    ui.append_block("user", user_text, lane)
  end
  if opts.debug_prompt and opts.debug_prompt ~= "" then
    ui.append_block("review-prompt", opts.debug_prompt, lane)
  end
  return true
end

local function trimmed(text)
  return vim.trim(text or "")
end

local function current_buffer_path()
  local path = vim.api.nvim_buf_get_name(0)
  return path ~= "" and path or nil
end

local function range_from_opts(opts)
  if not opts or tonumber(opts.range or 0) == 0 then
    return nil
  end
  local path = current_buffer_path()
  if not path then
    return nil
  end
  return {
    path = path,
    startLine = tonumber(opts.line1) or 1,
    endLine = tonumber(opts.line2) or tonumber(opts.line1) or 1,
  }
end

local function display_path(path)
  local cwd = current_cwd()
  if path and cwd and vim.startswith(path, cwd .. "/") then
    return path:sub(#cwd + 2)
  end
  return path
end

local function range_pointer(range)
  if not range then
    return nil
  end
  return string.format("%s:%d-%d", display_path(range.path), range.startLine, range.endLine)
end

local function chat_prefill(prompt, range)
  local parts = {}
  local pointer = range_pointer(range)
  local text = trimmed(prompt)
  if pointer then
    table.insert(parts, pointer)
  end
  if text ~= "" then
    table.insert(parts, text)
  end
  return table.concat(parts, "\n\n")
end

local function read_excerpt(path, start_line, end_line)
  local buf = vim.fn.bufnr(path)
  if buf > 0 and vim.api.nvim_buf_is_valid(buf) then
    return table.concat(vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false), "\n")
  end
  local all = vim.fn.readfile(path)
  local lines = {}
  for line = start_line, math.min(end_line, #all) do
    table.insert(lines, all[line])
  end
  return table.concat(lines, "\n")
end

local function send_review_prompt(prompt, label, opts)
  opts = opts or {}
  local open_log = opts.open_log
  if open_log == nil then
    open_log = true
  end
  return send("/review " .. prompt, label, {
    lane = REVIEW_LANE,
    operation = "review",
    debug_prompt = prompt,
    open_log = open_log,
  })
end

local function append_review_summary_to_main(summary)
  if not summary or summary == "" then
    return false
  end
  ensure_session(MAIN_LANE)
  local lines = {
    "Review summary",
    "",
    summary,
  }
  local comment_lines = review.pending_comment_lines()
  if comment_lines and #comment_lines > 0 then
    table.insert(lines, "")
    table.insert(lines, "Review comments")
    table.insert(lines, "")
    vim.list_extend(lines, comment_lines)
  end
  ui.append_block("assistant", table.concat(lines, "\n"), MAIN_LANE)
  return true
end

function M.complete_review_summary(summary)
  summary = trimmed(summary)
  if summary == "" then
    return false
  end
  local forwarded = append_review_summary_to_main(summary)
  if forwarded then
    review.mark_summary_forwarded(summary)
  end
  rpc.stop(REVIEW_LANE)
  return forwarded
end

local function start_selection_review(opts)
  if not ensure_backend(REVIEW_LANE) then
    return false
  end
  if warn_if_lane_busy(REVIEW_LANE) then
    return false
  end
  local item = review.start_planned("selection", opts)
  if not item then
    ui.notify("No review items found for the selected range", vim.log.levels.WARN)
    return false
  end
  local prompt = review.build_prompt(opts and opts.focus)
  if not prompt then
    return false
  end
  local label = opts and opts.focus ~= "" and opts.focus or "Review selection"
  return send_review_prompt(prompt, label, { open_log = false })
end

local function start_free_review(focus)
  local text = trimmed(focus)
  if text == "" then
    ui.notify("StriderReview requires input", vim.log.levels.WARN)
    return false
  end
  if not ensure_backend(REVIEW_LANE) then
    return false
  end
  if warn_if_lane_busy(REVIEW_LANE) then
    return false
  end
  if not review.start_planning(text) then
    return false
  end
  return send("/plan " .. text, text, {
    lane = REVIEW_LANE,
    operation = "plan",
    debug_prompt = text,
    open_log = false,
  })
end

-- Called from rpc.lua after a /plan turn finishes and a plan has been
-- ingested. Dispatches the first /review for stop 1 so the model's next
-- turn explains the first stop instead of idling.
-- Called from rpc.lua once a plan has been ingested. With pre-computed
-- explanations (smwyg-browser style), focusing stop 1 is sufficient —
-- the explanation is already in `items[1].explanation` and the sidebar
-- renders it. No second model round-trip needed.
function M.dispatch_first_review()
  if not review.has_active_review() then
    return false
  end
  if review.is_planning() then
    return false
  end
  -- `ingest_plan` already navigated to the first visible item (message 0
  -- or stop 1) and rendered the sidebar. Nothing else to do here — this
  -- hook exists so rpc.lua can still signal "plan turn complete" without
  -- hard-coding navigation.
  return true
end

-- Re-dispatch the plan turn if it stalled. Only useful while planning;
-- once a plan has landed, explanations are already pre-computed so
-- there is nothing to retry mid-review.
function M.retry()
  if not review.has_active_review() then
    ui.notify("No active Strider review to retry", vim.log.levels.WARN)
    return false
  end
  if review.is_planning() then
    local session = state.get_session(REVIEW_LANE)
    local goal = session and session.review and session.review.goal
    if not goal or goal == "" then
      ui.notify("Cannot retry plan: review goal is missing", vim.log.levels.WARN)
      return false
    end
    return send("/plan " .. goal, goal, {
      lane = REVIEW_LANE,
      operation = "plan",
      debug_prompt = goal,
      open_log = false,
    })
  end
  ui.notify("Nothing to retry — explanations are pre-computed.", vim.log.levels.INFO)
  return false
end

function M.setup(opts)
  state.setup(opts or {})
end

function M.status()
  ui.show_status(status.lines())
end

-- Cycle the pi thinking level (same semantics as pi's own shift-tab).
-- Dispatched as a pure extension command — no assistant turn, no
-- activity spinner, no change to compose buffer contents. The widget
-- update triggered on the TS side refreshes the `(level)` suffix on
-- the winbar's model line.
function M.cycle_thinking()
  if not ensure_backend(MAIN_LANE) then return end
  rpc.send_prompt(MAIN_LANE, "/thinking")
end

-- :StriderStop — cancel the current in-flight turn via pi's abort RPC.
-- The actual "[error] Turn aborted" block in the log and spinner reset
-- happen when pi emits the final message_end (see handle_message_end's
-- stopReason == "aborted" branch). We just fire the abort and give the
-- user a quick notify so the interval between keypress and message_end
-- doesn't feel like nothing happened.
function M.stop()
  if not state.peek_pending_request(MAIN_LANE) then
    ui.notify("Strider is idle — nothing to stop", vim.log.levels.INFO)
    return
  end
  if rpc.abort(MAIN_LANE) then
    ui.notify("Stopping Strider…", vim.log.levels.INFO)
  end
end

-- Slash-commands that pi routes to our /prompt etc. handlers which DO
-- send a user message to the model — treat these as normal prompt turns
-- (they produce message_end and need pending-request tracking).
local strider_prompt_commands = {
  prompt = true, patch = true, review = true, search = true, plan = true,
}

-- Pure extension commands — run a handler, may open UI, but never
-- dispatch an LLM turn. No pending request, no activity spinner. The
-- list is intentionally conservative; anything not listed that starts
-- with `/` is also treated as a pure command (safer to leave spinner
-- off than leave it hanging).
local function is_prompt_slash(text)
  local name = text:match("^/([%w%-_:]+)")
  return name and strider_prompt_commands[name] or false
end

-- Session-management and built-in commands that are dedicated RPC
-- message types, not extension commands routed through prompt.
local rpc_commands = {
  new     = { type = "new_session" },
  compact = { type = "compact", args_key = "customInstructions" },
  export  = { type = "export_html", args_key = "outputPath" },
  resume  = { type = "switch_session", args_key = "sessionPath" },
}

-- Aliases: common short-hands that map to the canonical command name
-- used by the extension or RPC layer. Checked early in dispatch_prompt
-- so `/model` works the same as `/models`.
local command_aliases = {
  model = "models",
}

-- /fork needs a multi-step flow: fetch forkable messages, present a
-- picker, then issue the actual fork command with the chosen entryId.
local function fork_flow()
  rpc.send_command("get_fork_messages", {}, nil, function(event)
    if not event.success then
      ui.notify(event.errorMessage or event.error or "Failed to get fork messages", vim.log.levels.ERROR)
      return
    end
    local messages = event.data and event.data.messages or {}
    if #messages == 0 then
      ui.notify("No messages available to fork from", vim.log.levels.WARN)
      return
    end
    local labels = {}
    local by_label = {}
    for i, msg in ipairs(messages) do
      local preview = (msg.text or "(empty)"):sub(1, 120):gsub("%s+", " ")
      local label = string.format("%3d: %s", i, preview)
      table.insert(labels, label)
      by_label[label] = msg.entryId
    end
    vim.ui.select(labels, { prompt = "Fork from message" }, function(choice)
      if not choice then return end
      local entry_id = by_label[choice]
      if not entry_id then return end
      rpc.send_command("fork", { entryId = entry_id })
    end)
  end)
end

local function dispatch_prompt(text)
  -- If the user typed a slash-command (e.g. /models, /tree, /compact),
  -- pass it through verbatim so pi routes it to the matching extension
  -- command instead of wrapping it in /prompt (which would send the
  -- slash-command to the LLM as prose and never fire the handler).
  if text:sub(1, 1) == "/" then
    local name, rest = text:match("^/([%w%-_]+)%s*(.*)$")
    local original_name = name
    name = name and (command_aliases[name] or name)
    -- Rebuild the command text if we resolved an alias so pi sees the
    -- canonical name (e.g. /model → /models).
    if name and name ~= original_name then
      text = "/" .. name .. (rest ~= "" and (" " .. rest) or "")
    end
    if name == "fork" then
      fork_flow()
      return
    end
    local rpc_def = name and rpc_commands[name]
    if rpc_def then
      local extra = {}
      if rpc_def.args_key and rest and rest ~= "" then
        extra[rpc_def.args_key] = rest
      end
      rpc.send_command(rpc_def.type, extra)
      return
    end
    if is_prompt_slash(text) then
      send(text, text, { operation = "prompt", open_log = true })
    else
      -- Pi built-in or extension command (e.g. /models).
      -- Still needs a pending request so streamed response events
      -- aren't silently dropped by the message_update handler.
      send(text, text, { operation = "command", open_log = true })
    end
    return
  end
  send("/prompt " .. text, text, { operation = "prompt", open_log = true })
end

-- Send a user message from the compose buffer. If a request is already
-- in flight, deliver as a steer (mid-turn redirect) instead of a new
-- prompt. Either way the log gets a [user] block so the transcript
-- reads correctly. dispatch_compose is referenced by
-- M.open_compose_for_clarify (defined just below as the clarify-reply
-- entrypoint) before its own definition further down, so it is
-- forward-declared here.
local dispatch_compose

-- Send a clarify reply back through the RPC extension_ui_response
-- channel. Mirrors the shape rpc.lua's send_ui_response uses but lives
-- here so we don't have to expose that helper — we just write the JSON
-- to the same channel via the rpc module.
local function reply_to_clarify(pending, text)
  local session = state.get_session(MAIN_LANE)
  if not session or not session.job_id then return false end
  local body = { type = "extension_ui_response", id = pending.id, value = text }
  local ok, encoded = pcall(vim.json.encode, body)
  if not ok then return false end
  vim.fn.chansend(session.job_id, encoded .. "\n")
  return true
end

local function cancel_clarify(pending)
  local session = state.get_session(MAIN_LANE)
  if not session or not session.job_id then return false end
  local body = { type = "extension_ui_response", id = pending.id, cancelled = true }
  local ok, encoded = pcall(vim.json.encode, body)
  if not ok then return false end
  vim.fn.chansend(session.job_id, encoded .. "\n")
  return true
end

-- Open the compose surfaces so the user can answer a clarify. The
-- compose buffer's send callback is the standard dispatch_compose,
-- which checks pending_clarify first and routes appropriately.
function M.open_compose_for_clarify()
  if not ensure_backend(MAIN_LANE) then return end
  ui.open_log({ preserve_focus = true }, MAIN_LANE)
  ui.open_compose(function(text)
    return dispatch_compose(text)
  end)
end

-- Called from compose's <Esc><Esc> keymap. If a clarify is pending,
-- cancel it. Otherwise fall through so the keymap's usual behavior
-- (stopinsert) runs.
function M.cancel_pending_clarify_if_any()
  local pending = state.consume_pending_clarify(MAIN_LANE)
  if not pending then return false end
  state.set_status("strider-clarify", nil, MAIN_LANE)
  ui.refresh_compose_winbar(MAIN_LANE)
  ui.refresh_compose_hint()
  cancel_clarify(pending)
  ui.append({ "[strider] clarify cancelled" }, MAIN_LANE)
  return true
end

function dispatch_compose(text)
  text = trimmed(text)
  if text == "" then return false end
  if not ensure_backend(MAIN_LANE) then return false end

  -- A pending clarify takes precedence over everything: the model is
  -- explicitly waiting for a reply on the extension_ui_request channel.
  -- Whatever the user types becomes the answer. No tangent, no steer,
  -- no new prompt turn. Clears the badge on success.
  local pending_clarify = state.peek_pending_clarify(MAIN_LANE)
  if pending_clarify then
    state.consume_pending_clarify(MAIN_LANE)
    state.set_status("strider-clarify", nil, MAIN_LANE)
    ui.refresh_compose_winbar(MAIN_LANE)
    ui.refresh_compose_hint()
    ui.append_block("user", text, MAIN_LANE)
    if not reply_to_clarify(pending_clarify, text) then
      ui.notify("Failed to send clarify reply", vim.log.levels.ERROR)
      return false
    end
    return true
  end

  local pending = state.peek_pending_request(MAIN_LANE)
  if pending then
    -- Extension commands (/models, /tree, etc.) are not allowed as steer
    -- messages — pi requires them to come through prompt. Reject with a
    -- helpful notice instead of silently dropping.
    if text:sub(1, 1) == "/" then
      ui.notify("Slash-commands can't be sent mid-turn — wait for the current request to finish.", vim.log.levels.WARN)
      return false
    end
    -- Steer: the pending request stays the same, the model gets the
    -- new message mid-stream. No new operation, no new activity.
    ui.append_block("user", text, MAIN_LANE)
    local ok = rpc.send_steer(MAIN_LANE, text)
    if not ok then
      ui.notify("Steer failed to send", vim.log.levels.ERROR)
      return false
    end
    return true
  end
  -- No pending — start a new prompt turn. send() handles the [user]
  -- append, pending state, and activity spinner.
  dispatch_prompt(text)
  return true
end

function M.chat(prompt, opts)
  prompt = trimmed(prompt)
  local range = range_from_opts(opts)
  local prefill = chat_prefill(prompt, range)

  -- No args + no range keeps the old toggle behavior. Any explicit
  -- prompt or range means "open chat with this draft/context".
  if prefill == "" then
    if ui.chat_is_visible() then
      ui.hide_chat()
      return
    end
  end

  if not ensure_backend(MAIN_LANE) then
    return
  end

  ui.open_log({ preserve_focus = true }, MAIN_LANE)
  ui.ensure_compose_buffer(function(text)
    return dispatch_compose(text)
  end)
  if prefill ~= "" then
    ui.prefill_compose(prefill)
  end
  ui.open_compose(function(text)
    return dispatch_compose(text)
  end)
end

function M.search(prompt)
  prompt = trimmed(prompt)
  if prompt == "" then
    ui.open_prompt_editor("Strider search", function(text)
      M.search(text)
    end, {
      "Structured code search. e.g. \"websocket entrypoints\".",
      "Use :StriderSearches to browse previous searches.",
    })
    return
  end
  send("/search " .. prompt, prompt, {
    lane = FLOW_LANE,
    operation = "search",
    metadata = { prompt = prompt },
  })
end


local function submit_review_request(text, range)
  text = trimmed(text)
  if text == "" then
    return
  end
  if warn_if_lane_busy(REVIEW_LANE) then
    return
  end

  if review.has_active_review() and range then
    review.begin_ranged_question(range, text)
    local prompt = review.build_prompt(text)
    if prompt then send_review_prompt(prompt, text) end
    return
  end

  if review.has_active_review() then
    local prompt = review.build_prompt(text)
    if not prompt then
      ui.notify("No active Strider review item", vim.log.levels.WARN)
      return
    end
    send_review_prompt(prompt, text)
    return
  end

  if range then
    start_selection_review({
      endLine = range.endLine,
      focus = text,
      path = range.path,
      startLine = range.startLine,
    })
    return
  end

  start_free_review(text)
end

function M.review(args, opts)
  local range = range_from_opts(opts)
  local text = trimmed(args)
  local title = "Strider review context"
  local hint_lines

  if review.has_active_review() and range then
    title = "Ask about this selected range"
    hint_lines = {
      "Ask a question about the selected range inside the active review.",
      string.format("Range: %s", range_pointer(range)),
    }
  elseif review.has_active_review() then
    title = "Ask about this review item"
    hint_lines = {
      "Ask a question about the current review item.",
    }
  elseif range then
    hint_lines = {
      "Describe what you want reviewed in this selected range.",
      string.format("Range: %s", range_pointer(range)),
    }
  else
    hint_lines = {
      "Describe what you want reviewed.",
    }
  end

  ui.open_prompt_editor(title, function(input)
    submit_review_request(input, range)
  end, {
    hint_lines = hint_lines,
    prefill = text ~= "" and text or nil,
  })
end

local function dispatch_patch(prompt, range)
  local lines = {
    string.format("Patch target file: %s", range.path),
    string.format("Patch target lines: %d-%d", range.startLine, range.endLine),
    "Only edit this file and stay as close to the selected range as possible.",
    "<PATCH_EXCERPT>",
    read_excerpt(range.path, range.startLine, range.endLine),
    "</PATCH_EXCERPT>",
    "User request: " .. prompt,
  }
  send("/patch " .. table.concat(lines, "\n"), prompt, {
    lane = FLOW_LANE,
    operation = "patch",
  })
end

local function resolve_patch_range(opts)
  local range = range_from_opts(opts)
  local item = review.current_item()
  if not range and item then
    return {
      path = item.path,
      startLine = item.startLine,
      endLine = item.endLine,
    }
  end
  return range
end

local function dispatch_q(prompt, range)
  local message
  if range then
    local lines = {
      string.format("Context file: %s", range.path),
      string.format("Context lines: %d-%d", range.startLine, range.endLine),
      "<Q_EXCERPT>",
      read_excerpt(range.path, range.startLine, range.endLine),
      "</Q_EXCERPT>",
      "Question: " .. prompt,
    }
    message = table.concat(lines, "\n")
  else
    message = prompt
  end
  send("/prompt " .. message, prompt, {
    lane = FLOW_LANE,
    operation = "q",
  })
end

local function submit_q_request(prompt, range)
  prompt = trimmed(prompt)
  if prompt == "" then
    return
  end
  if not ensure_backend(FLOW_LANE) then
    return
  end
  dispatch_q(prompt, range)
end

function M.q(prompt, opts)
  prompt = trimmed(prompt)
  local range = range_from_opts(opts)
  local hint_lines = {
    "Ask a side question without opening chat.",
    "Answers land in StriderLogFlow.",
  }
  local pointer = range_pointer(range)
  if pointer then
    table.insert(hint_lines, string.format("Range: %s", pointer))
  end

  ui.open_prompt_editor("Strider Q", function(text)
    submit_q_request(text, range)
  end, {
    hint_lines = hint_lines,
    prefill = prompt ~= "" and prompt or nil,
  })
end

function M.patch(prompt, opts)
  prompt = trimmed(prompt)

  local range = resolve_patch_range(opts)
  if not range then
    ui.notify("StriderPatch needs a visual range or an active review item", vim.log.levels.WARN)
    return
  end

  ui.open_prompt_editor("Strider patch request", function(text)
    text = trimmed(text)
    if text == "" then
      return
    end
    dispatch_patch(text, range)
  end, {
    hint_lines = {
      string.format("Patch target: %s", range_pointer(range)),
      "Keep changes local to this range.",
    },
    prefill = prompt ~= "" and prompt or nil,
  })
end

function M.next_step(accept_current)
  if not review.has_active_review() then
    ui.notify("No active Strider review session", vim.log.levels.WARN)
    return
  end

  if accept_current then
    review.accept_current_stop({ quiet = true })
  end

  -- Explanations are pre-computed at plan time. Navigation is a pure
  -- index++ that focuses the next stop; no model round-trip.
  local item, finished = review.advance(1)
  if item then
    return
  end

  if finished then
    local prompt = review.finish()
    if prompt then
      local comment_lines = review.pending_comment_lines()
      if comment_lines then
        ui.append_block("review-comments", table.concat(comment_lines, "\n"), REVIEW_LANE)
      end
      send_review_prompt(prompt, "Summarize unresolved review comments", { open_log = false })
    else
      M.complete_review_summary("Review complete. No unresolved comments.")
      ui.notify("Strider review complete", vim.log.levels.INFO)
    end
  end
end

function M.prev_step()
  if not review.has_active_review() then
    ui.notify("No active Strider review session", vim.log.levels.WARN)
    return
  end
  local _item, past_end, moved = review.advance(-1)
  if not moved and not past_end then
    ui.notify("Already at the first review item", vim.log.levels.WARN)
  end
end

function M.comment(text, opts)
  local range = range_from_opts(opts)
  local item = review.current_item()
  local prefill = trimmed(text)

  if not item then
    ui.notify("No active review item to comment on", vim.log.levels.WARN)
    return
  end

  local function log_comment(comment)
    ui.append_block("review", string.format("%s:%d-%d\n%s", comment.path, comment.startLine, comment.endLine, comment.text), REVIEW_LANE)
  end

  review.open_comment_editor(range, log_comment, {
    prefill = prefill ~= "" and prefill or nil,
  })
end

function M.comments()
  review.comment_picker()
end

function M.review_items()
  review.item_picker()
end

function M.searches()
  search.history_picker(FLOW_LANE)
end

function M.flow_log()
  if ui.log_is_visible(FLOW_LANE) then
    ui.hide_log(FLOW_LANE)
    return
  end
  ensure_session(FLOW_LANE)
  ui.open_log({}, FLOW_LANE)
end

function M.review_log()
  if ui.log_is_visible(REVIEW_LANE) then
    ui.hide_log(REVIEW_LANE)
    return
  end
  ensure_session(REVIEW_LANE)
  ui.open_log({}, REVIEW_LANE)
end

return M
