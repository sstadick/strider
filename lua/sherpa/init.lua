local review = require("sherpa.review")
local rpc = require("sherpa.rpc")
local search = require("sherpa.search")
local state = require("sherpa.state")
local ui = require("sherpa.ui")

local M = {}

local review_scopes = {
  branch = "branch",
  diff = "diff",
  file = "file",
  last = "last",
  pr = "branch",
  search = "search",
  searches = "search",
  selection = "selection",
}

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
    search = "Sherpa search running...",
    teach = "Sherpa review running...",
    work = "Sherpa work running...",
  }
  return titles[operation] or "Sherpa running..."
end

local function activity_target(operation)
  if operation == "teach" and review.has_active_review() then
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

local function parse_scope(args, has_range)
  if has_range then
    return "selection", trimmed(args)
  end

  local text = trimmed(args)
  if text == "" then
    return nil, nil
  end

  local first, rest = text:match("^(%S+)%s*(.-)$")
  if first and review_scopes[first] then
    return review_scopes[first], trimmed(rest)
  end

  return nil, text
end

local function start_review(scope, opts)
  if not ensure_backend() then
    return false
  end
  local item = review.start(scope, opts)
  if not item then
    return false
  end
  local prompt = review.build_prompt(opts and opts.focus)
  if not prompt then
    return false
  end
  local label = opts and opts.focus ~= "" and opts.focus or ("Review " .. scope)
  return send("/teach " .. prompt, label, { operation = "teach" })
end

function M.setup(opts)
  state.setup(opts or {})
end

function M.work(prompt)
  prompt = trimmed(prompt)
  if prompt == "" then
    ui.open_prompt_editor("Sherpa work request", function(text)
      M.work(text)
    end, {
      "Broader implementation request. Sherpa may touch multiple files.",
      "Follow up with :SherpaReview diff or :SherpaReview last.",
    })
    return
  end
  send("/work " .. prompt, prompt, { operation = "work", open_log = true })
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
  local scope, focus = parse_scope(args, range ~= nil)
  local empty_args = trimmed(args) == ""
  if scope and not (scope == "selection" and empty_args) then
    local base = nil
    if scope == "branch" and focus and focus ~= "" then
      local first, rest = focus:match("^(%S+)%s*(.-)$")
      base = first
      focus = trimmed(rest)
    end
    start_review(scope, {
      base = base,
      endLine = range and range.endLine or nil,
      focus = focus,
      path = range and range.path or nil,
      startLine = range and range.startLine or nil,
    })
    return
  end

  if empty_args then
    if review.has_active_review() then
      ui.open_prompt_editor_allow_empty("Ask about this review item", function(text)
        local question = trimmed(text)
        local prompt = review.build_prompt(question ~= "" and question or nil)
        if not prompt then
          ui.notify("No active Sherpa review item", vim.log.levels.WARN)
          return
        end
        local label = question ~= "" and question or "Continue review"
        send("/teach " .. prompt, label, { operation = "teach" })
      end, {
        "Ask a question about the current review item.",
        "Submit empty input to continue the review without adding a question.",
      })
      return
    end
    if range then
      start_review("selection", {
        endLine = range.endLine,
        path = range.path,
        startLine = range.startLine,
      })
    else
      start_review("file", { focus = nil })
    end
    return
  end

  if review.has_active_review() then
    local question = trimmed(args)
    local prompt = review.build_prompt(question ~= "" and question or nil)
    if not prompt then
      ui.notify("No active Sherpa review item", vim.log.levels.WARN)
      return
    end
    local label = question ~= "" and question or "Continue review"
    send("/teach " .. prompt, label, { operation = "teach" })
    return
  end

  start_review("file", { focus = trimmed(args) })
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
  if review.has_active_review() then
    local item, finished = review.advance(1)
    if item then
      send("/teach " .. review.build_prompt(), "Next review item", { operation = "teach" })
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
        send("/teach " .. prompt, "Summarize unresolved review comments", { operation = "teach" })
      else
        ui.notify("Sherpa review complete", vim.log.levels.INFO)
      end
      return
    end
  end

  ui.notify("No active Sherpa review session", vim.log.levels.WARN)
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
  send("/teach " .. review.build_prompt(), "Previous review item", { operation = "teach" })
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
