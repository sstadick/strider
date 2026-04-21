local review = require("sherpa.review")
local rpc = require("sherpa.rpc")
local search = require("sherpa.search")
local state = require("sherpa.state")
local ui = require("sherpa.ui")

local M = {}

local function current_cwd()
  return vim.fn.getcwd()
end

local function ensure_backend()
  local cwd = current_cwd()
  local session = state.get_session()
  if session and session.cwd ~= cwd then
    rpc.stop()
    state.clear_session()
  end
  return rpc.start(cwd)
end

local function activity_title(operation)
  local titles = {
    patch = "Sherpa patch running...",
    plan = "Sherpa planning review...",
    review = "Sherpa review running...",
    search = "Sherpa search running...",
    prompt = "Sherpa prompt running...",
  }
  return titles[operation] or "Sherpa running..."
end

local function activity_target(operation)
  if (operation == "review" or operation == "plan") and review.has_active_review() then
    return "review"
  end
  return "log"
end

local function send(command, user_text, opts)
  if not ensure_backend() then
    return false
  end
  if opts and opts.open_log then
    ui.open_log()
  end
  local operation = opts and opts.operation or nil
  state.set_pending_request(operation, opts and opts.metadata)
  if operation then
    ui.start_activity(activity_title(operation), activity_target(operation), operation)
  end
  local ok = rpc.send_prompt(command)
  if not ok then
    state.set_pending_request(nil)
    ui.finish_activity("Sherpa request failed to start", "error")
    return false
  end
  if user_text and user_text ~= "" then
    ui.append_block("user", user_text)
  end
  if opts and opts.debug_prompt and opts.debug_prompt ~= "" then
    ui.append_block("review-prompt", opts.debug_prompt)
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

local function send_review_prompt(prompt, label)
  return send("/review " .. prompt, label, {
    operation = "review",
    debug_prompt = prompt,
  })
end

local function start_selection_review(opts)
  if not ensure_backend() then
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
  return send_review_prompt(prompt, label)
end

local function start_free_review(focus)
  local text = trimmed(focus)
  if text == "" then
    ui.notify("SherpaReview requires input", vim.log.levels.WARN)
    return false
  end
  if not ensure_backend() then
    return false
  end
  if not review.start_planning(text) then
    return false
  end
  return send("/plan " .. text, text, {
    operation = "plan",
    debug_prompt = text,
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
  -- `ingest_plan` already called focus_item for stop 1 and rendered the
  -- sidebar. Nothing else to do here — this hook exists so rpc.lua can
  -- still signal "plan turn complete" without hard-coding navigation.
  return true
end

-- Re-dispatch the plan turn if it stalled. Only useful while planning;
-- once a plan has landed, explanations are already pre-computed so
-- there is nothing to retry mid-review.
function M.retry()
  if not review.has_active_review() then
    ui.notify("No active Sherpa review to retry", vim.log.levels.WARN)
    return false
  end
  if review.is_planning() then
    local session = state.get_session()
    local goal = session and session.review and session.review.goal
    if not goal or goal == "" then
      ui.notify("Cannot retry plan: review goal is missing", vim.log.levels.WARN)
      return false
    end
    return send("/plan " .. goal, goal, {
      operation = "plan",
      debug_prompt = goal,
    })
  end
  ui.notify("Nothing to retry — explanations are pre-computed.", vim.log.levels.INFO)
  return false
end

function M.setup(opts)
  state.setup(opts or {})
end

function M.prompt(prompt)
  prompt = trimmed(prompt)
  if prompt == "" then
    -- Spin up the backend first so peek_pending_request has a session.
    if not ensure_backend() then
      return
    end
    -- Reject-with-notify if a request is already in flight. Composing
    -- a draft on top of a pending turn is confusing; the user should
    -- wait for the reply (or explicitly abort) before composing.
    local pending = state.peek_pending_request()
    if pending then
      ui.notify(
        string.format("Sherpa is already running a %s request; wait for the reply.", pending.operation),
        vim.log.levels.WARN
      )
      return
    end
    ui.open_log_with_draft(function(text)
      M.prompt(text)
    end)
    return
  end
  send("/prompt " .. prompt, prompt, { operation = "prompt", open_log = true })
end

function M.search(prompt)
  prompt = trimmed(prompt)
  if prompt == "" then
    ui.open_prompt_editor("Sherpa search", function(text)
      M.search(text)
    end, {
      "Structured code search. e.g. \"websocket entrypoints\".",
      "Use :SherpaSearches to browse previous searches.",
    })
    return
  end
  send("/search " .. prompt, prompt, {
    operation = "search",
    metadata = { prompt = prompt },
    open_log = true,
  })
end


function M.review(args, opts)
  local range = range_from_opts(opts)
  local text = trimmed(args)
  local empty_args = text == ""

  -- Ranged question inside an active review: scope the question to the
  -- sub-range and stash the range so the streaming answer can render as
  -- an inline block annotation over that range rather than cluttering
  -- the sidebar.
  if review.has_active_review() and range then
    if empty_args then
      local captured = range
      ui.open_prompt_editor("Ask about this selected range", function(input)
        local question = trimmed(input)
        if question == "" then return end
        review.begin_ranged_question(captured, question)
        local prompt = review.build_prompt(question)
        if prompt then send_review_prompt(prompt, question) end
      end, {
        "Ask a question about the selected range inside the active review.",
      })
      return
    end
    review.begin_ranged_question(range, text)
    local prompt = review.build_prompt(text)
    if prompt then send_review_prompt(prompt, text) end
    return
  end

  if review.has_active_review() and not range then
    if empty_args then
      ui.open_prompt_editor("Ask about this review item", function(input)
        local question = trimmed(input)
        local prompt = review.build_prompt(question)
        if not prompt then
          ui.notify("No active Sherpa review item", vim.log.levels.WARN)
          return
        end
        send_review_prompt(prompt, question)
      end, {
        "Ask a question about the current review item.",
      })
      return
    end

    local prompt = review.build_prompt(text)
    if not prompt then
      ui.notify("No active Sherpa review item", vim.log.levels.WARN)
      return
    end
    send_review_prompt(prompt, text)
    return
  end

  if range then
    if empty_args then
      ui.open_prompt_editor("Sherpa review context", function(input)
        local focus_text = trimmed(input)
        start_selection_review({
          endLine = range.endLine,
          focus = focus_text,
          path = range.path,
          startLine = range.startLine,
        })
      end, {
        "Describe what you want reviewed in this selected range.",
      })
      return
    end

    start_selection_review({
      endLine = range.endLine,
      focus = text,
      path = range.path,
      startLine = range.startLine,
    })
    return
  end

  if empty_args then
    ui.open_prompt_editor("Sherpa review context", function(input)
      start_free_review(trimmed(input))
    end, {
      "Describe what you want reviewed.",
    })
    return
  end

  start_free_review(text)
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
  send("/patch " .. table.concat(lines, "\n"), prompt, { operation = "patch" })
end

function M.patch(prompt, opts)
  prompt = trimmed(prompt)

  local range = range_from_opts(opts)
  local item = review.current_item()
  if not range and item then
    range = {
      path = item.path,
      startLine = item.startLine,
      endLine = item.endLine,
    }
  end
  if not range then
    ui.notify("SherpaPatch needs a visual range or an active review item", vim.log.levels.WARN)
    return
  end

  if prompt == "" then
    local captured_range = range
    ui.open_prompt_editor("Sherpa patch request", function(text)
      local inner = trimmed(text)
      if inner == "" then
        ui.notify("Usage: :SherpaPatch <request>", vim.log.levels.WARN)
        return
      end
      dispatch_patch(inner, captured_range)
    end, {
      string.format("Patch target: %s:%d-%d", range.path, range.startLine, range.endLine),
      "Keep changes local to this range.",
    })
    return
  end

  dispatch_patch(prompt, range)
end

function M.next_step()
  if not review.has_active_review() then
    ui.notify("No active Sherpa review session", vim.log.levels.WARN)
    return
  end

  -- Explanations are pre-computed at plan time. Navigation is a pure
  -- index++ that focuses the next stop; no model round-trip.
  local item, finished = review.advance(1)
  if item then
    return
  end

  if finished then
    local prompt = review.finish()
    ui.open_log()
    local comment_lines = review.pending_comment_lines()
    if comment_lines then
      ui.append_block("review-comments", table.concat(comment_lines, "\n"))
    end
    if prompt then
      send_review_prompt(prompt, "Summarize unresolved review comments")
    else
      ui.notify("Sherpa review complete", vim.log.levels.INFO)
    end
  end
end

function M.prev_step()
  if not review.has_active_review() then
    ui.notify("No active Sherpa review session", vim.log.levels.WARN)
    return
  end
  local item = review.advance(-1)
  if not item then
    ui.notify("Already at the first review item", vim.log.levels.WARN)
    return
  end
end

function M.comment(text, opts)
  local range = range_from_opts(opts)
  text = trimmed(text)

  local function log_comment(comment)
    ui.append_block("review", string.format("%s:%d-%d\n%s", comment.path, comment.startLine, comment.endLine, comment.text))
  end

  if text == "" then
    review.open_comment_editor(range, log_comment)
    return
  end

  local comment = review.add_comment(text, range)
  if not comment then
    return
  end
  log_comment(comment)
end

function M.comments()
  review.comment_picker()
end

function M.review_items()
  review.item_picker()
end

function M.searches()
  search.history_picker()
end

function M.show_log()
  ui.show_log()
end

return M
