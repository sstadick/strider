local picker = require("sherpa.picker")
local search = require("sherpa.search")
local state = require("sherpa.state")
local ui = require("sherpa.ui")

local M = {}

local git_run
local relative_path

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
    local chunk_excerpt = excerpt(path, chunk_start, chunk_end)
    table.insert(items, {
      id = string.format("%s:%d-%d", path, chunk_start, chunk_end),
      path = path,
      startLine = chunk_start,
      endLine = chunk_end,
      kind = kind,
      title = chunk_title(kind, path, title, chunk_excerpt),
      summary = chunk_summary(kind, summary, chunk_excerpt),
      excerpt = chunk_excerpt,
    })
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

local function normalize_diff_path(raw)
  if not raw or raw == "/dev/null" then
    return nil
  end
  local session = state.get_session()
  if not session then
    return nil
  end
  local path = raw:gsub("^b/", "")
  local cwd = session.cwd
  if path:match("^/") then
    return path
  end
  return vim.fs.joinpath(cwd, path)
end

local function parse_hunk(line)
  local start_raw, count_raw = line:match("^@@ %-%d+,?%d* %+(%d+),?(%d*) @@")
  if not start_raw then
    return nil
  end
  local start_line = tonumber(start_raw) or 1
  local count = tonumber(count_raw)
  if count == nil or count == 0 then
    count = 1
  end
  return start_line, start_line + count - 1
end

git_run = function(cwd, args)
  local cmd = string.format("git -C %s %s", vim.fn.shellescape(cwd), args)
  local output = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return output
end

local function git_first_line(cwd, args)
  local output = git_run(cwd, args)
  if not output or #output == 0 then
    return nil
  end
  local line = vim.trim(output[1] or "")
  if line == "" then
    return nil
  end
  return line
end

local function ref_exists(cwd, ref)
  local cmd = string.format(
    "git -C %s rev-parse --verify --quiet %s",
    vim.fn.shellescape(cwd),
    vim.fn.shellescape(ref)
  )
  vim.fn.systemlist(cmd)
  return vim.v.shell_error == 0
end

local function detect_base_branch(cwd)
  if vim.fn.executable("gh") == 1 then
    local gh_cmd = "cd " .. vim.fn.shellescape(cwd)
      .. " && gh pr view --json baseRefName -q .baseRefName 2>/dev/null"
    local gh_output = vim.fn.systemlist(gh_cmd)
    if vim.v.shell_error == 0 and gh_output[1] and vim.trim(gh_output[1]) ~= "" then
      local base = vim.trim(gh_output[1])
      local remote_ref = "origin/" .. base
      if ref_exists(cwd, remote_ref) then
        return remote_ref
      end
      if ref_exists(cwd, base) then
        return base
      end
    end
  end

  local head_ref = git_first_line(cwd, "symbolic-ref --quiet refs/remotes/origin/HEAD")
  if head_ref then
    local stripped = head_ref:gsub("^refs/remotes/", "")
    if ref_exists(cwd, stripped) then
      return stripped
    end
  end

  for _, candidate in ipairs({ "origin/main", "origin/master", "main", "master" }) do
    if ref_exists(cwd, candidate) then
      return candidate
    end
  end

  return nil
end

local function parse_diff_output(output)
  local items = {}
  local current_path = nil
  for _, line in ipairs(output or {}) do
    if vim.startswith(line, "+++") then
      current_path = normalize_diff_path(line:match("^%+%+%+%s+(.+)$"))
    elseif vim.startswith(line, "@@") and current_path then
      local start_line, end_line = parse_hunk(line)
      if start_line and end_line then
        push_chunks(items, current_path, start_line, end_line, "change", "Diff hunk", line)
      end
    end
  end
  return items
end

local function diff_items()
  local session = state.get_session()
  if not session then
    return {}
  end
  local output = git_run(session.cwd, "diff --unified=0 --no-color")
  if not output then
    return {}
  end
  return parse_diff_output(output)
end

local function branch_diff_items(base)
  local session = state.get_session()
  if not session then
    return {}, nil
  end
  local cwd = session.cwd
  local base_ref = base and base ~= "" and base or detect_base_branch(cwd)
  if not base_ref then
    ui.notify("Sherpa: could not determine base branch for review", vim.log.levels.WARN)
    return {}, nil
  end
  if not ref_exists(cwd, base_ref) then
    ui.notify("Sherpa: base ref not found: " .. base_ref, vim.log.levels.WARN)
    return {}, base_ref
  end
  local args = string.format(
    "diff --unified=0 --no-color %s...HEAD",
    vim.fn.shellescape(base_ref)
  )
  local output = git_run(cwd, args)
  if not output then
    return {}, base_ref
  end
  return parse_diff_output(output), base_ref
end

local function current_item(review)
  review = review or active_review()
  if not review then
    return nil
  end
  return review.items[review.current_index]
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
    string.format("- item: `%d/%d`", review.current_index or 1, #review.items),
    "",
  }

  if item then
    table.insert(lines, string.format("**%s**", item.title or "Review item"))
    table.insert(lines, string.format("`%s:%d-%d`", relative_path(item.path), item.startLine, item.endLine))
    if item.summary and item.summary ~= "" then
      table.insert(lines, string.format("Synopsis: %s", item.summary))
    end
    table.insert(lines, "")
  end

  local explanation = item and item.explanation or nil
  local explanation_title = "Explanation"
  if review.awaiting_summary then
    explanation_title = "End of review"
    explanation = "Waiting for the end-of-review summary from the agent..."
  elseif review.summary and review.summary ~= "" then
    explanation_title = "Review summary"
    explanation = review.summary
  elseif not explanation or explanation == "" then
    explanation = review.active and "Waiting for the explanation for this review item..." or "Review complete."
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

  if scope == "file" then
    local path = opts.path or current_buffer_path()
    if not is_reviewable_file(path) then
      opts.resolved_source = "project"
      return project_items(opts.focus)
    end
    local line_count = file_line_count(path)
    return file_items(path, 1, line_count, "tour-stop", "File walkthrough", "Current file")
  end

  if scope == "project" then
    opts.resolved_source = "project"
    return project_items(opts.focus)
  end

  if scope == "diff" then
    return diff_items()
  end

  if scope == "branch" then
    local items, base = branch_diff_items(opts.base)
    if base then
      opts.resolved_base = base
    end
    return items
  end

  if scope == "search" then
    return search.to_review_items(search.last_result_set())
  end

  if scope == "last" then
    local last_search = search.last_result_set()
    if last_search then
      return search.to_review_items(last_search)
    end
    local items = diff_items()
    if #items > 0 then
      return items
    end
    return M.build_items("file", opts)
  end

  return {}
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
  if scope == "branch" and opts.resolved_base then
    source = "branch (" .. opts.resolved_base .. ")"
  end
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

  local user_focus = focus or review.focus or "Walk me through this review item."
  local lines = {
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

function M.advance(direction)
  local review = active_review()
  if not review then
    return nil, false
  end

  local next_index = review.current_index + direction
  if next_index < 1 or next_index > #review.items then
    return nil, next_index > #review.items
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
