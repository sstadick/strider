local flow_cards = require("strider.ui.flow_cards")
local state = require("strider.state")

local M = {}

local function normalize_lane(lane)
  return state.normalize_lane(lane)
end

local function display_path(path, lane)
  if not path or path == "" then return "(unknown)" end
  local session = state.get_session(lane)
  local cwd = session and session.cwd or vim.fn.getcwd()
  if cwd and cwd ~= "" and vim.startswith(path, cwd .. "/") then
    return path:sub(#cwd + 2)
  end
  return path
end

local function target_label(target, lane)
  if not target then return "(unknown target)" end
  local path = display_path(target.path, lane)
  local start_line = tonumber(target.startLine) or 1
  local end_line = tonumber(target.endLine) or start_line
  return string.format("%s:%d-%d", path, start_line, end_line)
end

local function add_unique(list, value)
  if not value or value == "" then return end
  for _, item in ipairs(list) do
    if item == value then return end
  end
  table.insert(list, value)
end

local function append_lines(out, text)
  for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
    table.insert(out, line)
  end
end

local function append_section(out, title, lines)
  table.insert(out, title)
  if not lines or #lines == 0 then
    table.insert(out, "- (none yet)")
  else
    vim.list_extend(out, lines)
  end
end

local function file_bullets(paths, lane)
  local lines = {}
  for _, path in ipairs(paths or {}) do
    table.insert(lines, "- " .. display_path(path, lane))
  end
  return lines
end

local function status_text(card)
  if card.assistant_summary and vim.trim(card.assistant_summary) ~= "" then
    return card.assistant_summary
  end
  if card.status == "running" then return "Patch is still running." end
  if card.status == "success" then return "Patch completed with no final summary." end
  return card.error_summary or "Patch stopped before a final summary."
end

local function append_diff_blocks(out, card, lane)
  if not card.diff_blocks or #card.diff_blocks == 0 then return end
  table.insert(out, "")
  table.insert(out, "Diffs")
  for _, block in ipairs(card.diff_blocks) do
    table.insert(out, "")
    table.insert(out, display_path(block.path, lane))
    table.insert(out, "```diff")
    append_lines(out, block.diff)
    table.insert(out, "```")
  end
end

local function render_body(card, lane)
  local lines = {}
  table.insert(lines, "Target: " .. target_label(card.target, lane))
  table.insert(lines, "")
  append_section(lines, "Files touched", file_bullets(card.edited_files, lane))
  table.insert(lines, "")
  append_section(lines, "Inspected", file_bullets(card.inspected_files, lane))
  table.insert(lines, "")
  append_section(lines, "Activity", card.tool_lines)
  append_diff_blocks(lines, card, lane)
  table.insert(lines, "")
  table.insert(lines, "Summary")
  append_lines(lines, status_text(card))
  return lines
end

local function folded_summary(status)
  if status == "success" then return "Patch complete — focus to expand" end
  if status == "error" then return "Patch failed — focus to expand" end
  if status == "cancelled" then return "Patch stopped — focus to expand" end
  return "Patch running…"
end

local function copy_with(card, fields)
  local next_card = vim.deepcopy(card or {})
  for key, value in pairs(fields or {}) do
    next_card[key] = value
  end
  return next_card
end

local function update_body(id, fields, lane)
  lane = normalize_lane(lane)
  local card = flow_cards.get_card(id, lane)
  if not card then return nil end
  local preview = copy_with(card, fields)
  fields = vim.tbl_extend("force", fields or {}, {
    body_lines = render_body(preview, lane),
  })
  return flow_cards.update_card(id, fields, lane)
end

function M.open(prompt, opts, lane)
  lane = normalize_lane(lane)
  opts = opts or {}
  local card = {
    title = "StriderPatch",
    prompt = prompt or "",
    operation = "patch",
    status = "running",
    target = opts.target,
    inspected_files = {},
    edited_files = {},
    tool_lines = {},
    diff_blocks = {},
    summary = folded_summary("running"),
  }
  card.body_lines = render_body(card, lane)
  local id = flow_cards.create_card("patch", card, lane)
  flow_cards.open_card(id, lane)
  return id
end

local function tool_line(tool, lane)
  local path = display_path(tool.path, lane)
  if tool.kind == "edit" then
    return string.format("• Edited %s (+%d -%d)", path, tool.added or 0, tool.removed or 0)
  end
  if tool.kind == "write" then return "• Wrote " .. path end
  if tool.kind == "read" then return "• Read " .. path end
  return "• Ran " .. (tool.kind or "tool")
end

function M.record_tool(id, tool, lane)
  lane = normalize_lane(lane)
  local card = flow_cards.get_card(id, lane)
  if not card then return nil end
  local inspected = vim.deepcopy(card.inspected_files or {})
  local edited = vim.deepcopy(card.edited_files or {})
  local tools = vim.deepcopy(card.tool_lines or {})
  local diffs = vim.deepcopy(card.diff_blocks or {})
  if tool.kind == "read" then add_unique(inspected, tool.path) end
  if tool.kind == "edit" or tool.kind == "write" then add_unique(edited, tool.path) end
  table.insert(tools, tool_line(tool, lane))
  if tool.diff and tool.diff ~= "" then
    table.insert(diffs, { path = tool.path, diff = tool.diff })
  end
  return update_body(id, {
    diff_blocks = diffs,
    edited_files = edited,
    inspected_files = inspected,
    tool_lines = tools,
  }, lane)
end

function M.finish(id, status, fields, lane)
  status = status or "success"
  fields = fields or {}
  local updates = {
    assistant_summary = fields.assistant_summary or fields.summary,
    error_summary = fields.error_summary,
    finished_at = vim.uv.hrtime(),
    status = status,
    summary = folded_summary(status),
  }
  return update_body(id, updates, lane)
end

return M
