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
    ui.append({ string.format("[tool] %s %s", tool_name, path) })
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
  ui.notify(event.errorMessage or "Sherpa RPC request failed", vim.log.levels.ERROR)
end

local function handle_message_end(event)
  local text = strip_sherpa_footer(text_content(event.message))
  if not text then
    return
  end
  state.set_summary(text:gsub("\n", " "))
  ui.append_block("assistant", text)
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

local function handle_tool_start(event)
  local session = state.get_session()
  append_tool(event.toolName, event.args)
  local path = track_tool_path(session, event)
  if not path then
    return
  end
  state.record_file(path)
  if event.toolName == "read" then
    ui.jump_to_file(path, event.args and event.args.offset)
  end
end

local function handle_tool_end(event)
  local session = state.get_session()
  local path = finish_tool_path(session, event)
  if not path then
    return
  end
  if event.toolName == "edit" then
    local lines = changed_lines(event)
    state.record_file(path)
    ui.jump_to_file(path, first_changed_line(event))
    ui.highlight_lines(path, lines)
    return
  end
  if event.toolName == "write" then
    state.record_file(path)
    ui.jump_to_file(path, 1)
    ui.highlight_range(path, 1)
  end
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
  end
end

local function dispatch(event)
  if event.type == "response" then
    handle_response(event)
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
    ui.show_log()
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

return M
