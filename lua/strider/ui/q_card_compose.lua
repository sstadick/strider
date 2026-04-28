local M = {}

local ns = vim.api.nvim_create_namespace("strider-q-card-compose")
local HINT = "Type a Q follow-up · <C-s> send"

local function trim_lines(lines)
  while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
  return lines
end

local function buffer_name(card)
  if card.compose_buffer_name then return card.compose_buffer_name end
  local seq = card.seq or tostring(card.id):match("(%d+)$") or "1"
  if card.buffer_name == "strider://StriderQAnswer" then return "strider://StriderQCompose" end
  return string.format("strider://flow-card/q-compose/%s", seq)
end

local function configure_buffer(buf)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
end

local function compose_win(card)
  if card.compose_win and vim.api.nvim_win_is_valid(card.compose_win) then return card.compose_win end
  local buf = card.compose_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return nil end
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then card.compose_win = win; return win end
  end
  card.compose_win = nil
  return nil
end

local function render_hint(card)
  local buf = card.compose_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  if vim.trim(text) ~= "" then return end
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, 0, 0, {
    virt_text = { { HINT, "Comment" } },
    virt_text_pos = "overlay",
  })
end

local function reset_undo(buf)
  vim.bo[buf].undolevels = -1
  vim.bo[buf].undolevels = vim.o.undolevels
end

local function clear_buffer(card)
  local buf = card.compose_buf
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    reset_undo(buf)
    render_hint(card)
  end
end

local function fold(card)
  local lane = card.compose_lane or "q"
  local session = require("strider.state").get_session(lane)
  if session then session.active_flow_card_id = nil end
  local ok, flow_cards = pcall(require, "strider.ui.flow_cards")
  if ok and flow_cards and flow_cards.reflow then flow_cards.reflow(lane) end
end

local function submit(card)
  local buf = M.ensure_buffer(card)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = vim.trim(table.concat(trim_lines(lines), "\n"))
  if text == "" then
    vim.notify("Type a Q follow-up first", vim.log.levels.WARN)
    M.focus(card, { insert = true })
    return
  end
  local ok, strider = pcall(require, "strider")
  if not ok or not strider.q_followup then
    vim.notify("Strider Q follow-up is unavailable", vim.log.levels.ERROR)
    return
  end
  if strider.q_followup(text) ~= false then clear_buffer(card) end
end

local function attach_buffer(card)
  local buf = card.compose_buf
  if vim.b[buf].strider_q_compose_attached then return end
  vim.b[buf].strider_q_compose_attached = true
  vim.keymap.set({ "n", "i" }, "<C-s>", function() submit(card) end, {
    buffer = buf, nowait = true, silent = true, desc = "Send Strider Q follow-up",
  })
  vim.keymap.set("n", "q", function() fold(card) end, {
    buffer = buf, nowait = true, silent = true, desc = "Fold Strider Q card",
  })
  vim.keymap.set("n", "<Esc>", function() fold(card) end, {
    buffer = buf, nowait = true, silent = true, desc = "Fold Strider Q card",
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = function() render_hint(card) end,
  })
end

local function configure_window(win)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].cursorline = false
  vim.wo[win].winhighlight = "NormalFloat:Normal,FloatBorder:FloatBorder"
end

function M.ensure_buffer(card)
  if card.compose_buf and vim.api.nvim_buf_is_valid(card.compose_buf) then return card.compose_buf end
  local name = buffer_name(card)
  local existing = vim.fn.bufnr(name)
  local buf = existing > 0 and existing or vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, name)
  configure_buffer(buf)
  card.compose_buf = buf
  card.compose_buffer_name = name
  attach_buffer(card)
  render_hint(card)
  return buf
end

function M.attach_answer(card)
  if not card or not card.buf or vim.b[card.buf].strider_q_compose_answer_attached then return end
  vim.b[card.buf].strider_q_compose_answer_attached = true
  local function start() M.focus(card, { insert = true }) end
  vim.keymap.set("n", "i", start, { buffer = card.buf, nowait = true, silent = true, desc = "Compose Strider Q follow-up" })
  vim.keymap.set("n", "a", start, { buffer = card.buf, nowait = true, silent = true, desc = "Compose Strider Q follow-up" })
end

function M.open(card, config, opts)
  opts = opts or {}
  local buf = M.ensure_buffer(card)
  local win = compose_win(card)
  if win then pcall(vim.api.nvim_win_set_config, win, config) else win = vim.api.nvim_open_win(buf, false, config) end
  configure_window(win)
  card.compose_win = win
  render_hint(card)
  if opts.focus then M.focus(card, { insert = opts.insert }) end
  return win
end

function M.close(card)
  local win = compose_win(card)
  if win then pcall(vim.api.nvim_win_close, win, true) end
  card.compose_win = nil
end

function M.focus(card, opts)
  opts = opts or {}
  local win = compose_win(card)
  if not win then return false end
  vim.api.nvim_set_current_win(win)
  local last = math.max(vim.api.nvim_buf_line_count(card.compose_buf), 1)
  local text = vim.api.nvim_buf_get_lines(card.compose_buf, last - 1, last, false)[1] or ""
  pcall(vim.api.nvim_win_set_cursor, win, { last, #text })
  if opts.insert then vim.cmd("startinsert") end
  return true
end

function M.clear(card) clear_buffer(card) end

return M
