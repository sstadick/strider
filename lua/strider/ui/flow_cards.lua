local highlights = require("strider.ui.highlights")
local state = require("strider.state")
local M = {}
local ns = vim.api.nvim_create_namespace("strider-flow-cards")
local G = highlights.groups
local log_user_hl = G.log_user
local log_rule_hl = G.log_rule
local log_muted_hl = G.log_muted
local compose_working_hl = G.compose_working
local FOLDED_HEIGHT = 3
local STACK_GAP = 1
local STACK_MARGIN_BOTTOM = 2
local EXPANDED_TOP_MARGIN = 1
local EXPANDED_BOTTOM_MARGIN = 3
local WORKING_LABEL = "Working"
local augroup = nil
local function normalize_lane(lane)
  return state.normalize_lane(lane)
end
local function escape_status_text(text)
  return (text or ""):gsub("%%", "%%%%")
end
local function format_elapsed(start_ns)
  if not start_ns then return nil end
  local elapsed_s = (vim.uv.hrtime() - start_ns) / 1e9
  if elapsed_s < 60 then
    return string.format("%ds", math.floor(elapsed_s))
  end
  if elapsed_s < 3600 then
    return string.format("%dm%02ds", math.floor(elapsed_s / 60), math.floor(elapsed_s % 60))
  end
  return string.format("%dh%02dm", math.floor(elapsed_s / 3600), math.floor((elapsed_s % 3600) / 60))
end
local function stop_command(lane)
  return normalize_lane(lane) == "flow" and ":StriderStopFlow" or ":StriderStop"
end
local function stop_hint(lane) return stop_command(lane) .. " to interrupt" end
local function working_label()
  highlights.ensure()
  return string.format("%%#%s#%s%%*", compose_working_hl, WORKING_LABEL)
end
local function configure_scratch_buffer(buf, filetype)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  if filetype then vim.bo[buf].filetype = filetype end
end
local function q_answer_name(lane)
  lane = normalize_lane(lane)
  if lane == "flow" then return "strider://StriderQAnswer" end
  return "strider://StriderQAnswer-" .. lane
end
local function ensure_card_state(session)
  session.flow_cards = session.flow_cards or {}
  session.flow_card_seq = session.flow_card_seq or 0
  return session.flow_cards
end
local function next_card_id(session)
  session.flow_card_seq = (session.flow_card_seq or 0) + 1
  return string.format("flow-card-%d", session.flow_card_seq)
end
local function card_by_id(session, id)
  if not session or not id then return nil end
  for _, card in ipairs(ensure_card_state(session)) do
    if card.id == id then
      return card
    end
  end
  return nil
end
local function card_buffer_name(card, lane)
  if card.buffer_name then
    return card.buffer_name
  end
  local seq = card.seq or tostring(card.id):match("(%d+)$") or "1"
  return string.format("strider://flow-card/%s/%s", card.kind or "card", seq)
end
local function ensure_card_buffer(card, lane)
  if card.buf and vim.api.nvim_buf_is_valid(card.buf) then
    return card.buf
  end
  local name = card_buffer_name(card, lane)
  local existing = vim.fn.bufnr(name)
  local buf = existing > 0 and existing or vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, name)
  configure_scratch_buffer(buf, "markdown")
  vim.bo[buf].bufhidden = "hide"
  vim.b[buf].strider_flow_card = card.id
  vim.b[buf].strider_flow_card_kind = card.kind
  if card.kind == "q" then
    vim.b[buf].strider_q_answer = true
  end
  card.buf = buf
  return buf
end
local function sync_legacy_q(session, card)
  if not session or not card or card.kind ~= "q" then return end
  session.q_answer_card_id = card.id
  session.q_answer_buf = card.buf
  session.q_answer_win = card.win
  session.q_answer_prompt = card.prompt or ""
  session.q_answer_text = card.answer_text or ""
  session.q_answer_done = card.status ~= "running"
  session.q_answer_status = card.status == "running" and nil or (card.status == "cancelled" and "error" or card.status)
end
local function card_window(card)
  if not card then return nil end
  if card.win and vim.api.nvim_win_is_valid(card.win) then
    return card.win
  end
  local buf = card.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return nil end
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      card.win = win
      return win
    end
  end
  card.win = nil
  return nil
end
local function current_card_id(session)
  local current = vim.api.nvim_get_current_win()
  for _, card in ipairs(ensure_card_state(session)) do
    local win = card_window(card)
    if win and win == current then
      return card.id
    end
  end
  return nil
end
local function card_is_expanded(session, card)
  return session and card and current_card_id(session) == card.id
end
local function ui_size()
  return vim.api.nvim_list_uis()[1] or { width = 120, height = 30 }
end
local function card_width(width)
  return math.min(88, math.max(42, math.floor(width * 0.42)))
end
local function folded_row(ui_height, stack_index)
  local step = FOLDED_HEIGHT + 2 + STACK_GAP
  return math.max(ui_height - FOLDED_HEIGHT - STACK_MARGIN_BOTTOM - step * (stack_index - 1), 0)
end
local function card_config(session, card, stack_index)
  local info = ui_size()
  local expanded = card_is_expanded(session, card)
  local width = card_width(info.width)
  local height = expanded and math.max(FOLDED_HEIGHT, info.height - EXPANDED_BOTTOM_MARGIN - 1) or FOLDED_HEIGHT
  return {
    relative = "editor",
    anchor = "NW",
    row = expanded and EXPANDED_TOP_MARGIN or folded_row(info.height, stack_index or 1),
    col = math.max(info.width - width - 1, 0),
    width = width,
    height = height,
    border = "rounded",
    title = " " .. (card.title or "Strider flow") .. " ",
    title_pos = "left",
    style = "minimal",
    focusable = true,
    zindex = expanded and 60 or 40,
  }
end
local function configure_card_window(win)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].cursorline = false
  vim.wo[win].winhighlight = "NormalFloat:Normal,FloatBorder:FloatBorder"
end
local function preview_text(text)
  local preview = vim.trim((text or ""):gsub("%s+", " "))
  if preview == "" then preview = "(no question)" end
  if vim.fn.strchars(preview) > 74 then
    preview = vim.fn.strcharpart(preview, 0, 73) .. "…"
  end
  return preview
end
local function q_compact_status(card)
  local body = card.answer_text or ""
  local has_body = vim.trim(body) ~= ""
  local done = card.status ~= "running"
  if has_body and done and card.status ~= "success" then
    return "Stopped — focus to expand"
  end
  if has_body and done then
    return "Answer ready — focus to expand"
  end
  if has_body then
    return "Answer streaming — focus to expand"
  end
  if done then
    return card.status ~= "success" and "Strider Q stopped before an answer." or "Strider Q completed with no answer."
  end
  return "Waiting for Strider…"
end
local function q_card_lines(card, expanded)
  if not expanded then
    return {
      "› " .. preview_text(card.prompt),
      "────────────────────────────────",
      q_compact_status(card),
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
    table.insert(lines, card.status ~= "success" and "Strider Q stopped before an answer." or "Strider Q completed with no answer.")
  else
    table.insert(lines, "Waiting for Strider…")
  end
  return lines, #question_lines, separator_row, body_row
end
local function generic_card_lines(card, expanded)
  local lines = {}
  table.insert(lines, "› " .. preview_text(card.prompt))
  table.insert(lines, "────────────────────────────────")
  if expanded and card.body_lines and #card.body_lines > 0 then
    vim.list_extend(lines, card.body_lines)
  else
    table.insert(lines, card.summary or "Waiting for Strider…")
  end
  return lines, 1, 1, 2
end
local function render_card(session, card)
  local buf = ensure_card_buffer(card, session.lane)
  local expanded = card_is_expanded(session, card)
  local lines, question_count, separator_row, body_row
  if card.kind == "q" then
    lines, question_count, separator_row, body_row = q_card_lines(card, expanded)
  else
    lines, question_count, separator_row, body_row = generic_card_lines(card, expanded)
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for row = 0, question_count - 1 do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, {
      end_row = row + 1,
      hl_group = log_user_hl,
      priority = 10,
    })
  end
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, separator_row, 0, {
    end_row = separator_row + 1,
    hl_group = log_rule_hl,
    priority = 10,
  })
  if card.status == "running" and vim.trim(card.answer_text or "") == "" then
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, body_row, 0, {
      end_row = body_row + 1,
      hl_group = log_muted_hl,
      priority = 10,
    })
  end
  vim.bo[buf].modifiable = false
end
local function card_winbar(card, lane)
  local session = state.get_session(lane)
  if session and session.progress and card.status == "running" then
    local elapsed = format_elapsed(session.progress.started_at) or "0s"
    local title = session.progress.title or (card.title or "Strider flow") .. " running..."
    local left = working_label() .. escape_status_text(string.format(" (%s) · %s", elapsed, title))
    return left .. "%=" .. escape_status_text(stop_hint(lane))
  end
  if card.status ~= "running" then
    if card.kind == "q" then
      return escape_status_text(card.status == "success" and "StriderQ answer ready" or "StriderQ stopped")
    end
    if card.kind == "patch" then
      return escape_status_text(card.status == "success" and "StriderPatch complete" or "StriderPatch stopped")
    end
  end
  return escape_status_text(card.title or "Strider flow")
end
local function open_card_window(session, card)
  local buf = ensure_card_buffer(card, session.lane)
  local win = card_window(card)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_set_config, win, card_config(session, card, 1))
  else
    win = vim.api.nvim_open_win(buf, false, card_config(session, card, 1))
  end
  configure_card_window(win)
  card.win = win
  sync_legacy_q(session, card)
  return win
end
local function sorted_cards(session)
  local cards = vim.tbl_filter(function(card)
    return not card.dismissed
  end, ensure_card_state(session))
  table.sort(cards, function(a, b)
    return (a.started_at or 0) < (b.started_at or 0)
  end)
  return cards
end
function M.reflow(lane)
  lane = normalize_lane(lane)
  local session = state.get_session(lane)
  if not session then return end
  session.active_flow_card_id = current_card_id(session)
  local stack_index = 1
  local cards = sorted_cards(session)
  for i = #cards, 1, -1 do
    local card = cards[i]
    local win = card_window(card)
    if win and vim.api.nvim_win_is_valid(win) then
      render_card(session, card)
      pcall(vim.api.nvim_win_set_config, win, card_config(session, card, stack_index))
      pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
      pcall(function() vim.wo[win].winbar = card_winbar(card, lane) end)
      sync_legacy_q(session, card)
      if not card_is_expanded(session, card) then
        stack_index = stack_index + 1
      end
    else
      card.win = nil
      sync_legacy_q(session, card)
    end
  end
end
function M.refresh_layouts()
  for _, lane in ipairs(state.lanes()) do
    M.reflow(lane)
  end
end
function M.refresh_winbars(lane)
  lane = normalize_lane(lane)
  local session = state.get_session(lane)
  if not session then return end
  for _, card in ipairs(ensure_card_state(session)) do
    local win = card_window(card)
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(function() vim.wo[win].winbar = card_winbar(card, lane) end)
    end
  end
end
local function ensure_autocmds()
  if augroup then return end
  augroup = vim.api.nvim_create_augroup("StriderFlowCardsLayout", { clear = true })
  vim.api.nvim_create_autocmd({ "WinEnter", "WinLeave", "BufEnter", "WinClosed", "VimResized" }, {
    group = augroup,
    callback = function()
      vim.schedule(function()
        M.refresh_layouts()
      end)
    end,
  })
end
function M.get_card(id, lane)
  lane = normalize_lane(lane)
  return card_by_id(state.get_session(lane), id)
end
function M.open_card(id, lane)
  ensure_autocmds()
  lane = normalize_lane(lane)
  local session = state.get_session(lane)
  local card = card_by_id(session, id)
  if not card then return nil end
  render_card(session, card)
  local win = open_card_window(session, card)
  M.reflow(lane)
  return win
end
function M.create_card(kind, opts, lane)
  ensure_autocmds()
  lane = normalize_lane(lane)
  local session = state.get_session(lane)
  if not session then return nil end
  opts = opts or {}
  local card = vim.tbl_extend("force", {
    id = opts.id or next_card_id(session),
    kind = kind,
    operation = opts.operation or kind,
    title = opts.title or "Strider flow",
    prompt = opts.prompt or "",
    status = opts.status or "running",
    answer_text = opts.answer_text or "",
    body_lines = opts.body_lines,
    summary = opts.summary,
    started_at = opts.started_at or vim.uv.hrtime(),
    finished_at = opts.finished_at,
    buffer_name = opts.buffer_name,
  }, opts)
  table.insert(ensure_card_state(session), card)
  ensure_card_buffer(card, lane)
  sync_legacy_q(session, card)
  return card.id
end
function M.update_card(id, fields, lane)
  lane = normalize_lane(lane)
  local session = state.get_session(lane)
  local card = card_by_id(session, id)
  if not card then return nil end
  for key, value in pairs(fields or {}) do
    card[key] = value
  end
  render_card(session, card)
  sync_legacy_q(session, card)
  M.reflow(lane)
  return card
end
function M.finish_card(id, status, fields, lane)
  fields = fields or {}
  fields.status = status or fields.status or "success"
  fields.finished_at = fields.finished_at or vim.uv.hrtime()
  return M.update_card(id, fields, lane)
end
local function ensure_q_card(prompt, lane)
  lane = normalize_lane(lane)
  local session = state.get_session(lane)
  if not session then return nil end
  local card = card_by_id(session, session.q_answer_card_id)
  if card then
    card.prompt = prompt or ""
    card.answer_text = ""
    card.status = "running"
    card.finished_at = nil
    card.started_at = vim.uv.hrtime()
    card.title = "Strider Q"
    card.buffer_name = q_answer_name(lane)
    sync_legacy_q(session, card)
    return card
  end
  local id = M.create_card("q", {
    title = "Strider Q",
    prompt = prompt or "",
    operation = "q",
    buffer_name = q_answer_name(lane),
  }, lane)
  return card_by_id(session, id)
end
function M.ensure_q_answer_buffer(lane)
  lane = normalize_lane(lane)
  local session = state.get_session(lane)
  if not session then return nil end
  local card = card_by_id(session, session.q_answer_card_id) or ensure_q_card(session.q_answer_prompt, lane)
  if not card then return nil end
  local buf = ensure_card_buffer(card, lane)
  sync_legacy_q(session, card)
  return buf
end
function M.open_q_answer(prompt, lane)
  ensure_autocmds()
  lane = normalize_lane(lane)
  local session = state.get_session(lane)
  if not session then return nil end
  local card = ensure_q_card(prompt, lane)
  if not card then return nil end
  render_card(session, card)
  local win = open_card_window(session, card)
  M.reflow(lane)
  return win
end
function M.update_q_answer(text, lane)
  lane = normalize_lane(lane)
  local session = state.get_session(lane)
  if not session then return end
  local card = card_by_id(session, session.q_answer_card_id)
  if not card then return end
  M.update_card(card.id, { answer_text = text or "", status = "running" }, lane)
end
function M.finish_q_answer(text, status, lane)
  lane = normalize_lane(lane)
  local session = state.get_session(lane)
  if not session then return end
  local card = card_by_id(session, session.q_answer_card_id)
  if not card then return end
  local fields = {}
  if text ~= nil then fields.answer_text = text end
  M.finish_card(card.id, status or "success", fields, lane)
end
function M.refresh_q_answer_winbar(lane) M.refresh_winbars(lane) end
function M.refresh_q_answer_layouts() M.refresh_layouts() end
return M
