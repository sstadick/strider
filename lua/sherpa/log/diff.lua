local M = {}

local function replace_tabs(text)
  return (text or ""):gsub("\t", "   ")
end

local function trim_fenced_lines(text)
  local lines = {}
  for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
    if line:match("^```") then
      -- Older callers wrapped edit diffs in ```diff fences.
    elseif line ~= "" or #lines > 0 then
      table.insert(lines, line)
    end
  end
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  return lines
end

function M.content_lines(text)
  return trim_fenced_lines(text)
end

local function parse_numbered(line)
  local sign, number, content = line:match("^([+%- ])(%s*%d*)%s(.*)$")
  if not sign then return nil end
  local kind = sign == "+" and "add" or sign == "-" and "remove" or "context"
  return {
    kind = kind,
    sign = sign,
    line_num = vim.trim(number or ""),
    content = replace_tabs(content),
  }
end

local function parse_plain(line)
  if line:match("^%+") and not line:match("^%+%+%+") then
    return { kind = "add", sign = "+", line_num = "", content = replace_tabs(line:sub(2)) }
  end
  if line:match("^%-") and not line:match("^%-%-%-") then
    return { kind = "remove", sign = "-", line_num = "", content = replace_tabs(line:sub(2)) }
  end
  if line:match("^%.%.%.") or line:match("^@@") then
    return { kind = "meta", raw = line }
  end
  return { kind = "context", sign = " ", line_num = "", content = replace_tabs(line) }
end

local function parse_line(line)
  return parse_numbered(line) or parse_plain(line)
end

local function line_num_width(rows)
  local width = 1
  for _, row in ipairs(rows) do
    width = math.max(width, #(row.line_num or ""))
  end
  return width
end

local function render_row(row, width)
  if row.kind == "meta" then
    return "     │ " .. row.raw
  end
  local number = row.line_num ~= "" and row.line_num or string.rep(" ", width)
  local padded = string.rep(" ", width - #number) .. number
  local prefix = "  " .. row.sign .. padded .. " │ "
  row.sign_col = 2
  row.number_col = 3
  row.number_end_col = 3 + #padded
  row.gutter_col = #prefix - #"│ "
  row.content_col = #prefix
  return prefix .. row.content
end

function M.render(text)
  local rows = {}
  for _, line in ipairs(trim_fenced_lines(text)) do
    table.insert(rows, parse_line(line))
  end

  local width = line_num_width(rows)
  local lines = {}
  for index, row in ipairs(rows) do
    row.index = index - 1
    table.insert(lines, render_row(row, width))
  end
  table.insert(lines, "")
  return lines, rows
end

local function row_group(row, groups)
  if row.kind == "add" then return groups.add end
  if row.kind == "remove" then return groups.remove end
  if row.kind == "context" then return groups.context end
end

local function sign_group(row, groups)
  if row.kind == "add" then return groups.add_sign end
  if row.kind == "remove" then return groups.remove_sign end
end

function M.highlight_rows(buf, ns, start_line, rows, groups)
  for _, row in ipairs(rows) do
    local line = start_line + row.index
    local bg = row_group(row, groups)
    if bg then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, line, 0, {
        end_row = line + 1,
        hl_group = bg,
        hl_eol = row.kind ~= "context",
        priority = 8,
      })
    end

    local sign_hl = sign_group(row, groups)
    if sign_hl then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, line, row.sign_col, {
        end_row = line,
        end_col = row.sign_col + 1,
        hl_group = sign_hl,
        priority = 14,
      })
    end
    if row.number_col and row.number_end_col then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, line, row.number_col, {
        end_row = line,
        end_col = row.number_end_col,
        hl_group = groups.line_number,
        priority = 13,
      })
    end
    if row.gutter_col then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, line, row.gutter_col, {
        end_row = line,
        end_col = row.content_col,
        hl_group = groups.gutter,
        priority = 13,
      })
    end
  end
end

local function highlight_query(lang)
  local ok, query = pcall(function()
    if vim.treesitter.query.get then
      return vim.treesitter.query.get(lang, "highlights")
    end
    return vim.treesitter.query.get_query(lang, "highlights")
  end)
  return ok and query or nil
end

local function parser_for(buf, lang)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, lang)
  return ok and parser or nil
end

local function code_rows(rows)
  local lines = {}
  local map = {}
  for _, row in ipairs(rows) do
    if row.content_col and row.kind ~= "meta" then
      table.insert(lines, row.content or "")
      map[#lines] = row
    end
  end
  return lines, map
end

local function apply_capture(buf, ns, start_line, row, range, group)
  local sr, sc, er, ec = unpack(range)
  local end_col = er == sr and ec or #row.content
  if end_col <= sc then return end
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, start_line + row.index, row.content_col + sc, {
    end_row = start_line + row.index,
    end_col = row.content_col + end_col,
    hl_group = group,
    priority = 16,
  })
end

function M.highlight_syntax(buf, ns, start_line, rows, lang)
  if not lang or lang == "" then return end
  local query = highlight_query(lang)
  if not query then return end
  local lines, map = code_rows(rows)
  if #lines == 0 then return end

  local scratch = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch].filetype = lang
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, lines)
  local parser = parser_for(scratch, lang)
  if not parser then
    pcall(vim.api.nvim_buf_delete, scratch, { force = true })
    return
  end

  local trees = parser:parse()
  local group_prefix = "@"
  for _, tree in ipairs(trees or {}) do
    for id, node in query:iter_captures(tree:root(), scratch, 0, #lines) do
      local row = map[(select(1, node:range())) + 1]
      if row then
        apply_capture(buf, ns, start_line, row, { node:range() }, group_prefix .. query.captures[id])
      end
    end
  end
  pcall(vim.api.nvim_buf_delete, scratch, { force = true })
end

return M
