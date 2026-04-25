local M = {}

local function truncate(text, width)
  width = width or 72
  if #text <= width then
    return text
  end
  return text:sub(1, width - 1) .. "…"
end

local function first_meaningful_line(text)
  for _, raw in ipairs(vim.split(text or "", "\n", { plain = true })) do
    local line = vim.trim(raw)
    if line ~= ""
      and not line:match("^#")
      and not line:match("^//")
      and not line:match("^%-%-")
      and not line:match("^/%*")
      and not line:match("^%*")
      and line ~= "{" and line ~= "}" and line ~= "end" then
      return line
    end
  end
  return nil
end

local synopsis_patterns = {
  "^local%s+function%s+([%w_]+)",
  "^function%s+([%w_%.:]+)",
  "^export%s+function%s+([%w_]+)",
  "^async%s+function%s+([%w_]+)",
  "^def%s+([%w_]+)",
  "^class%s+([%w_]+)",
  "^interface%s+([%w_]+)",
  "^type%s+([%w_]+)",
  "^const%s+([%w_]+)%s*=",
  "^let%s+([%w_]+)%s*=",
  "^var%s+([%w_]+)%s*=",
  "^fn%s+([%w_]+)",
  "^struct%s+([%w_]+)",
  "^enum%s+([%w_]+)",
}

local function import_synopsis(line)
  if line:match("^import%s") or line:match("^from%s") then
    return "Imports and setup"
  end
  if line:match("^require%(") or line:match("^use%s") then
    return "Imports and setup"
  end
end

local function declaration_synopsis(line)
  for _, pattern in ipairs(synopsis_patterns) do
    local name = line:match(pattern)
    if name then
      return "Defines " .. name
    end
  end
end

local function excerpt_synopsis(text)
  local line = first_meaningful_line(text)
  if not line then return nil end
  return import_synopsis(line) or declaration_synopsis(line) or truncate(line)
end

function M.chunk_title(_path, fallback_title, excerpt_text)
  return excerpt_synopsis(excerpt_text) or fallback_title
end

local fence_languages = {
  bash = "bash",
  c = "c",
  cpp = "cpp",
  csharp = "csharp",
  css = "css",
  dart = "dart",
  dockerfile = "dockerfile",
  elixir = "elixir",
  go = "go",
  html = "html",
  java = "java",
  javascript = "js",
  javascriptreact = "jsx",
  json = "json",
  kotlin = "kotlin",
  lua = "lua",
  make = "makefile",
  markdown = "markdown",
  php = "php",
  python = "python",
  ruby = "ruby",
  rust = "rust",
  sass = "sass",
  scala = "scala",
  scss = "scss",
  sh = "bash",
  sql = "sql",
  swift = "swift",
  toml = "toml",
  typescript = "ts",
  typescriptreact = "tsx",
  vim = "vim",
  xml = "xml",
  yaml = "yaml",
  zsh = "bash",
}

local function excerpt_fence(path)
  if not path or path == "" then
    return "```"
  end

  local filetype = nil
  local buf = vim.fn.bufnr(path)
  if buf > 0 and vim.api.nvim_buf_is_valid(buf) then
    filetype = vim.bo[buf].filetype
  end
  if not filetype or filetype == "" then
    filetype = vim.filetype.match({ filename = path })
  end

  local language = filetype and fence_languages[filetype] or nil
  if not language or language == "" then
    return "```"
  end
  -- Review pane itself is markdown. Rendering markdown excerpts as
  -- ```markdown makes README-style content look like sidebar structure
  -- instead of literal source, so force plain text for markdown files.
  if language == "markdown" then
    return "```text"
  end
  return "```" .. language
end

function M.item_label(item, index, total)
  local status_text = item.status == "accepted" and " [accepted]" or ""
  return string.format(
    "[%d/%d] %s:%d-%d%s %s",
    index,
    total,
    vim.fn.fnamemodify(item.path, ":."),
    item.startLine,
    item.endLine,
    status_text,
    item.title or ""
  )
end

local function current_item(review)
  if not review then return nil end
  if not review.current_index or review.current_index < 1 then return nil end
  return review.items[review.current_index]
end

local function comments_for_item(review, item)
  local items = {}
  for _, comment in ipairs((review and review.comments) or {}) do
    if item and comment.itemId == item.id then
      table.insert(items, comment)
    end
  end
  return items
end

local function append_section(lines, title, content)
  table.insert(lines, "## " .. title)
  if type(content) == "string" then
    vim.list_extend(lines, vim.split(content, "\n", { plain = true }))
  else
    vim.list_extend(lines, content)
  end
  table.insert(lines, "")
end

local function accepted_count(review)
  local count = 0
  for _, item in ipairs((review and review.items) or {}) do
    if item.status == "accepted" then
      count = count + 1
    end
  end
  return count
end

local function unresolved_comment_count(review)
  local count = 0
  for _, comment in ipairs((review and review.comments) or {}) do
    if not comment.resolved then
      count = count + 1
    end
  end
  return count
end

local function relative_path(path, cwd)
  if cwd and vim.startswith(path, cwd .. "/") then
    return path:sub(#cwd + 2)
  end
  return path
end

local function review_status_lines(review, item)
  local status_text = "active"
  if review.planning then
    status_text = "planning"
  elseif review.awaiting_summary then
    status_text = "waiting for summary"
  elseif review.pending_question then
    status_text = "answering ranged question"
  elseif not review.active then
    status_text = "complete"
  end

  local lines = {
    string.format("- state: `%s`", status_text),
    string.format("- accepted: `%d/%d`", accepted_count(review), #review.items),
  }
  if item and item.status then
    table.insert(lines, string.format("- current stop: `%s`", item.status))
  end
  if not review.active or unresolved_comment_count(review) > 0 then
    table.insert(lines, string.format("- unresolved comments: `%d`", unresolved_comment_count(review)))
  end
  if review.summary_forwarded then
    table.insert(lines, "- summary: `forwarded to main chat`")
  elseif review.awaiting_summary then
    table.insert(lines, "- summary: `waiting for agent`")
  elseif not review.active and review.summary and review.summary ~= "" then
    table.insert(lines, "- summary: `ready`")
  end
  if review.pending_question then
    table.insert(lines, "- waiting: ranged answer is streaming inline; moving stops will clear it")
  end
  return lines
end

local function stop_line(review, has_msg0)
  if review.planning then
    return "- stop: `planning...`"
  end
  if not review.active then
    local done_index = math.min(#review.items, math.max(review.current_index or #review.items, 0))
    return string.format("- stop: `complete (%d/%d)`", done_index, #review.items)
  end
  if has_msg0 and review.current_index == 0 then
    return string.format("- stop: `0/%d`", #review.items)
  end

  local display_index = has_msg0 and review.current_index or (review.current_index or 1)
  return string.format("- stop: `%d/%d`", display_index, #review.items)
end

local function header_lines(review)
  local has_msg0 = review.plan_message and review.plan_message ~= ""
  local title = (not review.active and not review.planning) and "# Strider Review Complete" or "# Strider Review"
  local lines = {
    title,
    "",
    string.format("- source: `%s`", review.source),
    review.goal and ("- goal: `" .. review.goal .. "`") or nil,
    stop_line(review, has_msg0),
    review.scope and string.format("- scope: `%s`", review.scope) or nil,
    review.coverage_ok == false and "- coverage: `incomplete`" or nil,
    "",
  }

  return vim.tbl_filter(function(line)
    return line ~= nil and line ~= ""
  end, lines)
end

local function append_item_summary(lines, review, item, cwd, on_msg0)
  if on_msg0 then
    table.insert(lines, "**Synopsis**")
    table.insert(lines, "")
    return
  end

  if item then
    local path = relative_path(item.path, cwd)
    table.insert(lines, string.format("**%s**", item.title or "Review item"))
    table.insert(lines, string.format("`%s:%d-%d`", path, item.startLine, item.endLine))
    if item.status == "accepted" then table.insert(lines, "Status: accepted") end
    if item.summary and item.summary ~= "" then
      table.insert(lines, string.format("Synopsis: %s", item.summary))
    end
    if item.why and item.why ~= "" and item.why ~= item.summary then
      table.insert(lines, string.format("Why: %s", item.why))
    end
    table.insert(lines, "")
    return
  end

  if review.planning then
    table.insert(lines, "Strider is planning the review. The first stop will open here.")
    table.insert(lines, "")
  end
end

local function explanation_for(review, item, on_msg0)
  local explanation = item and (item.summary or item.why or item.explanation)
  local title = "Explanation"
  if review.awaiting_summary then
    return "End of review", "Waiting for the end-of-review summary from the agent..."
  elseif review.summary and review.summary ~= "" then
    return "Review summary", review.summary
  elseif on_msg0 then
    return "Synopsis", review.plan_message
  elseif review.planning then
    return title, "Strider is planning the review..."
  elseif not explanation or explanation == "" then
    return title, review.active and "Waiting for the explanation for this review item..." or "Review complete."
  end
  return title, explanation
end

local function append_explanation(lines, review, item, on_msg0)
  -- Sidebar Explanation shows the shorter `summary`. The longer
  -- `explanation` is rendered as a virtual-line block in the code buffer
  -- instead, so we don't duplicate it here.
  local title, explanation = explanation_for(review, item, on_msg0)
  if title == "Explanation" then
    append_section(lines, title, {
      "Synopsis of the current stop (full explanation is shown inline in the code):",
      "",
      explanation,
    })
  else
    append_section(lines, title, explanation)
  end
end

local function append_excerpt(lines, item)
  if item and item.excerpt and item.excerpt ~= "" then
    append_section(lines, "Excerpt", {
      excerpt_fence(item.path),
      item.excerpt,
      "```",
    })
  end
end

local function append_item_comments(lines, review, item, on_msg0)
  if on_msg0 then return end

  local item_comments = comments_for_item(review, item)
  if #item_comments == 0 then
    append_section(lines, "Comments on this item", "No comments on this item yet.")
    return
  end

  local rendered = {}
  for index, comment in ipairs(item_comments) do
    table.insert(rendered, string.format("%d. lines %d-%d — %s",
      index, comment.startLine, comment.endLine, comment.text))
  end
  append_section(lines, "Comments on this item", rendered)
end

local function review_plan_lines(review, cwd, has_msg0)
  local toc = {}
  if has_msg0 then
    local marker = review.current_index == 0 and "→" or " "
    table.insert(toc, string.format("%s [0] Synopsis", marker))
  end
  for index, stop in ipairs(review.items) do
    local marker = (index == review.current_index) and "→" or " "
    local status = stop.status == "accepted" and " [accepted]" or ""
    table.insert(toc, string.format("%s [%d] `%s:%d-%d`%s %s",
      marker, index, relative_path(stop.path, cwd), stop.startLine,
      stop.endLine, status, stop.title or ""))
  end
  return toc
end

local function append_review_plan(lines, review, cwd, has_msg0)
  if #review.items > 1 or has_msg0 then
    append_section(lines, "Review plan", review_plan_lines(review, cwd, has_msg0))
  end
end

local function append_controls(lines, review)
  if review and not review.active then
    local actions = {
      "- Review is complete; start another `:StriderReview <prompt>` when ready.",
      "- `:StriderLogReview` opens the diagnostic transcript if you need it.",
    }
    if review.summary_forwarded then
      table.insert(actions, 2, "- `:StriderChat` opens the main chat with the forwarded review summary.")
    elseif review.awaiting_summary then
      table.insert(actions, 2, "- Waiting for the agent to summarize unresolved comments before forwarding.")
    elseif review.summary and review.summary ~= "" then
      table.insert(actions, 2, "- Summary is ready in this pane.")
    end
    append_section(lines, "Next actions", actions)
    return
  end

  append_section(lines, "Controls", {
    "- `:StriderNext` / `:StriderPrev` move between review items",
    "- `:StriderNext!` accepts the current stop and moves on",
    "- `:StriderReview <question>` asks about the current review item",
    "- `:'<,'>StriderReview <question>` asks about a selected range",
    "- `:StriderChat` toggles the chat surfaces (log + compose)",
    "- `:StriderComment` opens the multiline comment editor",
    "- `:'<,'>StriderComment [text]` opens the multiline editor for a selected range",
    "- `:'<,'>StriderPatch <prompt>` patches the selected range",
  })
end

function M.panel_lines(review, opts)
  opts = opts or {}
  if not review then
    return {
      "# Strider Review",
      "",
      "No active review session.",
    }
  end

  local cwd = opts.cwd
  local item = current_item(review)
  local has_msg0 = review.plan_message and review.plan_message ~= ""
  local on_msg0 = has_msg0 and review.current_index == 0
  local lines = header_lines(review)

  append_section(lines, "Status", review_status_lines(review, item))
  append_item_summary(lines, review, item, cwd, on_msg0)
  append_explanation(lines, review, item, on_msg0)
  append_excerpt(lines, item)
  append_item_comments(lines, review, item, on_msg0)
  append_review_plan(lines, review, cwd, has_msg0)
  append_controls(lines, review)

  return lines
end

return M
