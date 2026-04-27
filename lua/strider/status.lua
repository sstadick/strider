local state = require("strider.state")

local M = {}

local operation_labels = {
  command = "command",
  patch = "patch",
  plan = "plan",
  prompt = "chat",
  q = "Q",
  review = "review",
  search = "search",
}

local function op_label(operation)
  return operation_labels[operation] or operation or "request"
end

local function session_status(session)
  if not session then
    return "stopped"
  end
  if session.pending_clarify then
    return "waiting for clarify"
  end
  if session.progress then
    return "running " .. op_label(session.progress.operation)
  end
  if session.pending_request then
    return "pending " .. op_label(session.pending_request.operation)
  end
  if session.last_error and session.last_error ~= "" then
    return "failed"
  end
  if session.job_id then
    return "idle"
  end
  return "stopped"
end

function M.pending_action(lane)
  lane = state.normalize_lane(lane)
  local session = state.get_session(lane)
  if not session then
    return nil
  end
  if session.pending_clarify then
    return "<C-s> sends your clarify answer; <Esc><Esc> rejects it"
  end
  local pending = session.pending_request
  if pending and lane == "main" then
    if pending.operation == "command" then
      return "wait for the command to finish before sending another slash-command"
    end
    return "type to steer this turn; :StriderStop cancels it"
  end
  if pending and state.is_flow_lane(lane) then
    return ":StriderStopFlow cancels this flow worker"
  end
  if pending then
    return ":StriderStop cancels the main chat turn; wait for this lane to finish"
  end
  return nil
end

local function review_lines(session)
  local review = session and session.review
  if not review then
    return { "review: none" }
  end

  local accepted = 0
  for _, item in ipairs(review.items or {}) do
    if item.status == "accepted" then
      accepted = accepted + 1
    end
  end

  local state_text = "active"
  if review.planning then
    state_text = "planning"
  elseif review.awaiting_summary then
    state_text = "waiting for summary"
  elseif not review.active then
    state_text = "complete"
  elseif review.pending_question then
    state_text = "answering ranged question"
  end

  return {
    string.format("review: %s", state_text),
    string.format("review stop: %d/%d", review.current_index or 0, #(review.items or {})),
    string.format("accepted stops: %d/%d", accepted, #(review.items or {})),
    string.format("comments: %d", #(review.comments or {})),
  }
end

function M.lines()
  local lines = { "# Strider Status", "" }
  for _, lane in ipairs(state.lanes()) do
    local session = state.get_session(lane)
    table.insert(lines, string.format("## %s", lane))
    table.insert(lines, string.format("- state: `%s`", session_status(session)))
    if session and session.cwd then
      table.insert(lines, string.format("- cwd: `%s`", session.cwd))
    end
    local action = M.pending_action(lane)
    if action then
      table.insert(lines, string.format("- action: %s", action))
    end
    if session and session.last_summary and session.last_summary ~= "" then
      table.insert(lines, string.format("- last: %s", session.last_summary))
    end
    if session and session.last_error and session.last_error ~= "" then
      table.insert(lines, string.format("- error: %s", session.last_error))
    end
    if lane == "review" then
      for _, line in ipairs(review_lines(session)) do
        table.insert(lines, "- " .. line)
      end
    end
    if session and session.widget and #session.widget > 0 then
      for _, line in ipairs(session.widget) do
        if line and line ~= "" then
          table.insert(lines, "- " .. line)
        end
      end
    end
    table.insert(lines, "")
  end

  table.insert(lines, "## Controls")
  table.insert(lines, "- `:StriderStop` aborts the main in-flight turn.")
  table.insert(lines, "- `:StriderStopFlow` aborts active Q/Search/Patch flow workers.")
  table.insert(lines, "- Empty compose text shows whether `<C-s>` will send, steer, or answer clarify.")
  table.insert(lines, "- `:StriderNext!` accepts the current review stop and advances.")
  table.insert(lines, "- `:StriderRetry` retries a stalled review plan.")
  return lines
end

function M.session_status(lane)
  return session_status(state.get_session(lane))
end

return M
