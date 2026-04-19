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
    chunk_lines = {},
    chunk_path = nil,
    cwd = cwd,
    highlight_buf = nil,
    job_id = nil,
    last_summary = nil,
    last_touched_file = nil,
    recent_files = {},
    request_seq = 0,
    status = {},
    stdout_tail = "",
    stderr_tail = "",
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

return M
