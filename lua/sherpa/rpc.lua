local picker = require("sherpa.picker")
local review = require("sherpa.review")
local search = require("sherpa.search")
local state = require("sherpa.state")
local ui = require("sherpa.ui")

local M = {}

local function command_list()
  local config = state.get_config()
  local cmd = vim.deepcopy(config.pi_cmd)
  local extension = config.extension_path or (config.plugin_root .. "/pi/sherpa-stepper.ts")
  vim.list_extend(cmd, { "--mode", "rpc", "--extension", extension })
  return cmd
end

local function decode(line)
  local ok, value = pcall(vim.json.decode, line)
  if ok then
    return value
  end
end

local function append_tool(tool_name, args)
  local path = args and args.path
  if path then
    if tool_name == "read" then
      local start_line = tonumber(args.offset) or 1
      local limit = tonumber(args.limit)
      local range = limit
        and string.format(":%d-%d", start_line, start_line + limit - 1)
        or string.format(":%d", start_line)
      ui.append_tool_line(tool_name, path, range)
      return
    end
    ui.append_tool_line(tool_name, path, nil)
    return
  end

  if tool_name == "bash" and args and args.command then
    ui.append_block("tool", string.format("bash\n%s", args.command))
    return
  end

  ui.append({ string.format("[tool] %s", tool_name) })
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

local function strip_sherpa_footer(text)
  if not text then
    return nil
  end
  local cleaned = text:gsub("\n?<SHERPA_STATUS>.-</SHERPA_STATUS>%s*$", "")
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

local function handle_response(event)
  if event.success then
    return
  end
  -- RPC transport-level error (pi rejected the request shape, backend
  -- isn't running, etc.). Less common than model-level errors — those
  -- arrive on message_end with stopReason="error" (see
  -- handle_message_end). Both paths log into the buffer so the user
  -- always has a record beyond the fleeting notify.
  local reason = event.errorMessage or "Sherpa RPC request failed"
  ui.append_block("error", reason)
  ui.finish_activity(reason, "error")
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
local function handle_extension_error(event)
  local reason = event.error or "Sherpa extension error"
  -- Collapse multi-line reasons to the first non-empty line for the
  -- notify + activity echo; put the full text in the [error] block so
  -- detail isn't lost.
  local first_line = reason
  for line in reason:gmatch("[^\r\n]+") do
    if vim.trim(line) ~= "" then first_line = line; break end
  end
  ui.append_block("error", reason)
  ui.finish_activity(first_line, "error")
  ui.notify(first_line, vim.log.levels.ERROR)
  -- Clear the pending request so the activity spinner actually stops
  -- and the next send doesn't think a turn is still in flight.
  state.consume_pending_request()
end

local function ensure_stream_log(pending)
  if not pending or pending.log_opened or pending.operation == "plan" then
    return
  end
  pending.log_opened = true
  ui.open_log({ preserve_focus = true })
end

local function flush_thinking_index(session, pending, content_index)
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
  ensure_stream_log(pending)
  ui.append_block("thinking", text)
end

local function flush_all_thinking(session, pending)
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
    flush_thinking_index(session, pending, index)
  end
end

local function handle_message_update(event)
  local delta = event.assistantMessageEvent
  if not delta then
    return
  end
  local pending = state.peek_pending_request()
  if not pending then
    return
  end
  local session = state.get_session()
  session.assistant_thinking = session.assistant_thinking or {}

  if delta.type == "thinking_start" then
    session.assistant_thinking[delta.contentIndex or 0] = ""
    return
  end
  if delta.type == "thinking_delta" then
    local index = delta.contentIndex or 0
    session.assistant_thinking[index] = (session.assistant_thinking[index] or "") .. (delta.delta or "")
    ensure_stream_log(pending)
    return
  end
  if delta.type == "thinking_end" then
    local index = delta.contentIndex or 0
    if (not session.assistant_thinking[index] or session.assistant_thinking[index] == "") and delta.content then
      session.assistant_thinking[index] = delta.content
    end
    flush_thinking_index(session, pending, index)
    return
  end
  if delta.type == "done" or delta.type == "error" then
    flush_all_thinking(session, pending)
    return
  end
  if delta.type ~= "text_delta" then
    return
  end
  session.assistant_text = (session.assistant_text or "") .. (delta.delta or "")

  -- Auto-open the log on the first streamed delta of any answer-producing
  -- operation, without stealing focus. Idempotent: open_log is a no-op
  -- when the log is already visible. One-per-pending guard avoids
  -- reopening a manually-closed log mid-stream.
  ensure_stream_log(pending)

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

local function handle_message_end(event)
  local message = event.message
  local text = strip_sherpa_footer(text_content(message))
  local pending = state.peek_pending_request()
  local session = state.get_session()

  flush_all_thinking(session, pending)

  -- Do not consume pending on tool-call turns or user messages.
  -- Only the final text-bearing assistant message should consume it.
  if has_tool_use(message) then
    return
  end
  if not message or message.role ~= "assistant" then
    return
  end

  pending = state.consume_pending_request()
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
    ui.append_block("error", reason)
    local level = stop_reason == "aborted" and "cancel" or "error"
    ui.finish_activity(reason, level)
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
      ui.append_block("assistant", text)
    end
    if review.has_active_review() and review.is_planning() then
      ui.notify("Sherpa could not produce a plan — try rephrasing.", vim.log.levels.ERROR)
      ui.finish_activity("Sherpa plan failed", "error")
      return
    end
    ui.finish_activity("Sherpa plan complete", "success")
    vim.schedule(function()
      local ok, mod = pcall(require, "sherpa")
      if ok and mod and mod.dispatch_first_review then
        mod.dispatch_first_review()
      end
    end)
    return
  end

  if not text then
    ui.finish_activity("Sherpa request complete (no text)", "success")
    return
  end

  if pending and pending.operation == "search" then
    local result_set = search.handle_response(text, pending.metadata)
    local summary = search.summary_text(result_set)
    state.set_summary(summary)
    ui.append_block("assistant", summary)
    ui.finish_activity(summary, "success")
    return
  end

  state.set_summary(text:gsub("\n", " "))
  ui.append_block("assistant", text)
  if pending and pending.operation == "review" then
    review.capture_assistant_text(text)
  end
  ui.finish_activity("Sherpa request complete", "success")
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

local function handle_tool_start(event)
  local session = state.get_session()
  append_tool(event.toolName, event.args)

  -- Cache args for Sherpa planning tools — tool_execution_end events do not
  -- carry args, so we have to capture them here while they're available.
  if (event.toolName == "sherpa_plan" or event.toolName == "sherpa_append_stops")
      and event.toolCallId then
    session.tool_args[event.toolCallId] = event.args
  end

  local path = track_tool_path(session, event)
  if not path then
    return
  end
  state.record_file(path)
  -- Do not auto-jump for model tool reads. Sherpa review navigation is the
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
-- as noise). edit is deliberately excluded — its `[diff]` block below
-- already captures the change, and the raw text result for edit tends
-- to be a redundant "OK" string.
local TOOL_OUTPUT_WHITELIST = {
  bash = true,
  read = true,
  grep = true,
  ls = true,
  find = true,
  write = true,
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

local function handle_tool_end(event)
  local session = state.get_session()

  -- Render textual output for tools where seeing the content helps the
  -- user follow along (everything except edit, which gets a diff block
  -- below, and Sherpa's internal planning tools which carry structured
  -- payloads rather than user-facing text). For read/write we pass a
  -- language tag so the content is fenced and treesitter +
  -- render-markdown can syntax-highlight it; other tools render as
  -- plain muted text.
  if TOOL_OUTPUT_WHITELIST[event.toolName] then
    local text = tool_result_text(event)
    if text then
      local lang = nil
      if event.toolName == "read" or event.toolName == "write" then
        -- Peek the stashed path without consuming — finish_tool_path
        -- below does the actual consume for the edit/highlight flow.
        local stashed = event.toolCallId and session.tool_paths[event.toolCallId] or nil
        lang = language_for_path(stashed)
      end
      ui.append_tool_output(text, lang)
    end
  end

  -- Sherpa planning tools carry their payload in args captured at start time.
  if event.toolName == "sherpa_plan" then
    local args = consume_tool_args(session, event) or {}
    -- Capture any streamed prose as the plan message BEFORE ingest_plan so
    -- ingest_plan can route to message 0.  handle_message_end skips the
    -- capture when the message contains tool_use (which it always does here),
    -- so this is the only place the plan message is reliably captured.
    local raw_text = session.assistant_text
    if raw_text and raw_text ~= "" then
      local text = strip_sherpa_footer(vim.trim(raw_text))
      if text ~= "" then
        review.capture_plan_message(text)
      end
    end
    local item = review.ingest_plan(args)
    if item then
      ui.append({ string.format("[sherpa] plan: %d stop(s), scope=%s",
        #(args.stops or {}),
        args.scope or "?") })
    else
      ui.notify("Sherpa plan was empty or invalid; review cannot start", vim.log.levels.ERROR)
    end
    return
  end
  if event.toolName == "sherpa_append_stops" then
    local args = consume_tool_args(session, event) or {}
    local added = review.ingest_append_stops(args)
    if added > 0 then
      ui.append({ string.format("[sherpa] appended %d stop(s)", added) })
    end
    return
  end

  local path = finish_tool_path(session, event)
  if not path then
    return
  end
  if event.toolName == "read" then
    state.record_file(path)
    return
  end
  if event.toolName == "edit" then
    state.record_file(path)
    -- Keep local highlights if the edited buffer is already around, but do
    -- not move the user's window to follow model tool use.
    local lines = changed_lines(event)
    ui.highlight_lines(path, lines)
    -- Also show the diff in the log as a [diff] block. Pi emits a
    -- unified diff at event.result.details.diff already formatted with
    -- `+NUM / -NUM /  NUM` line prefixes; append_block's diff branch
    -- colors each line by prefix.
    local diff_text = event.result and event.result.details and event.result.details.diff
    if diff_text and diff_text ~= "" then
      ui.append_block("diff", diff_text)
    end
    return
  end
  if event.toolName == "write" then
    state.record_file(path)
    -- Same rule as edits: annotate opportunistically, never steal focus.
    ui.highlight_range(path, 1)
  end
end

-- Send an extension_ui_response back to pi. Payload merges an id + any
-- response-specific fields (value / cancelled / confirmed).
local function send_ui_response(id, payload)
  local session = state.get_session()
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

local function handle_extension_ui(event)
  if event.method == "notify" then
    local levels = {
      error = vim.log.levels.ERROR,
      info = vim.log.levels.INFO,
      warning = vim.log.levels.WARN,
    }
    ui.notify(event.message or "Sherpa notice", levels[event.notifyType] or vim.log.levels.INFO)
    return
  end
  if event.method == "setStatus" then
    local session = state.get_session()
    local previous = session.status[event.statusKey]
    state.set_status(event.statusKey, event.statusText)
    -- /q-anchor echoes the leaf messageId back via this key. Hand it to
    -- whoever called send_q_anchor and return — no other UI side-effects.
    if event.statusKey == "sherpa-q-anchor" then
      local cb = state.consume_q_anchor_callback()
      if cb then
        local id = event.statusText
        if id == nil or id == "" then
          cb(nil)
        else
          cb(id)
        end
      end
      return
    end
    if event.statusKey == "sherpa" and event.statusText ~= previous then
      if event.statusText == "complete" then
        ui.append({ "[sherpa] Workflow complete", "" })
      elseif event.statusText and event.statusText:find("final%-awaiting%-next", 1, false) then
        ui.append({ "[sherpa] Final chunk awaiting :SherpaNext", "" })
      elseif event.statusText and event.statusText:find("awaiting-next", 1, true) then
        ui.append({ "[sherpa] Awaiting :SherpaNext", "" })
      end
    end
    return
  end
  if event.method == "setWidget" then
    state.set_widget(event.widgetLines)
    ui.refresh_log_winbar()
    return
  end
  if event.method == "editor" then
    -- Open a floating scratch editor. Title comes from the event; any
    -- `prefill` seeds the buffer. On submit send `{value: text}`; on
    -- cancel send `{cancelled: true}`. Tool's execute() in the extension
    -- awaits this response.
    --
    -- Plan proposals are a special case: the extension tags their title
    -- with a `[sherpa-plan-proposal]` sentinel so we route through a
    -- read-only preview + accept/modify/reject picker rather than the
    -- one-box edit-and-submit flow.
    local id = event.id
    local title = event.title or "Sherpa clarify"
    local prefill = event.prefill or ""
    local plan_prefix = "[sherpa-plan-proposal] "
    if title:sub(1, #plan_prefix) == plan_prefix then
      local display_title = title:sub(#plan_prefix + 1)
      -- Put the full proposal body in the chat log first so the user can
      -- read it in-place before the Accept/Modify/Reject picker pops.
      -- No floating preview — everything lives in the chat transcript.
      local body = prefill ~= "" and prefill or "(empty proposal)"
      ui.append_block("plan", string.format("%s\n\n%s", display_title, body))
      ui.clarify_plan_proposal_picker(function(choice)
        if choice == "accept" then
          ui.append_block("user", prefill ~= "" and prefill or "(accepted)")
          send_ui_response(id, { value = prefill })
        elseif choice == "modify" then
          -- Hijack compose as the clarify-reply surface, seeded with
          -- the proposal body. The user edits in-place and hits <C-s>
          -- to submit the edited text as the clarify value.
          state.set_pending_clarify(id, display_title)
          state.set_status("sherpa-clarify", "clarify")
          ui.refresh_compose_winbar()
          require("sherpa").open_compose_for_clarify()
          ui.seed_compose(prefill)
        else
          ui.append({ "[sherpa] plan proposal rejected" })
          send_ui_response(id, { cancelled = true })
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
    ui.append_block("clarify", table.concat(body_parts, "\n"))
    state.set_pending_clarify(id, title)
    state.set_status("sherpa-clarify", "clarify")
    ui.refresh_compose_winbar()
    ui.open_log({ preserve_focus = true })
    -- Bring compose up; dispatch_compose (init.lua) checks
    -- pending_clarify before anything else and routes there.
    require("sherpa").open_compose_for_clarify()
    return
  end
  if event.method == "confirm" then
    local id = event.id
    local title = event.title or "Sherpa confirm"
    local message = event.message or ""
    local prompt = message ~= "" and (title .. "\n\n" .. message) or title
    vim.schedule(function()
      vim.ui.select({ "Yes", "No" }, { prompt = prompt }, function(choice)
        if choice == nil then
          ui.append({ "[sherpa] confirm cancelled" })
          send_ui_response(id, { cancelled = true })
        else
          local confirmed = choice == "Yes"
          ui.append({ string.format("[sherpa] confirm: %s", choice) })
          send_ui_response(id, { confirmed = confirmed })
        end
      end)
    end)
    return
  end
  if event.method == "select" then
    -- Fuzzy picker (telescope → fzf-lua → vim.ui.select). Response shape
    -- is `{value: <selected option string>}` or `{cancelled: true}`.
    local id = event.id
    local title = event.title or "Sherpa select"
    local options = event.options or {}
    local items = {}
    for _, opt in ipairs(options) do
      table.insert(items, { label = tostring(opt), value = opt })
    end
    ui.append_block("sherpa", string.format("select: %s", title))
    local delivered = false
    local function deliver(chosen)
      if delivered then return end
      delivered = true
      if chosen == nil then
        ui.append({ "[sherpa] select cancelled" })
        send_ui_response(id, { cancelled = true })
      else
        ui.append({ string.format("[sherpa] select: %s", chosen) })
        send_ui_response(id, { value = chosen })
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
    local title = event.title or "Sherpa input"
    local placeholder = event.placeholder or ""
    ui.append_block("sherpa", string.format("input: %s", title))
    vim.schedule(function()
      vim.ui.input({ prompt = title .. ": ", default = placeholder }, function(value)
        if value == nil then
          ui.append({ "[sherpa] input cancelled" })
          send_ui_response(id, { cancelled = true })
        else
          ui.append_block("user", value)
          send_ui_response(id, { value = value })
        end
      end)
    end)
    return
  end
end

local function dispatch(event)
  if event.type == "response" then
    handle_response(event)
    return
  end
  if event.type == "extension_error" then
    handle_extension_error(event)
    return
  end
  if event.type == "message_update" then
    handle_message_update(event)
    return
  end
  if event.type == "message_end" then
    handle_message_end(event)
    return
  end
  if event.type == "tool_execution_start" then
    handle_tool_start(event)
    return
  end
  if event.type == "tool_execution_end" then
    handle_tool_end(event)
    return
  end
  if event.type == "extension_ui_request" then
    handle_extension_ui(event)
  end
end

local function split_lines(data, tail)
  if #data == 0 then
    return {}, tail
  end

  local lines = {}
  local current = tail .. (data[1] or "")
  for index = 2, #data do
    table.insert(lines, current)
    current = data[index] or ""
  end
  if data[#data] == "" then
    if current ~= "" then
      table.insert(lines, current)
    end
    return lines, ""
  end
  return lines, current
end

local function consume_json(session, data, tail_key)
  local lines
  lines, session[tail_key] = split_lines(data, session[tail_key])
  for _, line in ipairs(lines) do
    local event = decode(line)
    if event then
      vim.schedule(function()
        dispatch(event)
      end)
    end
  end
end

local function consume_text(session, data, tail_key)
  local lines
  lines, session[tail_key] = split_lines(data, session[tail_key])
  if #lines == 0 then
    return
  end
  vim.schedule(function()
    for _, line in ipairs(lines) do
      ui.append({ "[stderr] " .. line })
    end
  end)
end

function M.start(cwd)
  local session = state.ensure_session(cwd)
  if session.job_id and vim.fn.jobwait({ session.job_id }, 0)[1] == -1 then
    return true
  end

  local job_id = vim.fn.jobstart(command_list(), {
    cwd = cwd,
    on_exit = function()
      session.job_id = nil
      vim.schedule(function()
        ui.notify("Sherpa backend exited", vim.log.levels.WARN)
      end)
    end,
    on_stderr = function(_, data)
      consume_text(session, data, "stderr_tail")
    end,
    on_stdout = function(_, data)
      consume_json(session, data, "stdout_tail")
    end,
  })

  if job_id <= 0 then
    ui.notify("Failed to start pi in RPC mode", vim.log.levels.ERROR)
    return false
  end

  session.job_id = job_id
  if state.get_config().open_log_on_start then
    ui.open_log({ preserve_focus = true })
  end
  ui.append({ "[sherpa] backend started", "" })
  return true
end

function M.stop()
  local session = state.get_session()
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
function M.abort()
  local session = state.get_session()
  if not session or not session.job_id then
    ui.notify("Sherpa backend is not running", vim.log.levels.WARN)
    return false
  end
  vim.fn.chansend(session.job_id, vim.json.encode({ type = "abort" }) .. "\n")
  return true
end

function M.send_prompt(message)
  local session = state.get_session()
  if not session or not session.job_id then
    ui.notify("Sherpa backend is not running", vim.log.levels.WARN)
    return false
  end

  local payload = {
    id = state.next_request_id(),
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
-- Ask the backend for the current session leaf messageId. The response
-- arrives as a `setStatus` event with key `sherpa-q-anchor` and is
-- routed to `cb(id_or_nil)`. Fire-and-forget send; the callback resolves
-- when the event lands (or with nil if no conversation exists).
function M.send_q_anchor(cb)
  local session = state.get_session()
  if not session or not session.job_id then
    ui.notify("Sherpa backend is not running", vim.log.levels.WARN)
    if cb then cb(nil) end
    return false
  end
  state.set_q_anchor_callback(cb)
  return M.send_prompt("/q-anchor")
end

-- Navigate the session tree back to `message_id` so the Q branch drops
-- off the active path. Fire-and-forget; pi handles navigation.
function M.send_q_end(message_id)
  if not message_id or message_id == "" then
    return false
  end
  return M.send_prompt("/q-end " .. message_id)
end

function M.send_steer(message)
  local session = state.get_session()
  if not session or not session.job_id then
    ui.notify("Sherpa backend is not running", vim.log.levels.WARN)
    return false
  end

  local payload = {
    id = state.next_request_id(),
    message = message,
    type = "steer",
  }
  vim.fn.chansend(session.job_id, vim.json.encode(payload) .. "\n")
  return true
end

return M
