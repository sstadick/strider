local picker = require("sherpa.picker")
local state = require("sherpa.state")
local ui = require("sherpa.ui")

local M = {}

local git_run
local relative_path
local make_item

local MAX_REVIEW_LINES = 40
local MAX_PROJECT_FILE_BYTES = 256 * 1024
local MAX_PROJECT_REVIEW_FILES = 10

local function active_review()
  local session = state.get_session()
  if not session then
    return nil
  end
  local review = session.review
  if review and review.active then
    return review
  end
end

local function current_buffer_path()
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" then
    return nil
  end
  return path
end

local function file_stat(path)
  if not path or path == "" then
    return nil
  end
  return vim.uv.fs_stat(path)
end

local function is_reviewable_file(path)
  if not path or path == "" or path:match("^%a+://") then
    return false
  end
  local stat = file_stat(path)
  return stat ~= nil and stat.type == "file"
end

local function read_lines(path, start_line, end_line)
  local buf = vim.fn.bufnr(path)
  if buf > 0 and vim.api.nvim_buf_is_valid(buf) then
    return vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
  end
  local all = vim.fn.readfile(path)
  local lines = {}
  for line = start_line, math.min(end_line, #all) do
    table.insert(lines, all[line])
  end
  return lines
end

local function excerpt(path, start_line, end_line)
  local final_line = math.min(end_line, start_line + 12)
  local lines = read_lines(path, start_line, final_line)
  return table.concat(lines, "\n")
end

local function truncate(text, width)
  width = width or 72
  if #text <= width then
    return text
  end
  return text:sub(1, width - 1) .. "…"
end

local function collapse_whitespace(text)
  return vim.trim((text or ""):gsub("%s+", " "))
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

local function excerpt_synopsis(text)
  local line = first_meaningful_line(text)
  if not line then
    return nil
  end

  if line:match("^import%s") or line:match("^from%s") or line:match("^require%(") or line:match("^use%s") then
    return "Imports and setup"
  end

  for _, pattern in ipairs({
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
  }) do
    local name = line:match(pattern)
    if name then
      return "Defines " .. name
    end
  end

  return truncate(line)
end

local function chunk_title(kind, path, fallback_title, excerpt_text)
  if kind == "project-file" then
    return relative_path(path)
  end
  return excerpt_synopsis(excerpt_text) or fallback_title
end

local function chunk_summary(kind, fallback_summary, excerpt_text)
  if kind == "change" then
    return fallback_summary
  end
  return excerpt_synopsis(excerpt_text) or fallback_summary
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
  return "```" .. language
end

local function item_label(item, index, total)
  return string.format(
    "%d/%d %s:%d-%d %s",
    index,
    total,
    vim.fn.fnamemodify(item.path, ":."),
    item.startLine,
    item.endLine,
    item.title or ""
  )
end

local function push_chunks(items, path, start_line, end_line, kind, title, summary)
  local chunk_start = start_line
  while chunk_start <= end_line do
    local chunk_end = math.min(chunk_start + MAX_REVIEW_LINES - 1, end_line)
    table.insert(items, make_item(path, chunk_start, chunk_end, kind, title, summary))
    chunk_start = chunk_end + 1
  end
end

local function file_items(path, start_line, end_line, kind, title, summary)
  local items = {}
  push_chunks(items, path, start_line, end_line, kind, title, summary)
  return items
end

local function file_line_count(path)
  local buf = vim.fn.bufnr(path)
  if buf > 0 and vim.api.nvim_buf_is_valid(buf) then
    return vim.api.nvim_buf_line_count(buf)
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return 0
  end
  return #lines
end

local function focus_tokens(text)
  local tokens = {}
  local seen = {}
  for token in (text or ""):lower():gmatch("[%w_]+") do
    if #token >= 3 and not seen[token] then
      seen[token] = true
      table.insert(tokens, token)
    end
  end
  return tokens
end

local function wants_full_project_review(focus)
  local text = (focus or ""):lower()
  return text:find("every file", 1, true)
    or text:find("all files", 1, true)
    or text:find("entire repo", 1, true)
    or text:find("whole repo", 1, true)
    or text:find("entire project", 1, true)
    or text:find("whole project", 1, true)
end

local function project_file_score(path, focus)
  local relative = relative_path(path):lower()
  local score = 0
  local wants_tests = (focus or ""):lower():match("test") ~= nil
  local wants_docs = (focus or ""):lower():match("readme") ~= nil or (focus or ""):lower():match("doc") ~= nil

  if relative == "readme.md" or relative:match("/readme%.md$") then score = score + 60 end
  if relative:match("package%.json$") or relative:match("pyproject%.toml$") or relative:match("cargo%.toml$")
    or relative:match("go%.mod$") or relative:match("setup%.py$") then
    score = score + 45
  end
  if relative:match("^plugin/") then score = score + 35 end
  if relative:match("^lua/") or relative:match("^src/") or relative:match("^app/") or relative:match("^lib/") then
    score = score + 20
  end
  if relative:match("main%.") or relative:match("index%.") or relative:match("app%.") or relative:match("init%.") then
    score = score + 20
  end
  if relative:match("^test/") or relative:match("^tests/") then
    score = score + (wants_tests and 25 or -20)
  end
  if relative:match("^docs/") then
    score = score + (wants_docs and 20 or 5)
  end
  if relative:match("package%-lock%.json$") or relative:match("pnpm%-lock%.yaml$") or relative:match("yarn%.lock$") then
    score = score - 25
  end

  local content = table.concat(read_lines(path, 1, math.min(file_line_count(path), 40)), "\n"):lower()
  for _, token in ipairs(focus_tokens(focus)) do
    if relative:find(token, 1, true) then
      score = score + 15
    end
    if content:find(token, 1, true) then
      score = score + 6
    end
  end

  return score
end

local function project_files(focus)
  local session = state.get_session()
  if not session then
    return {}
  end

  local candidates = {}
  local tracked = git_run(session.cwd, "ls-files") or {}
  if #tracked > 0 then
    for _, relative in ipairs(tracked) do
      table.insert(candidates, vim.fs.joinpath(session.cwd, relative))
    end
  else
    candidates = vim.fn.globpath(session.cwd, "**/*", false, true)
  end

  local scored = {}
  for _, path in ipairs(candidates) do
    local stat = file_stat(path)
    if stat and stat.type == "file" and stat.size <= MAX_PROJECT_FILE_BYTES then
      table.insert(scored, {
        path = path,
        score = project_file_score(path, focus),
      })
    end
  end

  table.sort(scored, function(a, b)
    if a.score == b.score then
      return a.path < b.path
    end
    return a.score > b.score
  end)

  local limit = wants_full_project_review(focus) and #scored or math.min(#scored, MAX_PROJECT_REVIEW_FILES)
  local files = {}
  for index = 1, limit do
    table.insert(files, scored[index].path)
  end
  return files
end

local function project_items(focus)
  local items = {}
  for _, path in ipairs(project_files(focus)) do
    local line_count = file_line_count(path)
    if line_count > 0 then
      push_chunks(items, path, 1, line_count, "project-file", relative_path(path), "Project file")
    end
  end
  return items
end

git_run = function(cwd, args)
  local cmd = string.format("git -C %s %s", vim.fn.shellescape(cwd), args)
  local output = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return output
end

local function current_item(review)
  review = review or active_review()
  if not review then
    return nil
  end
  if not review.current_index or review.current_index < 1 then
    return nil
  end
  return review.items[review.current_index]
end

make_item = function(path, start_line, end_line, kind, fallback_title, fallback_summary)
  local item_excerpt = excerpt(path, start_line, end_line)
  return {
    id = string.format("%s:%d-%d", path, start_line, end_line),
    path = path,
    startLine = start_line,
    endLine = end_line,
    kind = kind,
    title = chunk_title(kind, path, fallback_title, item_excerpt),
    summary = chunk_summary(kind, fallback_summary, item_excerpt),
    excerpt = item_excerpt,
  }
end

local function comment_lines(comments)
  local lines = {}
  for index, comment in ipairs(comments or {}) do
    table.insert(lines, string.format("%d. %s:%d-%d", index, comment.path, comment.startLine, comment.endLine))
    table.insert(lines, comment.text)
  end
  return lines
end

local function unresolved_comments(review)
  local items = {}
  for _, comment in ipairs((review and review.comments) or {}) do
    if not comment.resolved then
      table.insert(items, comment)
    end
  end
  return items
end

local function review_state()
  local session = state.get_session()
  return session and session.review or nil
end

relative_path = function(path)
  local session = state.get_session()
  local cwd = session and session.cwd or nil
  if cwd and vim.startswith(path, cwd .. "/") then
    return path:sub(#cwd + 2)
  end
  return path
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

local function panel_lines(review)
  if not review then
    return {
      "# Sherpa Review",
      "",
      "No active review session.",
    }
  end

  local item = current_item(review)
  local lines = {
    "# Sherpa Review",
    "",
    string.format("- source: `%s`", review.source),
    review.goal and ("- goal: `" .. review.goal .. "`") or nil,
  }

  if review.dynamic then
    table.insert(lines, string.format("- current stop: `%s`", review.current_index > 0 and tostring(review.current_index) or "planning"))
    table.insert(lines, string.format("- discovered stops: `%d`", #review.items))
    if review.expecting_next_item then
      table.insert(lines, "- state: `choosing next stop`")
    elseif review.complete_suggested then
      table.insert(lines, "- state: `no new stop chosen`")
    end
  else
    table.insert(lines, string.format("- item: `%d/%d`", review.current_index or 1, #review.items))
  end
  table.insert(lines, "")

  lines = vim.tbl_filter(function(line)
    return line ~= nil and line ~= ""
  end, lines)

  if item then
    table.insert(lines, string.format("**%s**", item.title or "Review item"))
    table.insert(lines, string.format("`%s:%d-%d`", relative_path(item.path), item.startLine, item.endLine))
    if item.summary and item.summary ~= "" then
      table.insert(lines, string.format("Synopsis: %s", item.summary))
    end
    table.insert(lines, "")
  elseif review.dynamic then
    table.insert(lines, "Sherpa is choosing the next review stop based on your request.")
    table.insert(lines, "")
  end

  local explanation = item and item.explanation or review.overview
  local explanation_title = "Explanation"
  if review.awaiting_summary then
    explanation_title = "End of review"
    explanation = "Waiting for the end-of-review summary from the agent..."
  elseif review.summary and review.summary ~= "" then
    explanation_title = "Review summary"
    explanation = review.summary
  elseif review.dynamic and review.complete_suggested then
    explanation_title = "No new stop chosen"
    explanation = review.overview or "Sherpa did not choose a new stop. Use :SherpaNext to ask for another stop or :SherpaReview <question> to redirect the review."
  elseif not explanation or explanation == "" then
    explanation = review.active and (review.dynamic and "Waiting for Sherpa to choose the next review stop..." or "Waiting for the explanation for this review item...") or "Review complete."
  end
  if explanation_title == "Explanation" then
    append_section(lines, explanation_title, {
      "Sherpa's current explanation of the highlighted review item:",
      "",
      explanation,
    })
  else
    append_section(lines, explanation_title, explanation)
  end

  if item and item.excerpt and item.excerpt ~= "" then
    append_section(lines, "Excerpt", {
      excerpt_fence(item.path),
      item.excerpt,
      "```",
    })
  end

  local item_comments = comments_for_item(review, item)
  if #item_comments == 0 then
    append_section(lines, "Comments on this item", "No comments on this item yet.")
  else
    local comment_lines = {}
    for index, comment in ipairs(item_comments) do
      table.insert(comment_lines, string.format("%d. lines %d-%d — %s", index, comment.startLine, comment.endLine, comment.text))
    end
    append_section(lines, "Comments on this item", comment_lines)
  end

  append_section(lines, "Controls", {
    "- `:SherpaNext` / `:SherpaPrev` move between review items",
    "- `:SherpaReview <question>` asks about the current review item",
    "- `:'<,'>SherpaReview <question>` asks about a selected range",
    "- `:SherpaLog` reopens the transcript / agent buffer",
    "- `:SherpaComment` opens the multiline comment editor",
    "- `:'<,'>SherpaComment <text>` comments on a selected range",
    "- `:'<,'>SherpaPatch <prompt>` patches the selected range",
  })

  return lines
end

function M.render()
  local review = review_state()
  if not review then
    ui.hide_review()
    return false
  end
  ui.set_review_lines(panel_lines(review))
  return true
end

function M.capture_assistant_text(text, opts)
  opts = opts or {}
  local review = review_state()
  if not review then
    return false
  end
  if review.awaiting_summary then
    review.summary = text
    if not opts.partial then
      review.awaiting_summary = false
    end
    M.render()
    return true
  end

  if review.dynamic then
    local candidate = review.pending_item
    local item = current_item(review)
    if candidate then
      local same_item = item
        and item.path == candidate.path
        and item.startLine == candidate.startLine
        and item.endLine == candidate.endLine
      if not same_item then
        local existing_index = nil
        for index, existing in ipairs(review.items) do
          if existing.path == candidate.path
            and existing.startLine == candidate.startLine
            and existing.endLine == candidate.endLine then
            existing_index = index
            break
          end
        end
        if existing_index then
          review.current_index = existing_index
          item = review.items[existing_index]
        else
          table.insert(review.items, candidate)
          review.current_index = #review.items
          item = candidate
        end
      end
      review.pending_item = nil
      review.expecting_next_item = false
      review.complete_suggested = false
    end

    if not item then
      if review.expecting_next_item and not opts.partial then
        review.expecting_next_item = false
        review.complete_suggested = true
        review.overview = text ~= "" and text or "Sherpa did not choose a new stop yet."
        review.last_overview = review.overview
        M.render()
        return true
      end
      review.overview = text
      if not opts.partial then
        review.last_overview = text
      end
      M.render()
      return true
    end
  end

  local item = current_item(review)
  if not item then
    return false
  end
  item.explanation = text
  if not opts.partial and item.status ~= "commented" then
    item.status = "reviewed"
  end
  M.render()
  return true
end

function M.has_active_review()
  return active_review() ~= nil
end

function M.current_item()
  return current_item(active_review())
end

function M.is_dynamic()
  local review = active_review()
  return review and review.dynamic or false
end

function M.note_read(path, start_line, end_line)
  local review = active_review()
  if not review or not review.dynamic or review.awaiting_summary then
    return false
  end
  review.pending_item = make_item(path, start_line, end_line, "review-stop", relative_path(path), "Review stop")
  return true
end

function M.focus_item(item)
  if not item then
    return false
  end
  ui.jump_to_file(item.path, item.startLine)
  ui.highlight_range(item.path, item.startLine, item.endLine)
  M.render()
  return true
end

function M.build_items(scope, opts)
  opts = opts or {}
  if scope == "selection" then
    local path = opts.path or current_buffer_path()
    if not path or not opts.startLine or not opts.endLine then
      return {}
    end
    return file_items(path, opts.startLine, opts.endLine, "selection", "Selection", "Selected range")
  end

  return {}
end

function M.start_dynamic(goal)
  local session = state.get_session()
  if not session then
    ui.notify("No active Sherpa session", vim.log.levels.WARN)
    return false
  end

  ui.clear_comment_markers()
  ui.hide_log()
  session.review = {
    active = true,
    awaiting_summary = false,
    comments = {},
    complete_suggested = false,
    current_index = 0,
    dynamic = true,
    expecting_next_item = false,
    goal = goal,
    items = {},
    source = "review",
    summary = nil,
    title = "Sherpa review",
  }
  M.render()
  return true
end

function M.start(scope, opts)
  opts = opts or {}
  local session = state.get_session()
  if not session then
    ui.notify("No active Sherpa session", vim.log.levels.WARN)
    return nil
  end
  local items = M.build_items(scope, opts)
  if #items == 0 then
    ui.notify("No review items found for scope: " .. scope, vim.log.levels.WARN)
    return nil
  end

  ui.clear_comment_markers()
  ui.hide_log()
  local source = opts.resolved_source or scope
  session.review = {
    active = true,
    awaiting_summary = false,
    base = opts.resolved_base,
    comments = {},
    current_index = 1,
    focus = opts.focus,
    items = items,
    source = source,
    summary = nil,
    title = opts.title or ("Sherpa review: " .. source),
  }
  ui.show_review()
  M.focus_item(items[1])
  return items[1]
end

function M.build_prompt(focus)
  local review = active_review()
  local item = current_item(review)
  if not review or not item then
    return nil
  end

  local user_focus = focus or review.focus or review.goal or "Walk me through this review item."
  local lines = {
    review.goal and ("Review goal: " .. review.goal) or nil,
    string.format("Review source: %s", review.source),
    string.format("Review item: %d of %d", review.current_index, #review.items),
    string.format("File: %s", item.path),
    string.format("Lines: %d-%d", item.startLine, item.endLine),
    item.title and ("Title: " .. item.title) or nil,
    item.summary and ("Summary: " .. item.summary) or nil,
    "Stay focused on this item.",
    "Across the overall review, follow the most sensible order for understanding the user's question rather than discovery order.",
    "Unless the user explicitly asks for a file-by-file audit, focus on the files and chunks most relevant to understanding the project.",
    "Keep the explanation compact and low-chrome.",
    "Avoid generic sections like 'Requirements' or 'Overview' unless the user explicitly asks for them.",
    "You may inspect nearby code if needed, but keep the explanation centered on this range.",
    item.excerpt and "<REVIEW_EXCERPT>\n" .. item.excerpt .. "\n</REVIEW_EXCERPT>" or nil,
    "User focus: " .. user_focus,
  }
  return table.concat(vim.tbl_filter(function(line)
    return line ~= nil and line ~= ""
  end, lines), "\n")
end

function M.next_prompt()
  local review = active_review()
  local item = current_item(review)
  if not review or not review.dynamic then
    return nil
  end
  if not item then
    return review.goal
  end

  local lines = {
    "Continue the review by choosing the next most useful file or small code section for understanding the review goal.",
    review.goal and ("Review goal: " .. review.goal) or nil,
    string.format("Current stop file: %s", item.path),
    string.format("Current stop lines: %d-%d", item.startLine, item.endLine),
    item.summary and ("Current stop summary: " .. item.summary) or nil,
    item.explanation and ("Current stop explanation: " .. collapse_whitespace(item.explanation)) or nil,
    "If the review is already complete, say so clearly instead of opening another stop.",
    "Otherwise, inspect one new small section and explain why it matters next.",
  }
  return table.concat(vim.tbl_filter(function(line)
    return line ~= nil and line ~= ""
  end, lines), "\n")
end

function M.prepare_next_dynamic()
  local review = active_review()
  if not review or not review.dynamic then
    return false
  end
  local item = current_item(review)
  if item and item.status == nil then
    item.status = "reviewed"
  end
  review.complete_suggested = false
  review.overview = nil
  review.pending_item = nil
  review.expecting_next_item = true
  M.render()
  return true
end

function M.advance(direction)
  local review = active_review()
  if not review then
    return nil, false
  end

  local next_index = (review.current_index or 0) + direction
  if next_index < 1 or next_index > #review.items then
    return nil, next_index > #review.items and not review.dynamic
  end

  local previous = current_item(review)
  if previous and previous.status == nil then
    previous.status = "reviewed"
  end
  review.current_index = next_index
  local item = current_item(review)
  M.focus_item(item)
  return item, false
end

function M.finish()
  local review = active_review()
  if not review then
    return nil
  end

  local comments = unresolved_comments(review)
  review.active = false
  if #comments == 0 then
    review.awaiting_summary = false
    review.pending_comments = nil
    review.summary = "Review complete. No unresolved comments."
    M.render()
    return nil
  end

  local lines = {
    string.format("Review source: %s", review.source),
    "The interactive review is complete.",
    "These unresolved review comments should now feed back into the agent as follow-up context.",
    "Please summarize the concerns, answer any implied open questions, and propose the smallest useful next patches or work items.",
    "<REVIEW_COMMENTS>",
  }
  local rendered_comments = comment_lines(comments)
  vim.list_extend(lines, rendered_comments)
  table.insert(lines, "</REVIEW_COMMENTS>")
  review.awaiting_summary = true
  review.pending_comments = rendered_comments
  review.summary = nil
  M.render()
  return table.concat(lines, "\n")
end

function M.pending_comment_lines()
  local review = review_state()
  if not review or not review.pending_comments then
    return nil
  end
  return review.pending_comments
end

function M.has_unresolved_comments()
  local review = active_review()
  return review ~= nil and #unresolved_comments(review) > 0
end

function M.add_comment(text, range)
  local review = active_review()
  local item = current_item(review)
  if not review or not item then
    ui.notify("No active review item to comment on", vim.log.levels.WARN)
    return nil
  end

  local start_line = range and range.startLine or item.startLine
  local end_line = range and range.endLine or item.endLine
  local comment = {
    id = string.format("comment-%d", #review.comments + 1),
    itemId = item.id,
    path = item.path,
    startLine = start_line,
    endLine = end_line,
    text = text,
    resolved = false,
    source = "local",
    externalId = nil,
  }

  table.insert(review.comments, comment)
  item.status = "commented"
  ui.add_comment_marker(comment.path, comment.startLine)
  M.render()
  return comment
end

function M.open_comment_editor(range, on_submit)
  ui.open_comment_editor(function(text)
    local comment = M.add_comment(text, range)
    if comment and on_submit then
      on_submit(comment)
    end
  end)
end

function M.comment_picker()
  local session = state.get_session()
  if not session then
    ui.notify("No active Sherpa session", vim.log.levels.WARN)
    return false
  end
  local review = active_review() or session.review
  local comments = (review and review.comments) or {}
  if #comments == 0 then
    ui.notify("No Sherpa review comments recorded", vim.log.levels.WARN)
    return false
  end

  local items = {}
  for index, comment in ipairs(comments) do
    table.insert(items, {
      label = string.format(
        "%d. %s:%d-%d %s",
        index,
        vim.fn.fnamemodify(comment.path, ":."),
        comment.startLine,
        comment.endLine,
        comment.text
      ),
      value = comment,
    })
  end

  return picker.select("Sherpa Comments", items, function(entry)
    local comment = entry.value
    ui.jump_to_file(comment.path, comment.startLine)
    ui.highlight_range(comment.path, comment.startLine, comment.endLine)
  end)
end

function M.item_picker()
  local session = state.get_session()
  local review = active_review() or (session and session.review)
  if not review then
    ui.notify("No Sherpa review session available", vim.log.levels.WARN)
    return false
  end

  local items = {}
  for index, item in ipairs(review.items) do
    table.insert(items, {
      label = item_label(item, index, #review.items),
      value = { index = index, item = item },
    })
  end

  return picker.select("Sherpa Review Items", items, function(entry)
    review.current_index = entry.value.index
    M.focus_item(entry.value.item)
  end)
end

return M
