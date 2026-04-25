local picker = require("strider.picker")
local review = require("strider.review")
local search = require("strider.search")
local state = require("strider.state")
local ui = require("strider.ui")

local M = {}

local function normalize_lane(lane)
  return state.normalize_lane(lane)
end

local function resolve_lane_and_cwd(arg1, arg2)
  if state.is_lane(arg1) then
    return normalize_lane(arg1), arg2
  end
  return normalize_lane(arg2), arg1
end

local function resolve_lane_and_payload(arg1, arg2)
  if arg2 == nil then
    return "main", arg1
  end
  if state.is_lane(arg1) then
    return normalize_lane(arg1), arg2
  end
  return normalize_lane(arg2), arg1
end

local function command_list()
  local config = state.get_config()
  local cmd = vim.deepcopy(config.pi_cmd)
  local extension = config.extension_path or (config.plugin_root .. "/pi/strider-stepper.ts")
  vim.list_extend(cmd, { "--mode", "rpc", "--extension", extension })
  return cmd
end

local function decode(line)
  local ok, value = pcall(vim.json.decode, line)
  if ok then
    return value
  end
end

-- Build a short inline summary of tool arguments for the log line.
-- Returns nil when nothing interesting to show.
local function quoted(value)
  return type(value) == "string" and string.format("%q", value) or nil
end

local function option_summary(...)
  local parts = {}
  for i = 1, select("#", ...) do
    local option = select(i, ...)
    if option then
      table.insert(parts, option)
    end
  end
  return #parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or ""
end

local function grep_args(args)
  local query = quoted(args.pattern)
  if not query then
    return args.path
  end
  local target = args.path and (" in " .. args.path) or ""
  return query .. target .. option_summary(
    args.glob and ("glob " .. args.glob),
    args.ignoreCase and "ignore-case",
    args.literal and "literal",
    args.context and ("context " .. args.context),
    args.limit and ("limit " .. args.limit)
  )
end

local function find_args(args)
  local query = args.pattern
  if not query then
    return args.path
  end
  local target = args.path and (" in " .. args.path) or ""
  return query .. target .. option_summary(args.limit and ("limit " .. args.limit))
end

local function ls_args(args)
  if not args.path then
    return nil
  end
  return args.path .. option_summary(args.limit and ("limit " .. args.limit))
end

local function format_tool_args(tool_name, args)
  if not args then return nil end
  if tool_name == "grep" then
    return grep_args(args)
  end
  if tool_name == "find" then
    return find_args(args)
  end
  if tool_name == "ls" then
    return ls_args(args)
  end
  if tool_name ~= "subagent" then
    return nil
  end
  local parts = {}
  if args.agent then table.insert(parts, args.agent) end
  if args.task then table.insert(parts, args.task:sub(1, 80)) end
  if #parts == 0 then return nil end
  return table.concat(parts, " ")
end

local summary_tools = {
  grep = true,
  find = true,
  ls = true,
  subagent = true,
}

local summary_verbs = {
  subagent = "Delegated",
}

local function append_tool_summary(tool_name, summary, lane)
  local verb = summary_verbs[tool_name] or "Explored"
  ui.append({ "• " .. verb, string.format("  └ %s %s", tool_name, summary) }, lane)
end

local function append_tool(tool_name, args, lane)
  local summary = summary_tools[tool_name] and format_tool_args(tool_name, args)
  if summary then
    append_tool_summary(tool_name, summary, lane)
    return
  end

  local path = args and args.path
  if path then
    if tool_name == "read" then
      local start_line = tonumber(args.offset) or 1
      local limit = tonumber(args.limit)
      local range = limit
        and string.format(":%d-%d", start_line, start_line + limit - 1)
        or string.format(":%d", start_line)
      ui.append_tool_line(tool_name, path, range, lane)
      return
    end
    ui.append_tool_line(tool_name, path, nil, lane)
    return
  end

  if tool_name == "bash" and args and args.command then
    ui.append({ string.format("• Ran command"), string.format("  └ %s", args.command) }, lane)
    return
  end

  summary = format_tool_args(tool_name, args)
  if summary then
    append_tool_summary(tool_name, summary, lane)
    return
  end

  ui.append({ string.format("• Ran %s", tool_name) }, lane)
end

local function text_content(message)
  if not message or message.role ~= "assistant" then
    return nil
  end

  local parts = {}
  for _, item in ipairs(message.content or {}) do
    if item.type == "text" and item.text ~= "" then
      table.insert(parts, item.text)
    end
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, "\n")
end

local function strip_strider_footer(text)
  if not text then
    return nil
  end
  local cleaned = text:gsub("\n?<STRIDER_STATUS>.-</STRIDER_STATUS>%s*$", "")
  cleaned = vim.trim(cleaned)
  return cleaned ~= "" and cleaned or text
end

local function is_absolute_path(path)
  return path:match("^/") ~= nil
    or path:match("^%a:[/\\]") ~= nil
    or path:match("^\\\\") ~= nil
end

local function absolute_path(session, path)
  if not session or not path or path == "" then
    return nil
  end
  if is_absolute_path(path) then
    return path
  end
  return vim.fs.joinpath(session.cwd, path)
end

-- Per-request response callbacks keyed by request id. When
-- send_command is given a callback, the id is stashed here;
-- handle_response fires and removes it before the default path.
local response_callbacks = {}

local function handle_response(event, lane)
  -- Fire per-request callback if one was registered.
  local cb = event.id and response_callbacks[event.id]
  if cb then
    response_callbacks[event.id] = nil
    cb(event, lane)
    return
  end

  if event.success then
    -- Raw RPC commands (new_session, compact, export_html, etc.) don't
    -- trigger LLM turns, so no message_end will follow. Consume the
    -- pending request now to clear the activity spinner and unblock the
    -- next send. Prompt-routed extension commands may also use operation
    -- "command"; they get the generic completion label.
    local pending = state.peek_pending_request(lane)
    if pending and pending.operation == "command" then
      state.consume_pending_request(lane)
      local metadata = pending.metadata or {}
      ui.finish_activity(metadata.activity_done or "Strider command complete", "ok", lane)
    end
    return
  end
  -- RPC transport-level error (pi rejected the request shape, backend
  -- isn't running, etc.). Less common than model-level errors — those
  -- arrive on message_end with stopReason="error" (see
  -- handle_message_end). Both paths log into the buffer so the user
  -- always has a record beyond the fleeting notify.
  local cmd = event.command or "unknown"
  local detail = event.errorMessage or event.error
  local reason
  if detail and detail ~= "" then
    reason = string.format("/%s failed: %s", cmd, detail)
  else
    reason = string.format("/%s failed (pi rejected the request)", cmd)
  end
  -- Consume the pending request so the activity spinner actually stops
  -- and the next send isn't blocked.
  local pending = state.peek_pending_request(lane)
  if pending then
    state.consume_pending_request(lane)
  end
  ui.append_block("error", reason, lane)
  state.set_error(reason, lane)
  ui.finish_activity(reason, "error", lane)
  ui.notify(reason, vim.log.levels.ERROR)
end

-- Runtime extension errors: pi emits these when sendUserMessage (or
-- another extension-side call) throws before a turn can start — e.g.
-- "No API key found for <provider>", or a provider returning 400
-- before the stream opens. The preceding `response` event reports
-- success:true because the RPC command itself dispatched cleanly; the
-- failure happens later in the extension's async promise chain.
-- Without a handler here, these silently evaporate and the log just
-- hangs on "Waiting for assistant response...".
local function handle_extension_error(event, lane)
  local reason = event.error or "Strider extension error"
  -- Collapse multi-line reasons to the first non-empty line for the
  -- notify + activity echo; put the full text in the [error] block so
  -- detail isn't lost.
  local first_line = reason
  for line in reason:gmatch("[^\r\n]+") do
    if vim.trim(line) ~= "" then first_line = line; break end
  end
  ui.append_block("error", reason, lane)
  state.set_error(first_line, lane)
  ui.finish_activity(first_line, "error", lane)
  ui.notify(first_line, vim.log.levels.ERROR)
  -- Clear the pending request so the activity spinner actually stops
  -- and the next send doesn't think a turn is still in flight.
  state.consume_pending_request(lane)
end

local function ensure_stream_log(pending, lane)
  if lane ~= "main" then
    return
  end
  if not pending or pending.log_opened or pending.operation == "plan" or pending.operation == "q" then
    return
  end
  pending.log_opened = true
  ui.open_log({ preserve_focus = true }, lane)
end

local function flush_thinking_index(session, pending, content_index, lane)
  if not session then
    return
  end
  session.assistant_thinking = session.assistant_thinking or {}
  local text = session.assistant_thinking[content_index]
  session.assistant_thinking[content_index] = nil
  if not text then
    return
  end
  text = vim.trim(text)
  if text == "" then
    return
  end
  ensure_stream_log(pending, lane)
  ui.finalize_live_block("thinking", text, lane)
end

local function flush_all_thinking(session, pending, lane)
  if not session then
    return
  end
  session.assistant_thinking = session.assistant_thinking or {}
  local indices = {}
  for index, text in pairs(session.assistant_thinking) do
    if text and vim.trim(text) ~= "" then
      table.insert(indices, index)
    end
  end
  table.sort(indices, function(a, b)
    return (tonumber(a) or 0) < (tonumber(b) or 0)
  end)
  for _, index in ipairs(indices) do
    flush_thinking_index(session, pending, index, lane)
  end
end

local function handle_message_update(event, lane)
  local delta = event.assistantMessageEvent
  if not delta then
    return
  end
  local pending = state.peek_pending_request(lane)
  if not pending then
    return
  end
  local session = state.get_session(lane)
  session.assistant_thinking = session.assistant_thinking or {}

  if delta.type == "thinking_start" then
    session.assistant_thinking[delta.contentIndex or 0] = ""
    ui.start_live_block(lane)
    return
  end
  if delta.type == "thinking_delta" then
    local index = delta.contentIndex or 0
    session.assistant_thinking[index] = (session.assistant_thinking[index] or "") .. (delta.delta or "")
    ensure_stream_log(pending, lane)
    ui.update_live_block(session.assistant_thinking[index], lane)
    return
  end
  if delta.type == "thinking_end" then
    local index = delta.contentIndex or 0
    if (not session.assistant_thinking[index] or session.assistant_thinking[index] == "") and delta.content then
      session.assistant_thinking[index] = delta.content
    end
    flush_thinking_index(session, pending, index, lane)
    return
  end
  if delta.type == "done" or delta.type == "error" then
    flush_all_thinking(session, pending, lane)
    return
  end
  if delta.type ~= "text_delta" then
    return
  end
  session.assistant_text = (session.assistant_text or "") .. (delta.delta or "")
  session.message_text = (session.message_text or "") .. (delta.delta or "")

  -- Auto-open the log on the first streamed delta of any answer-producing
  -- operation, without stealing focus. Idempotent: open_log is a no-op
  -- when the log is already visible. One-per-pending guard avoids
  -- reopening a manually-closed log mid-stream.
  ensure_stream_log(pending, lane)
  ui.ensure_live_block(lane)
  ui.update_live_block(session.message_text, lane)

  if pending.operation == "review" then
    review.capture_assistant_text(session.assistant_text, { partial = true })
  end
end

local function has_tool_use(message)
  if not message or message.role ~= "assistant" then
    return false
  end
  for _, item in ipairs(message.content or {}) do
    if item.type == "tool_use" or item.type == "toolCall" then
      return true
    end
  end
  return false
end

local function notify_turn_done(pending, lane)
  if not pending then return end
  local op = pending.operation
  -- Flow-lane operations: always leave a bottom-left completion cue.
  -- The popup-style notify is still skipped when StriderLogFlow is visible,
  -- but the command-line green dot remains so completion is not silent.
  if state.is_flow_operation(op) then
    local messages = {
      q = "StriderQ answer is ready",
      search = "StriderSearch complete",
      patch = "StriderPatch complete",
    }
    ui.notify_flow_done(messages[op] or "Strider flow complete", {
      notify = not ui.log_is_visible("flow"),
    })
    return
  end
  -- Chat (main lane): notify when StriderLog isn't visible.
  if lane == "main" then
    if ui.log_is_visible("main") then return end
    ui.notify("Strider chat complete", vim.log.levels.INFO)
  end
  -- Review pops up on its own, no notify needed.
end

local function handle_message_end(event, lane)
  local message = event.message
  local text = strip_strider_footer(text_content(message))
  local pending = state.peek_pending_request(lane)
  local session = state.get_session(lane)

  flush_all_thinking(session, pending, lane)
  ui.finalize_live_block(nil, nil, lane)
  session.message_text = nil

  -- Do not consume pending on tool-call turns or user messages.
  -- Only the final text-bearing assistant message should consume it.
  if has_tool_use(message) then
    return
  end
  if not message or message.role ~= "assistant" then
    return
  end

  pending = state.consume_pending_request(lane)
  session.assistant_text = nil
  session.assistant_thinking = {}

  -- Model/provider errors land here: pi emits a final message_end whose
  -- message.stopReason is "error" (or "aborted" for user-canceled
  -- turns), with the human-readable reason in message.errorMessage.
  -- Surface it into the log so the user sees why the turn failed
  -- instead of wondering why nothing streamed back. Short-circuit the
  -- normal plan/search/assistant branches — there's no usable text.
  local stop_reason = message.stopReason
  if stop_reason == "error" or stop_reason == "aborted" then
    local reason = message.errorMessage or (stop_reason == "aborted" and "Turn aborted" or "Model request failed")
    ui.append_block("error", reason, lane)
    state.set_error(reason, lane)
    local level = stop_reason == "aborted" and "cancel" or "error"
    ui.finish_activity(reason, level, lane)
    if stop_reason == "error" then
      ui.notify(reason, vim.log.levels.ERROR)
    end
    return
  end

  -- Plan turns: success depends on whether the plan tool landed a plan,
  -- not on whether the model produced trailing prose. Handle before the
  -- "no text" early return so empty plan-turn replies still dispatch the
  -- first /review.
  if pending and pending.operation == "plan" then
    if text and text ~= "" then
      review.capture_plan_message(text)
      ui.append_block("assistant", text, lane)
    end
    if review.has_active_review() and review.is_planning() then
      ui.notify("Strider could not produce a plan — try rephrasing.", vim.log.levels.ERROR)
      ui.finish_activity("Strider plan failed", "error", lane)
      return
    end
    ui.finish_activity("Strider plan complete", "success", lane)
    vim.schedule(function()
      local ok, mod = pcall(require, "strider")
      if ok and mod and mod.dispatch_first_review then
        mod.dispatch_first_review()
      end
    end)
    return
  end

  if not text then
    ui.finish_activity("Strider request complete (no text)", "success", lane)
    notify_turn_done(pending, lane)
    return
  end

  if pending and pending.operation == "search" then
    local result_set = search.handle_response(text, pending.metadata, lane)
    local summary = search.summary_text(result_set)
    state.set_summary(summary, lane)
    ui.append_block("assistant", summary, lane)
    ui.finish_activity(summary, "success", lane)
    notify_turn_done(pending, lane)
    return
  end

  state.set_summary(text:gsub("\n", " "), lane)
  ui.append_block("assistant", text, lane)
  local completing_review_summary = lane == "review"
    and pending and pending.operation == "review"
    and review.is_awaiting_summary()
  if pending and pending.operation == "review" then
    review.capture_assistant_text(text)
  end

  ui.finish_activity("Strider request complete", "success", lane)
  notify_turn_done(pending, lane)
  if completing_review_summary then
    vim.schedule(function()
      local ok, mod = pcall(require, "strider")
      if ok and mod and mod.complete_review_summary then
        mod.complete_review_summary(text)
      end
    end)
  end
end

local function track_tool_path(session, event)
  local path = absolute_path(session, event.args and event.args.path)
  if path and event.toolCallId then
    session.tool_paths[event.toolCallId] = path
  end
  return path
end

local function finish_tool_path(session, event)
  if not event.toolCallId then
    return nil
  end
  local path = session.tool_paths[event.toolCallId]
  session.tool_paths[event.toolCallId] = nil
  return path
end

local function first_changed_line(event)
  local details = event.result and event.result.details
  return details and tonumber(details.firstChangedLine) or 1
end

local function changed_lines(event)
  local details = event.result and event.result.details
  local start = first_changed_line(event)
  local diff = details and details.diff
  if not diff then
    return { { line = start, kind = "added" } }
  end

  local changes = {}
  local seen = {}
  local anchor = start

  local function add_change(line, kind)
    local target = tonumber(line) or start
    local key = string.format("%s:%d", kind, target)
    if seen[key] then
      return
    end
    seen[key] = true
    table.insert(changes, { line = target, kind = kind })
  end

  for _, line in ipairs(vim.split(diff, "\n", { plain = true })) do
    local added = tonumber(line:match("^%+%s*(%d+)%s"))
    if added then
      anchor = added
      add_change(added, "added")
    else
      local context = tonumber(line:match("^%s+(%d+)%s"))
      if context then
        anchor = context
      else
        local removed = tonumber(line:match("^%-%s*(%d+)%s"))
        if removed then
          add_change(anchor, "removed")
        end
      end
    end
  end

  if #changes == 0 then
    return { { line = start, kind = "added" } }
  end

  table.sort(changes, function(a, b)
    if a.line == b.line then
      return a.kind < b.kind
    end
    return a.line < b.line
  end)
  return changes
end

local function diff_stats(diff)
  local added = 0
  local removed = 0
  for _, line in ipairs(vim.split(diff or "", "\n", { plain = true })) do
    if line:match("^%+") and not line:match("^%+%+%+") then
      added = added + 1
    elseif line:match("^%-") and not line:match("^%-%-%-") then
      removed = removed + 1
    end
  end
  return added, removed
end

local function read_range(event)
  local start = tonumber(event.args and event.args.offset) or 1
  local limit = tonumber(event.args and event.args.limit)
  if not limit then
    local text = event.result and event.result.content and event.result.content[1] and event.result.content[1].text
    local line_count = text and #vim.split(text, "\n", { plain = true }) or 30
    limit = math.min(math.max(line_count, 1), 40)
  end
  return start, start + limit - 1
end

local function handle_tool_start(event, lane)
  local session = state.get_session(lane)
  append_tool(event.toolName, event.args, lane)

  -- Mark the header row so handle_tool_end can insert the result right
  -- after it (instead of appending at the end of the log, which
  -- disconnects headers from results when tools run in parallel).
  ui.mark_tool_header(event.toolCallId, lane)

  -- Cache args for Strider planning tools — tool_execution_end events do not
  -- carry args, so we have to capture them here while they're available.
  if (event.toolName == "strider_plan" or event.toolName == "strider_append_stops")
      and event.toolCallId then
    session.tool_args[event.toolCallId] = event.args
  end

  local path = track_tool_path(session, event)
  if not path then
    return
  end
  state.record_file(path, lane)
  -- Do not auto-jump for model tool reads. Strider review navigation is the
  -- only flow that should move the user's code window mechanically; prompt /
  -- chat tool use should leave the coding pane where it is.
end

local function consume_tool_args(session, event)
  if not event.toolCallId then
    return nil
  end
  local cached = session.tool_args[event.toolCallId]
  session.tool_args[event.toolCallId] = nil
  return cached
end

-- Pull the printable text out of a tool_execution_end result. Pi emits
-- result.content as a list of `{type: "text", text: "..."}` parts; we
-- concatenate their text. Non-text parts (images, structured data) are
-- skipped — we just want what the user should read in the transcript.
local function tool_result_text(event)
  local result = event.result
  if not result or not result.content then return nil end
  local parts = {}
  for _, item in ipairs(result.content) do
    if item.type == "text" and type(item.text) == "string" then
      table.insert(parts, item.text)
    end
  end
  if #parts == 0 then return nil end
  return table.concat(parts, "\n")
end

-- Tools whose textual result is worth showing in the log (vs dropped
-- as noise). edit is deliberately excluded — its inline diff rows below
-- already capture the change, and the raw text result for edit tends
-- to be a redundant "OK" string.
local FENCED_TOOL_OUTPUT = {
  read = true,
  write = true,
}

local COMPACT_TOOL_OUTPUT = {
  bash = {},
  grep = { count_singular = "match", count_plural = "matches" },
  ls = { count_singular = "entry", count_plural = "entries" },
  find = { count_singular = "path", count_plural = "paths" },
}

-- Filename extension → markdown code-fence language tag. Used for
-- `read` / `write` output so the log's markdown+treesitter pipeline
-- syntax-highlights the content. Requires nvim-treesitter parsers for
-- the languages you expect to see. Unmapped extensions fall through
-- to plain muted styling.
local LANG_BY_EXT = {
  lua = "lua",
  ts = "typescript", tsx = "tsx", mts = "typescript", cts = "typescript",
  js = "javascript", jsx = "javascript", mjs = "javascript", cjs = "javascript",
  py = "python", pyi = "python",
  rs = "rust",
  go = "go",
  md = "markdown", markdown = "markdown",
  json = "json",
  yaml = "yaml", yml = "yaml",
  toml = "toml",
  sh = "bash", bash = "bash", zsh = "bash",
  html = "html", htm = "html",
  css = "css", scss = "scss",
  c = "c", h = "c",
  cpp = "cpp", cc = "cpp", hpp = "cpp", hh = "cpp", cxx = "cpp",
  java = "java",
  rb = "ruby",
  sql = "sql",
}

local function language_for_path(path)
  if not path then return nil end
  local ext = path:match("%.([%w]+)$")
  if not ext then return nil end
  return LANG_BY_EXT[ext:lower()]
end

local function handle_tool_end(event, lane)
  local session = state.get_session(lane)

  -- Resolve where to place output: right after this tool's header when
  -- the extmark is still valid, otherwise fall back to normal append.
  local insert_row = ui.pop_tool_insert_row(event.toolCallId, lane)
  local insert_opts = insert_row and { insert_at = insert_row } or {}

  -- Render textual output for tools where seeing the content helps the
  -- user follow along (everything except edit, which renders inline diff
  -- rows below, and Strider's internal planning tools which carry structured
  -- payloads rather than user-facing text). For read/write we pass a
  -- language tag so the content is fenced and treesitter +
  -- render-markdown can syntax-highlight it; bash/grep/find/ls render
  -- as compact transcript rows so markdown-looking output stays inert.
  if FENCED_TOOL_OUTPUT[event.toolName] or COMPACT_TOOL_OUTPUT[event.toolName] then
    local text = tool_result_text(event)
    if text then
      if FENCED_TOOL_OUTPUT[event.toolName] then
        -- Peek the stashed path without consuming — finish_tool_path
        -- below does the actual consume for the edit/highlight flow.
        local stashed = event.toolCallId and session.tool_paths[event.toolCallId] or nil
        ui.append_tool_output(text, language_for_path(stashed), lane, insert_opts)
      else
        ui.append_compact_tool_output(text, COMPACT_TOOL_OUTPUT[event.toolName], lane, insert_opts)
      end
    end
  end

  -- Strider planning tools carry their payload in args captured at start time.
  if event.toolName == "strider_plan" then
    local args = consume_tool_args(session, event) or {}
    -- Capture any streamed prose as the plan message BEFORE ingest_plan so
    -- ingest_plan can route to message 0.  handle_message_end skips the
    -- capture when the message contains tool_use (which it always does here),
    -- so this is the only place the plan message is reliably captured.
    local raw_text = session.assistant_text
    if raw_text and raw_text ~= "" then
      local text = strip_strider_footer(vim.trim(raw_text))
      if text ~= "" then
        review.capture_plan_message(text)
      end
    end
    local item = review.ingest_plan(args)
    if item then
      ui.append({ string.format("• Planned %d stop(s), scope=%s",
        #(args.stops or {}),
        args.scope or "?") }, lane)
    else
      ui.notify("Strider plan was empty or invalid; review cannot start", vim.log.levels.ERROR)
    end
    return
  end
  if event.toolName == "strider_append_stops" then
    local args = consume_tool_args(session, event) or {}
    local added = review.ingest_append_stops(args)
    if added > 0 then
      ui.append({ string.format("• Appended %d stop(s)", added) }, lane)
    end
    return
  end

  local path = finish_tool_path(session, event)
  if not path then
    return
  end
  if event.toolName == "read" then
    state.record_file(path, lane)
    return
  end
  if event.toolName == "edit" then
    state.record_file(path, lane)
    -- Keep local highlights if the edited buffer is already around, but do
    -- not move the user's window to follow model tool use.
    local lines = changed_lines(event)
    ui.highlight_lines(path, lines, lane)
    local diff_text = event.result and event.result.details and event.result.details.diff
    if diff_text and diff_text ~= "" then
      local added, removed = diff_stats(diff_text)
      local suffix = string.format(" (+%d -%d)", added, removed)
      ui.update_tool_line(insert_row and (insert_row - 1) or nil, "edit", path, suffix, lane)
      local diff_opts = vim.tbl_extend("force", insert_opts, {
        lang = language_for_path(path),
        path = path,
      })
      ui.append_diff(diff_text, lane, diff_opts)
    end
    return
  end
  if event.toolName == "write" then
    state.record_file(path, lane)
    -- Same rule as edits: annotate opportunistically, never steal focus.
    ui.highlight_range(path, 1, nil, lane)
  end
end

-- Send an extension_ui_response back to pi. Payload merges an id + any
-- response-specific fields (value / cancelled / confirmed).
local function send_ui_response(id, payload, lane)
  local session = state.get_session(lane)
  if not session or not session.job_id then
    return false
  end
  -- pi-coding-agent uses crypto.randomUUID() (strings) as ids. Echo the
  -- id back as-is — do not coerce to/from number.
  local body = vim.tbl_extend("force", { type = "extension_ui_response", id = id }, payload or {})
  local ok, encoded = pcall(vim.json.encode, body)
  if not ok then
    return false
  end
  vim.fn.chansend(session.job_id, encoded .. "\n")
  return true
end

local function handle_extension_ui(event, lane)
  if event.method == "notify" then
    local levels = {
      error = vim.log.levels.ERROR,
      info = vim.log.levels.INFO,
      warning = vim.log.levels.WARN,
    }
    ui.notify(event.message or "Strider notice", levels[event.notifyType] or vim.log.levels.INFO)
    return
  end
  if event.method == "setStatus" then
    local session = state.get_session(lane)
    local previous = session.status[event.statusKey]
    state.set_status(event.statusKey, event.statusText, lane)
    if event.statusKey == "strider-session" then
      local reason = event.statusText
      if reason == "new" or reason == "fork" or reason == "resume" then
        local labels = { new = "New session", fork = "Forked session", resume = "Resumed session" }
        ui.append_block("strider", string.format("──── %s ────", labels[reason] or reason), lane)
      end
      return
    end
    if event.statusKey == "strider" and event.statusText ~= previous then
      if event.statusText == "complete" then
        ui.append({ "[strider] Workflow complete", "" }, lane)
      elseif event.statusText and event.statusText:find("final%-awaiting%-next", 1, false) then
        ui.append({ "[strider] Final chunk awaiting :StriderNext", "" }, lane)
      elseif event.statusText and event.statusText:find("awaiting-next", 1, true) then
        ui.append({ "[strider] Awaiting :StriderNext", "" }, lane)
      end
    end
    return
  end
  if event.method == "setWidget" then
    state.set_widget(event.widgetLines, lane)
    ui.refresh_log_winbar(lane)
    return
  end
  if event.method == "editor" then
    -- Open a floating scratch editor. Title comes from the event; any
    -- `prefill` seeds the buffer. On submit send `{value: text}`; on
    -- cancel send `{cancelled: true}`. Tool's execute() in the extension
    -- awaits this response.
    --
    -- Plan proposals are a special case: the extension tags their title
    -- with a `[strider-plan-proposal]` sentinel so we route through a
    -- read-only preview + accept/modify/reject picker rather than the
    -- one-box edit-and-submit flow.
    local id = event.id
    local title = event.title or "Strider clarify"
    local prefill = event.prefill or ""
    local plan_prefix = "[strider-plan-proposal] "
    if lane ~= "main" then
      local function popup_cancel(message)
        ui.append({ message or "[strider] clarify cancelled" }, lane)
        send_ui_response(id, { cancelled = true }, lane)
      end

      if title:sub(1, #plan_prefix) == plan_prefix then
        local display_title = title:sub(#plan_prefix + 1)
        local body = prefill ~= "" and prefill or "(empty proposal)"
        ui.append_block("plan", string.format("%s\n\n%s", display_title, body), lane)
        ui.clarify_plan_proposal_picker(function(choice)
          if choice == "accept" then
            ui.append_block("user", prefill ~= "" and prefill or "(accepted)", lane)
            send_ui_response(id, { value = prefill }, lane)
          elseif choice == "modify" then
            ui.open_prompt_editor(display_title, function(text)
              ui.append_block("user", text, lane)
              send_ui_response(id, { value = text }, lane)
            end, {
              hint_lines = { "Edit the proposal, then submit it back to Strider." },
              on_cancel = function()
                popup_cancel("[strider] plan proposal rejected")
              end,
              prefill = prefill,
            })
          else
            popup_cancel("[strider] plan proposal rejected")
          end
        end)
        return
      end

      local body_parts = { title }
      if prefill ~= "" then
        table.insert(body_parts, "")
        table.insert(body_parts, prefill)
      end
      ui.append_block("clarify", table.concat(body_parts, "\n"), lane)
      ui.open_prompt_editor(title, function(text)
        ui.append_block("user", text, lane)
        send_ui_response(id, { value = text }, lane)
      end, {
        hint_lines = { "Reply to Strider's question." },
        on_cancel = popup_cancel,
        prefill = prefill ~= "" and prefill or nil,
      })
      return
    end
    if title:sub(1, #plan_prefix) == plan_prefix then
      local display_title = title:sub(#plan_prefix + 1)
      -- Put the full proposal body in the chat log first so the user can
      -- read it in-place before the Accept/Modify/Reject picker pops.
      -- No floating preview — everything lives in the chat transcript.
      local body = prefill ~= "" and prefill or "(empty proposal)"
      ui.append_block("plan", string.format("%s\n\n%s", display_title, body), lane)
      ui.clarify_plan_proposal_picker(function(choice)
        if choice == "accept" then
          ui.append_block("user", prefill ~= "" and prefill or "(accepted)", lane)
          send_ui_response(id, { value = prefill }, lane)
        elseif choice == "modify" then
          -- Hijack compose as the clarify-reply surface, seeded with
          -- the proposal body. The user edits in-place and hits <C-s>
          -- to submit the edited text as the clarify value.
          state.set_pending_clarify(id, display_title, lane)
          state.set_status("strider-clarify", "clarify", lane)
          ui.refresh_compose_winbar(lane)
          ui.refresh_compose_hint()
          require("strider").open_compose_for_clarify()
          ui.seed_compose(prefill)
        else
          ui.append({ "[strider] plan proposal rejected" }, lane)
          send_ui_response(id, { cancelled = true }, lane)
        end
      end)
      return
    end
    -- Non-plan clarify: render the question inline in the chat log and
    -- hijack the next compose send to route back as the clarify reply.
    -- Matches the "everything in chat, no popout" principle used for
    -- plan proposals.
    local body_parts = { title }
    if prefill ~= "" then
      table.insert(body_parts, "")
      table.insert(body_parts, prefill)
    end
    ui.append_block("clarify", table.concat(body_parts, "\n"), lane)
    state.set_pending_clarify(id, title, lane)
    state.set_status("strider-clarify", "clarify", lane)
    ui.refresh_compose_winbar(lane)
    ui.refresh_compose_hint()
    ui.open_log({ preserve_focus = true }, lane)
    -- Bring compose up; dispatch_compose (init.lua) checks
    -- pending_clarify before anything else and routes there.
    require("strider").open_compose_for_clarify()
    return
  end
  if event.method == "confirm" then
    local id = event.id
    local title = event.title or "Strider confirm"
    local message = event.message or ""
    local prompt = message ~= "" and (title .. "\n\n" .. message) or title
    vim.schedule(function()
      vim.ui.select({ "Yes", "No" }, { prompt = prompt }, function(choice)
        if choice == nil then
          ui.append({ "[strider] confirm cancelled" }, lane)
          send_ui_response(id, { cancelled = true }, lane)
        else
          local confirmed = choice == "Yes"
          ui.append({ string.format("[strider] confirm: %s", choice) }, lane)
          send_ui_response(id, { confirmed = confirmed }, lane)
        end
      end)
    end)
    return
  end
  if event.method == "select" then
    -- Fuzzy picker (telescope → fzf-lua → vim.ui.select). Response shape
    -- is `{value: <selected option string>}` or `{cancelled: true}`.
    local id = event.id
    local title = event.title or "Strider select"
    local options = event.options or {}
    local items = {}
    for _, opt in ipairs(options) do
      table.insert(items, { label = tostring(opt), value = opt })
    end
    ui.append_block("strider", string.format("select: %s", title), lane)
    local delivered = false
    local function deliver(chosen)
      if delivered then return end
      delivered = true
      if chosen == nil then
        ui.append({ "[strider] select cancelled" }, lane)
        send_ui_response(id, { cancelled = true }, lane)
      else
        ui.append({ string.format("[strider] select: %s", chosen) }, lane)
        send_ui_response(id, { value = chosen }, lane)
      end
    end
    vim.schedule(function()
      local ok = picker.select(title, items, function(item)
        deliver(item and item.value or nil)
      end)
      if not ok then
        deliver(nil)
      end
    end)
    return
  end
  if event.method == "input" then
    -- Single-line input via vim.ui.input. Response shape is `{value: text}`
    -- or `{cancelled: true}`. Multi-line input is served by `editor`.
    local id = event.id
    local title = event.title or "Strider input"
    local placeholder = event.placeholder or ""
    ui.append_block("strider", string.format("input: %s", title), lane)
    vim.schedule(function()
      vim.ui.input({ prompt = title .. ": ", default = placeholder }, function(value)
        if value == nil then
          ui.append({ "[strider] input cancelled" }, lane)
          send_ui_response(id, { cancelled = true }, lane)
        else
          ui.append_block("user", value, lane)
          send_ui_response(id, { value = value }, lane)
        end
      end)
    end)
    return
  end
end

local function dispatch(event, lane)
  if event.type == "response" then
    handle_response(event, lane)
    return
  end
  if event.type == "extension_error" then
    handle_extension_error(event, lane)
    return
  end
  if event.type == "message_update" then
    handle_message_update(event, lane)
    return
  end
  if event.type == "message_end" then
    handle_message_end(event, lane)
    return
  end
  if event.type == "tool_execution_start" then
    handle_tool_start(event, lane)
    return
  end
  if event.type == "tool_execution_end" then
    handle_tool_end(event, lane)
    return
  end
  if event.type == "extension_ui_request" then
    handle_extension_ui(event, lane)
  end
end

-- Reusable per-call buffers to reduce GC pressure during rapid streaming.
-- split_lines populates `reuse_lines`; consume_json decodes into
-- `reuse_events`. Both are cleared at the start of each call.
local reuse_lines = {}
local reuse_events = {}

local function split_lines(data, tail)
  if #data == 0 then
    return reuse_lines, tail, 0
  end

  local count = 0
  local current = tail .. (data[1] or "")
  for index = 2, #data do
    count = count + 1
    reuse_lines[count] = current
    current = data[index] or ""
  end
  if data[#data] == "" then
    if current ~= "" then
      count = count + 1
      reuse_lines[count] = current
    end
    return reuse_lines, "", count
  end
  return reuse_lines, current, count
end

local function consume_json(session, data, tail_key, lane)
  local lines, new_tail, line_count = split_lines(data, session[tail_key])
  session[tail_key] = new_tail
  local event_count = 0
  for i = 1, line_count do
    local event = decode(lines[i])
    if event then
      event_count = event_count + 1
      reuse_events[event_count] = event
    end
  end
  if event_count > 0 then
    -- Snapshot the events for the scheduled callback; clear reuse buffers.
    local snapshot = {}
    for i = 1, event_count do
      snapshot[i] = reuse_events[i]
      reuse_events[i] = nil
    end
    for i = 1, line_count do reuse_lines[i] = nil end
    vim.schedule(function()
      for i = 1, #snapshot do
        dispatch(snapshot[i], lane)
      end
    end)
  else
    for i = 1, line_count do reuse_lines[i] = nil end
  end
end

local function consume_text(session, data, tail_key, lane)
  local lines, new_tail, line_count = split_lines(data, session[tail_key])
  session[tail_key] = new_tail
  if line_count == 0 then
    return
  end
  local snapshot = {}
  for i = 1, line_count do
    snapshot[i] = lines[i]
    lines[i] = nil
  end
  vim.schedule(function()
    for i = 1, #snapshot do
      ui.append({ "[stderr] " .. snapshot[i] }, lane)
    end
  end)
end

function M.start(arg1, arg2)
  local lane, cwd = resolve_lane_and_cwd(arg1, arg2)
  local session = state.ensure_session(lane, cwd)
  if session.job_id and vim.fn.jobwait({ session.job_id }, 0)[1] == -1 then
    return true
  end

  local job_id = vim.fn.jobstart(command_list(), {
    cwd = cwd,
    on_exit = function()
      session.job_id = nil
      vim.schedule(function()
        ui.notify("Strider backend exited", vim.log.levels.WARN)
      end)
    end,
    on_stderr = function(_, data)
      consume_text(session, data, "stderr_tail", lane)
    end,
    on_stdout = function(_, data)
      consume_json(session, data, "stdout_tail", lane)
    end,
  })

  if job_id <= 0 then
    ui.notify("Failed to start pi in RPC mode", vim.log.levels.ERROR)
    return false
  end

  session.job_id = job_id
  if lane == "main" and state.get_config().open_log_on_start then
    ui.open_log({ preserve_focus = true }, lane)
  end
  ui.append({ "[strider] backend started", "" }, lane)
  return true
end

function M.stop(lane)
  local session = state.get_session(lane)
  if not session or not session.job_id then
    return
  end
  vim.fn.jobstop(session.job_id)
  session.job_id = nil
end

-- Abort the current in-flight turn. Pi's RPC layer handles the rest:
-- it cancels the provider stream and emits a final `message_end` with
-- `stopReason = "aborted"`, which `handle_message_end` already renders
-- as a cancel-flavored `[error]` block and clears pending state.
-- No-op when no turn is in flight (still sends the RPC; pi answers
-- with success=true either way, costs nothing).
function M.abort(lane)
  local session = state.get_session(lane)
  if not session or not session.job_id then
    ui.notify("Strider backend is not running", vim.log.levels.WARN)
    return false
  end
  vim.fn.chansend(session.job_id, vim.json.encode({ type = "abort" }) .. "\n")
  return true
end

function M.send_prompt(arg1, arg2)
  local lane, message = resolve_lane_and_payload(arg1, arg2)
  local session = state.get_session(lane)
  if not session or not session.job_id then
    ui.notify("Strider backend is not running", vim.log.levels.WARN)
    return false
  end

  local payload = {
    id = state.next_request_id(lane),
    message = message,
    type = "prompt",
  }
  vim.fn.chansend(session.job_id, vim.json.encode(payload) .. "\n")
  return true
end

-- Steer an already-running turn with additional user input. Pi inserts
-- the steer message mid-stream; the model sees it and adjusts without
-- a new turn being started. No new pending_request is created — the
-- existing one continues to resolve on the next message_end.
function M.send_steer(arg1, arg2)
  local lane, message = resolve_lane_and_payload(arg1, arg2)
  local session = state.get_session(lane)
  if not session or not session.job_id then
    ui.notify("Strider backend is not running", vim.log.levels.WARN)
    return false
  end

  local payload = {
    id = state.next_request_id(lane),
    message = message,
    type = "steer",
  }
  vim.fn.chansend(session.job_id, vim.json.encode(payload) .. "\n")
  return true
end

-- Send a raw RPC command (not a prompt). Used for session-management
-- commands like new_session, fork, compact that are dedicated RPC
-- message types rather than slash-commands routed through prompt.
function M.send_command(cmd_type, extra, lane, callback)
  lane = normalize_lane(lane)
  local session = state.get_session(lane)
  if not session or not session.job_id then
    ui.notify("Strider backend is not running", vim.log.levels.WARN)
    return false
  end
  local req_id = state.next_request_id(lane)
  local payload = vim.tbl_extend("force", extra or {}, {
    id = req_id,
    type = cmd_type,
  })
  if callback then
    response_callbacks[req_id] = callback
  end
  vim.fn.chansend(session.job_id, vim.json.encode(payload) .. "\n")
  return true
end

return M
