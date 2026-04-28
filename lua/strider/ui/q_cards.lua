local state = require("strider.state")

local M = {}

local function preview_text(text)
  local preview = vim.trim((text or ""):gsub("%s+", " "))
  if preview == "" then preview = "(no question)" end
  if vim.fn.strchars(preview) > 74 then preview = vim.fn.strcharpart(preview, 0, 73) .. "…" end
  return preview
end

local function ensure_turns(card)
  if card.turns and #card.turns > 0 then return card.turns end
  card.turns = { {
    answer_text = card.answer_text or "",
    finished_at = card.finished_at,
    prompt = card.prompt or "",
    started_at = card.started_at,
    status = card.status or "running",
  } }
  card.current_turn_index = 1
  return card.turns
end

local function current_turn(card)
  local turns = ensure_turns(card)
  return turns[card.current_turn_index or #turns] or turns[#turns]
end

local function turn_status(turn)
  return turn and turn.status or "running"
end

local function compact_status(card)
  local turn = current_turn(card)
  local body = turn.answer_text or ""
  local status = turn_status(turn)
  local has_body = vim.trim(body) ~= ""
  local done = status ~= "running"
  if has_body and done and status ~= "success" then return "Stopped — focus to expand" end
  if has_body and done then return "Answer ready — focus to expand" end
  if has_body then return "Answer streaming — focus to expand" end
  if done then
    if status ~= "success" then return "StriderQ stopped before an answer." end
    return "StriderQ completed with no answer."
  end
  return "Waiting for Strider…"
end

local function answer_lines(turn)
  local body = turn.answer_text or ""
  local has_body = vim.trim(body) ~= ""
  if has_body then return vim.split(body, "\n", { plain = true }) end
  if turn_status(turn) ~= "running" then
    local stopped = "StriderQ stopped before an answer."
    return { turn_status(turn) == "success" and "StriderQ completed with no answer." or stopped }
  end
  return { "Waiting for Strider…" }
end

local function append_question(lines, prompt)
  local question = vim.trim(prompt or "")
  local question_lines = vim.split(question ~= "" and question or "(no question)", "\n", { plain = true })
  for index, line in ipairs(question_lines) do table.insert(lines, (index == 1 and "› " or "  ") .. line) end
  return #question_lines
end

local function append_turn(lines, turn, index)
  if index > 1 then table.insert(lines, "") end
  local question_count = append_question(lines, turn.prompt)
  local separator_row = #lines
  table.insert(lines, "────────────────────────────────")
  local answers = answer_lines(turn)
  if vim.trim(turn.answer_text or "") ~= "" then table.insert(lines, "") end
  local body_row = #lines
  vim.list_extend(lines, answers)
  return question_count, separator_row, body_row
end

function M.answer_name(lane)
  lane = state.normalize_lane(lane)
  if lane == "q" or lane == "flow" then return "strider://StriderQAnswer" end
  return "strider://StriderQAnswer-" .. lane
end

function M.start_turn(card, prompt)
  local turns = ensure_turns(card)
  local turn = { prompt = prompt or "", answer_text = "", status = "running", started_at = vim.uv.hrtime() }
  table.insert(turns, turn)
  card.current_turn_index = #turns
  card.answer_text = ""; card.status = "running"; card.started_at = turn.started_at
  if not card.prompt or card.prompt == "" then card.prompt = turn.prompt end
  return turn
end

function M.update_turn(card, text)
  local turn = current_turn(card)
  turn.answer_text = text or ""; turn.status = "running"
  card.answer_text = turn.answer_text; card.status = "running"
end

function M.finish_turn(card, text, status)
  local turn = current_turn(card)
  if text ~= nil then turn.answer_text = text end
  turn.status = status or "success"; turn.finished_at = vim.uv.hrtime()
  card.answer_text = turn.answer_text or ""; card.status = turn.status; card.finished_at = turn.finished_at
end

function M.sync_legacy(session, card)
  if not session or not card or card.kind ~= "q" then return end
  if session.q_answer_card_id and session.q_answer_card_id ~= card.id then return end
  local turn = current_turn(card)
  session.q_answer_card_id = card.id; session.q_answer_buf = card.buf; session.q_answer_win = card.win
  session.q_answer_prompt = turn.prompt or card.prompt or ""; session.q_answer_text = turn.answer_text or ""
  session.q_answer_done = turn_status(turn) ~= "running"
  session.q_answer_status = turn_status(turn) == "running" and nil or (turn_status(turn) == "cancelled" and "error" or turn_status(turn))
end

function M.lines(card, expanded)
  local turns = ensure_turns(card)
  if not expanded then
    return { "› " .. preview_text(card.prompt or current_turn(card).prompt), "────────────────────────────────", compact_status(card) }, 1, 1, 2
  end

  local lines = {}
  local question_count, separator_row, body_row = 1, 1, 2
  for index, turn in ipairs(turns) do
    local q_count, sep_row, row = append_turn(lines, turn, index)
    if index == 1 then question_count, separator_row = q_count, sep_row end
    if index == (card.current_turn_index or #turns) then body_row = row end
  end
  return lines, question_count, separator_row, body_row
end

return M
