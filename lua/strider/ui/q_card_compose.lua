local M = {}

local HEADER = "──────── Follow up ────────"
local HINT = "Type a follow-up here · <C-s> send"

local function trim_trailing_empty(lines)
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  return lines
end

local function find_card_win(card)
  if not card or not card.buf or not vim.api.nvim_buf_is_valid(card.buf) then return nil end
  local current = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(current) == card.buf then return current end
  for _, win in ipairs(vim.fn.win_findbuf(card.buf)) do
    if vim.api.nvim_win_is_valid(win) then return win end
  end
  return nil
end

function M.capture(card)
  if not card or card.kind ~= "q" or card._q_compose_rendering then return end
  if not card.buf or not vim.api.nvim_buf_is_valid(card.buf) then return end
  if not card.compose_start_row then return end
  local line_count = vim.api.nvim_buf_line_count(card.buf)
  if card.compose_start_row >= line_count then
    card.compose_text = ""
    return
  end
  local lines = vim.api.nvim_buf_get_lines(card.buf, card.compose_start_row, -1, false)
  card.compose_text = table.concat(trim_trailing_empty(lines), "\n")
end

function M.append(lines, card)
  table.insert(lines, "")
  table.insert(lines, HEADER)
  local header_row = #lines - 1
  local start_row = #lines
  local draft = card.compose_text or ""
  if vim.trim(draft) == "" then
    table.insert(lines, "")
  else
    vim.list_extend(lines, vim.split(draft, "\n", { plain = true }))
  end
  return header_row, start_row
end

function M.focus(card, opts)
  opts = opts or {}
  if not card or not card.compose_start_row then return false end
  local win = find_card_win(card)
  if not win then return false end
  vim.api.nvim_set_current_win(win)
  local line_count = vim.api.nvim_buf_line_count(card.buf)
  local row = math.max(1, math.min(card.compose_start_row + 1, line_count))
  pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })
  if opts.insert then vim.cmd("startinsert") end
  return true
end

function M.hint(card, ns)
  if not card or not card.compose_start_row then return end
  if vim.trim(card.compose_text or "") ~= "" then return end
  pcall(vim.api.nvim_buf_set_extmark, card.buf, ns, card.compose_start_row, 0, {
    virt_text = { { HINT, "Comment" } },
    virt_text_pos = "overlay",
  })
end

function M.attach(card)
  if not card or not card.buf or vim.b[card.buf].strider_q_compose_attached then return end
  vim.b[card.buf].strider_q_compose_attached = true

  local function start_compose()
    M.focus(card, { insert = true })
  end

  local function submit()
    M.capture(card)
    local text = vim.trim(card.compose_text or "")
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
    if strider.q_followup(text) ~= false then
      card.compose_text = ""
    end
  end

  vim.keymap.set("n", "i", start_compose, {
    buffer = card.buf, nowait = true, silent = true, desc = "Compose Strider Q follow-up",
  })
  vim.keymap.set("n", "a", start_compose, {
    buffer = card.buf, nowait = true, silent = true, desc = "Compose Strider Q follow-up",
  })
  vim.keymap.set({ "n", "i" }, "<C-s>", submit, {
    buffer = card.buf, nowait = true, silent = true, desc = "Send Strider Q follow-up",
  })
  vim.api.nvim_create_autocmd("InsertEnter", {
    buffer = card.buf,
    callback = function() M.focus(card) end,
  })
end

return M
