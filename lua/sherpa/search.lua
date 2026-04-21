local picker = require("sherpa.picker")
local state = require("sherpa.state")
local ui = require("sherpa.ui")

local M = {}

local function is_absolute(path)
  return path:match("^/") ~= nil
    or path:match("^%a:[/\\]") ~= nil
    or path:match("^\\\\") ~= nil
end

local function absolute_path(path)
  if path == nil or path == "" then
    return nil
  end
  if is_absolute(path) then
    return path
  end
  local session = state.get_session()
  if not session then
    return nil
  end
  return vim.fs.joinpath(session.cwd, path)
end

local function truncate(text, width)
  width = width or 80
  if #text <= width then
    return text
  end
  return text:sub(1, width - 1) .. "…"
end

local function parse_line(line)
  line = line:gsub("^[-*]%s+", "")
  line = line:gsub("^`+", ""):gsub("`+$", "")
  local path, lnum_raw, rest = line:match("^(.-):([^:]+):(.+)$")
  if not path or not lnum_raw or not rest then
    return nil
  end

  local col_raw, count_raw, notes = rest:match("^([^,]+),([^,]+),?(.*)$")
  if not col_raw or not count_raw then
    return nil
  end

  local lnum = tonumber(lnum_raw) or 1
  local col = tonumber(col_raw) or 1
  local count = math.max(tonumber(count_raw) or 1, 1)
  local filename = absolute_path(path)
  if not filename then
    return nil
  end

  return {
    filename = filename,
    lnum = lnum,
    end_lnum = lnum + count - 1,
    col = col,
    count = count,
    text = notes or "",
  }
end

local function summary_label(prompt, count)
  return string.format("%s (%d result%s)", truncate(prompt, 70), count, count == 1 and "" or "s")
end

local function quickfix_items(results)
  local items = {}
  for _, result in ipairs(results or {}) do
    table.insert(items, {
      filename = result.filename,
      lnum = result.lnum,
      end_lnum = result.end_lnum,
      col = result.col,
      text = result.text,
    })
  end
  return items
end

local function result_label(result)
  local notes = result.text ~= "" and result.text or "Search result"
  return string.format(
    "%s:%d-%d %s",
    vim.fn.fnamemodify(result.filename, ":."),
    result.lnum,
    result.end_lnum,
    truncate(notes, 90)
  )
end

function M.open_result(result)
  if not result then
    return false
  end
  ui.jump_to_file(result.filename, result.lnum)
  ui.highlight_range(result.filename, result.lnum, result.end_lnum)
  return true
end

local function store_quickfix(result_set, open)
  ui.set_quickfix(
    "Sherpa Search: " .. truncate(result_set.prompt or "results", 50),
    quickfix_items(result_set.results),
    open
  )
end

local function present_result_set(result_set)
  local count = #result_set.results

  if picker.available() then
    local items = {}
    for _, result in ipairs(result_set.results) do
      table.insert(items, {
        label = result_label(result),
        value = result,
      })
    end
    store_quickfix(result_set, false)
    return picker.select("Sherpa Search Results", items, function(item)
      M.open_result(item.value)
    end)
  end

  store_quickfix(result_set, true)
  if count == 1 then
    M.open_result(result_set.results[1])
  end
  return true
end

function M.open_result_set(result_set)
  local session = state.get_session()
  if not result_set or not result_set.results or #result_set.results == 0 then
    ui.notify("No search results available", vim.log.levels.WARN)
    return false
  end

  if session and session.search_history then
    local reordered = { result_set }
    for _, item in ipairs(session.search_history) do
      if item ~= result_set then
        table.insert(reordered, item)
      end
    end
    session.search_history = reordered
  end

  return present_result_set(result_set)
end

function M.handle_response(text, metadata)
  local session = state.get_session()
  if not session then
    return nil
  end
  local prompt = metadata and metadata.prompt or "Sherpa search"
  local results = {}

  for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
    local result = parse_line(vim.trim(line))
    if result then
      table.insert(results, result)
    end
  end

  local result_set = {
    id = string.format("search-%d", session.request_seq),
    prompt = prompt,
    raw = text,
    created_at = os.time(),
    results = results,
    label = summary_label(prompt, #results),
  }

  table.insert(session.search_history, 1, result_set)
  if #session.search_history > 20 then
    table.remove(session.search_history)
  end

  if #results == 0 then
    ui.notify("Sherpa search returned no structured results", vim.log.levels.INFO)
    return result_set
  end

  M.open_result_set(result_set)
  return result_set
end

function M.summary_text(result_set)
  if not result_set then
    return "Sherpa search finished."
  end
  local count = #(result_set.results or {})
  if count == 0 then
    return string.format("Sherpa search: no matches for '%s'", result_set.prompt or "search")
  end
  if count == 1 then
    return string.format("Sherpa search: 1 match for '%s'", result_set.prompt or "search")
  end
  return string.format("Sherpa search: %d matches for '%s'", count, result_set.prompt or "search")
end

function M.last_result_set()
  local session = state.get_session()
  return session and session.search_history[1] or nil
end

function M.history_picker()
  local session = state.get_session()
  if not session then
    ui.notify("No Sherpa searches recorded yet", vim.log.levels.WARN)
    return false
  end
  local items = {}
  for _, result_set in ipairs(session.search_history or {}) do
    table.insert(items, {
      label = result_set.label,
      value = result_set,
    })
  end

  if #items == 0 then
    ui.notify("No Sherpa searches recorded yet", vim.log.levels.WARN)
    return false
  end

  return picker.select("Sherpa Searches", items, function(item)
    M.open_result_set(item.value)
  end)
end

function M.to_review_items(result_set)
  local items = {}
  for index, result in ipairs((result_set and result_set.results) or {}) do
    local note = result.text ~= "" and result.text or "Search result"
    table.insert(items, {
      id = string.format("search-item-%d", index),
      path = result.filename,
      startLine = result.lnum,
      endLine = result.end_lnum,
      kind = "search-result",
      title = note,
      summary = note,
    })
  end
  return items
end

return M
