local compose = require("strider.ui.q_card_compose")
local state = require("strider.state")

local M = {}

local function preview_text(text)
  local preview = vim.trim((text or ""):gsub("%s+", " "))
  if preview == "" then preview = "(no question)" end
  if vim.fn.strchars(preview) > 74 then
    preview = vim.fn.strcharpart(preview, 0, 73) .. "…"
  end
  return preview
end

local function compact_status(card)
  local body = card.answer_text or ""
  local has_body = vim.trim(body) ~= ""
  local done = card.status ~= "running"
  if has_body and done and card.status ~= "success" then return "Stopped — focus to expand" end
  if has_body and done then return "Answer ready — focus to expand" end
  if has_body then return "Answer streaming — focus to expand" end
  if done then
    if card.status ~= "success" then return "Strider Q stopped before an answer." end
    return "Strider Q completed with no answer."
  end
  return "Waiting for Strider…"
end

function M.answer_name(lane)
  lane = state.normalize_lane(lane)
  if lane == "q" or lane == "flow" then return "strider://StriderQAnswer" end
  return "strider://StriderQAnswer-" .. lane
end

function M.sync_legacy(session, card)
  if not session or not card or card.kind ~= "q" then return end
  session.q_answer_card_id = card.id
  session.q_answer_buf = card.buf
  session.q_answer_win = card.win
  session.q_answer_prompt = card.prompt or ""
  session.q_answer_text = card.answer_text or ""
  session.q_answer_done = card.status ~= "running"
  session.q_answer_status = card.status == "running" and nil or (card.status == "cancelled" and "error" or card.status)
end

function M.lines(card, expanded)
  if not expanded then
    return {
      "› " .. preview_text(card.prompt),
      "────────────────────────────────",
      compact_status(card),
    }, 1, 1, 2
  end

  local question = vim.trim(card.prompt or "")
  local question_lines = vim.split(question ~= "" and question or "(no question)", "\n", { plain = true })
  local lines = {}
  for index, line in ipairs(question_lines) do
    table.insert(lines, (index == 1 and "› " or "  ") .. line)
  end

  local separator_row = #lines
  table.insert(lines, "────────────────────────────────")
  local body = card.answer_text or ""
  local has_body = vim.trim(body) ~= ""
  if has_body then table.insert(lines, "") end
  local body_row = #lines
  if has_body then
    vim.list_extend(lines, vim.split(body, "\n", { plain = true }))
  elseif card.status ~= "running" then
    local message = card.status ~= "success" and "Strider Q stopped before an answer." or "Strider Q completed with no answer."
    table.insert(lines, message)
  else
    table.insert(lines, "Waiting for Strider…")
  end

  local compose_header_row, compose_start_row = compose.append(lines, card)
  return lines, #question_lines, separator_row, body_row, compose_header_row, compose_start_row
end

return M
