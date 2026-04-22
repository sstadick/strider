local M = {}

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

local function new_session(cwd)
  return {
    assistant_text = nil,
    assistant_thinking = {},
    chunk_lines = {},
    chunk_path = nil,
    comment_buffers = {},
    cwd = cwd,
    highlight_buf = nil,
    review_buf = nil,
    review_win = nil,
    job_id = nil,
    last_summary = nil,
    last_touched_file = nil,
    pending_request = nil,
    progress = nil,
    recent_files = {},
    request_seq = 0,
    review = nil,
    search_history = {},
    status = {},
    stdout_tail = "",
    stderr_tail = "",
    tool_args = {},
    tool_paths = {},
    widget = {},
  }
end

M.config = vim.tbl_deep_extend("force", defaults, {
  plugin_root = plugin_root(),
})

M.session = nil

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

function M.get_session()
  return M.session
end

function M.ensure_session(cwd)
  if not M.session or M.session.cwd ~= cwd then
    M.session = new_session(cwd)
  end
  return M.session
end

function M.clear_session()
  M.session = nil
end

function M.next_request_id()
  local session = M.get_session()
  session.request_seq = session.request_seq + 1
  return string.format("sherpa-%d", session.request_seq)
end

function M.record_file(path)
  local session = M.get_session()
  session.last_touched_file = path
  local recent = { path }
  for _, item in ipairs(session.recent_files) do
    if item ~= path and #recent < 5 then
      table.insert(recent, item)
    end
  end
  session.recent_files = recent
end

function M.set_status(key, value)
  local session = M.get_session()
  session.status[key] = value
end

function M.set_widget(lines)
  local session = M.get_session()
  session.widget = lines or {}
end

function M.set_summary(text)
  local session = M.get_session()
  session.last_summary = text
end

function M.set_pending_request(operation, metadata)
  local session = M.get_session()
  if not operation then
    session.pending_request = nil
    return
  end
  session.pending_request = {
    operation = operation,
    metadata = metadata or {},
  }
end

function M.peek_pending_request()
  local session = M.get_session()
  return session.pending_request
end

function M.consume_pending_request()
  local session = M.get_session()
  local pending = session.pending_request
  session.pending_request = nil
  return pending
end

return M
