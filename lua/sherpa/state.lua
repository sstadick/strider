local M = {}

local lane_order = { "main", "flow", "review" }
local lane_set = {}
for _, lane in ipairs(lane_order) do
  lane_set[lane] = true
end

local flow_operations = {q = true, search = true, patch = true}

local function plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  local dir = vim.fs.dirname(source)
  return vim.fs.dirname(vim.fs.dirname(dir))
end

local defaults = {
  auto_jump = true,
  extension_path = nil,
  log_buffer_name = "sherpa://log",
  open_log_on_start = true,
  pi_cmd = { "pi" },
}

local function normalize_lane(lane)
  if lane == nil or lane == "" then
    return "main"
  end
  if lane_set[lane] then
    return lane
  end
  return "main"
end

local function resolve_lane_and_cwd(arg1, arg2)
  if lane_set[arg1] then
    return arg1, arg2
  end
  if lane_set[arg2] then
    return arg2, arg1
  end
  return "main", arg1 or arg2
end

local function new_session(cwd, lane)
  return {
    assistant_text = nil,
    assistant_thinking = {},
    chunk_lines = {},
    chunk_path = nil,
    comment_buffers = {},
    compose_buf = nil,
    cwd = cwd,
    highlight_buf = nil,
    job_id = nil,
    lane = lane,
    last_summary = nil,
    last_touched_file = nil,
    log_buf = nil,
    pending_request = nil,
    progress = nil,
    recent_files = {},
    request_seq = 0,
    review = nil,
    review_buf = nil,
    review_win = nil,
    search_history = {},
    status = {},
    stderr_tail = "",
    stdout_tail = "",
    tool_args = {},
    tool_paths = {},
    widget = {},
  }
end

M.config = vim.tbl_deep_extend("force", defaults, {
  plugin_root = plugin_root(),
})

M.sessions = {}

function M.setup(opts)
  local next_config = vim.tbl_deep_extend("force", M.config, opts or {})
  if opts and opts.pi_cmd then
    next_config.pi_cmd = opts.pi_cmd
  end
  if type(next_config.pi_cmd) == "string" then
    next_config.pi_cmd = { next_config.pi_cmd }
  end
  M.config = next_config
end

function M.get_config()
  return M.config
end

function M.lanes()
  return vim.deepcopy(lane_order)
end

function M.is_lane(lane)
  return lane_set[lane] == true
end

function M.normalize_lane(lane)
  return normalize_lane(lane)
end

function M.get_session(lane)
  return M.sessions[normalize_lane(lane)]
end

function M.ensure_session(arg1, arg2)
  local lane, cwd = resolve_lane_and_cwd(arg1, arg2)
  if not cwd or cwd == "" then
    local current = M.sessions[lane]
    cwd = current and current.cwd or vim.fn.getcwd()
  end
  if not M.sessions[lane] or M.sessions[lane].cwd ~= cwd then
    M.sessions[lane] = new_session(cwd, lane)
  end
  return M.sessions[lane]
end

function M.clear_session(lane)
  if lane == nil then
    M.sessions = {}
    return
  end
  M.sessions[normalize_lane(lane)] = nil
end

function M.next_request_id(lane)
  local session = M.get_session(lane)
  if not session then
    return nil
  end
  session.request_seq = session.request_seq + 1
  return string.format("sherpa-%s-%d", normalize_lane(lane), session.request_seq)
end

function M.record_file(path, lane)
  local session = M.get_session(lane)
  if not session then
    return
  end
  session.last_touched_file = path
  local recent = { path }
  for _, item in ipairs(session.recent_files) do
    if item ~= path and #recent < 5 then
      table.insert(recent, item)
    end
  end
  session.recent_files = recent
end

function M.set_status(key, value, lane)
  local session = M.get_session(lane)
  if not session then
    return
  end
  session.status[key] = value
end

function M.set_widget(lines, lane)
  local session = M.get_session(lane)
  if not session then
    return
  end
  session.widget = lines or {}
end

function M.set_summary(text, lane)
  local session = M.get_session(lane)
  if not session then
    return
  end
  session.last_summary = text
end

function M.set_pending_request(operation, metadata, lane)
  local session = M.get_session(lane)
  if not session then
    return
  end
  if not operation then
    session.pending_request = nil
    return
  end
  session.pending_request = {
    operation = operation,
    metadata = metadata or {},
  }
end

function M.peek_pending_request(lane)
  local session = M.get_session(lane)
  return session and session.pending_request
end

function M.consume_pending_request(lane)
  local session = M.get_session(lane)
  if not session then
    return nil
  end
  local pending = session.pending_request
  session.pending_request = nil
  return pending
end

-- Pending clarify: when the model calls sherpa_clarify (question kind),
-- the plugin stashes the extension_ui_request id + title here and
-- routes the next compose send back as the clarify reply. Cleared by
-- dispatch_compose (on answer) or by <Esc><Esc> in compose (on reject).
function M.set_pending_clarify(id, title, lane)
  local session = M.get_session(lane)
  if session then
    session.pending_clarify = { id = id, title = title or "" }
  end
end

function M.peek_pending_clarify(lane)
  local session = M.get_session(lane)
  return session and session.pending_clarify
end

function M.consume_pending_clarify(lane)
  local session = M.get_session(lane)
  if not session then return nil end
  local p = session.pending_clarify
  session.pending_clarify = nil
  return p
end

function M.is_flow_operation(op)
  return flow_operations[op] == true
end

return M
