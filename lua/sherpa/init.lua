local rpc = require("sherpa.rpc")
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

local function send(command, user_text)
  if not ensure_backend() then
    return false
  end
  local ok = rpc.send_prompt(command)
  if ok and user_text and user_text ~= "" then
    ui.append_block("user", user_text)
  end
  return ok
end

local function active_session()
  local session = state.get_session()
  if session and session.job_id then
    return session
  end
  ui.notify("No active Sherpa session", vim.log.levels.WARN)
end

function M.setup(opts)
  state.setup(opts or {})
end

function M.start(goal)
  if not goal or goal == "" then
    ui.notify("Usage: :SherpaStart <goal>", vim.log.levels.WARN)
    return
  end
  send("/guide " .. goal, goal)
end

function M.question(question)
  if not active_session() then
    return
  end
  if not question or question == "" then
    ui.notify("Usage: :SherpaQ <question>", vim.log.levels.WARN)
    return
  end
  send("/question " .. question, question)
end

function M.next_step()
  if not active_session() then
    return
  end
  send("/next", "Continue with the next chunk.")
end

function M.revise(feedback)
  if not active_session() then
    return
  end
  if not feedback or feedback == "" then
    ui.notify("Usage: :SherpaRevise <feedback>", vim.log.levels.WARN)
    return
  end
  send("/revise " .. feedback, "Revise: " .. feedback)
end

function M.status()
  if not active_session() then
    return
  end
  ui.show_status()
  ui.show_log()
  send("/status")
end

return M
