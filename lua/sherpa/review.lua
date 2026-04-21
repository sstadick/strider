local picker = require("sherpa.picker")
local state = require("sherpa.state")
local ui = require("sherpa.ui")

local M = {}

local git_run
local relative_path

local MAX_REVIEW_LINES = 40

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

local function chunk_title(path, fallback_title, excerpt_text)
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

  if review.planning then
    table.insert(lines, "- stop: `planning...`")
  else
    table.insert(lines, string.format("- stop: `%d/%d`", review.current_index or 1, #review.items))
  end
  if review.scope then
    table.insert(lines, string.format("- scope: `%s`", review.scope))
  end
  if review.coverage_ok == false then
    table.insert(lines, "- coverage: `incomplete`")
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
    if item.why and item.why ~= "" and item.why ~= item.summary then
      table.insert(lines, string.format("Why: %s", item.why))
    end
    table.insert(lines, "")
  elseif review.planning then
    table.insert(lines, "Sherpa is planning the review. The first stop will open here.")
    table.insert(lines, "")
  end

  -- Sidebar Explanation shows the shorter `summary`. The longer
  -- `explanation` is rendered as a virtual-line block in the code buffer
  -- instead, so we don't duplicate it here.
  local explanation = item and (item.summary or item.why or item.explanation)
  local explanation_title = "Explanation"
  if review.awaiting_summary then
    explanation_title = "End of review"
    explanation = "Waiting for the end-of-review summary from the agent..."
  elseif review.summary and review.summary ~= "" then
    explanation_title = "Review summary"
    explanation = review.summary
  elseif review.planning then
    explanation = "Sherpa is planning the review..."
  elseif not explanation or explanation == "" then
    explanation = review.active and "Waiting for the explanation for this review item..." or "Review complete."
  end
  if explanation_title == "Explanation" then
    append_section(lines, explanation_title, {
      "Synopsis of the current stop (full explanation is shown inline in the code):",
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

  if #review.items > 1 then
    local toc = {}
    for index, stop in ipairs(review.items) do
      local marker = (index == review.current_index) and "→" or " "
      table.insert(toc, string.format("%s %d. `%s:%d-%d` %s",
        marker, index, relative_path(stop.path), stop.startLine, stop.endLine, stop.title or ""))
    end
    append_section(lines, "Review plan", toc)
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
  -- End-of-review summary turn: feed the summary into the sidebar.
  if review.awaiting_summary then
    review.summary = text
    if not opts.partial then
      review.awaiting_summary = false
    end
    M.render()
    return true
  end

  -- Ranged question: render the answer inline over the question's range.
  if review.pending_question then
    return M.capture_ranged_question_answer(text, opts)
  end

  -- Plain question (no pending_question, no awaiting_summary): the
  -- answer goes to the log via the rpc's append_block. Do NOT touch
  -- item.explanation — that's reserved for the pre-computed explanation
  -- rendered inline in the buffer, and overwriting it would clobber the
  -- stop's own context.
  if not opts.partial then
    local item = current_item(review)
    if item and item.status == nil then
      item.status = "reviewed"
    end
  end
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
  -- Swap inline annotations: clear prior stop's, render this one's.
  -- Each step clears the annotations of the previous step (by design).
  -- Any pending ranged-question answer also gets cleared — the user
  -- moved on.
  ui.clear_stop_annotations()
  local review = review_state()
  if review then review.pending_question = nil end
  ui.set_stop_annotations(item)
  M.render()
  return true
end

-- Stash a ranged question on the review so the streaming answer can be
-- rendered as an inline block annotation over the same range. Only
-- honored while the review is active and the current stop is unchanged
-- when the answer lands.
function M.begin_ranged_question(range, text)
  local review = active_review()
  if not review or not range then
    return false
  end
  local item = current_item(review)
  review.pending_question = {
    path = range.path,
    startLine = range.startLine,
    endLine = range.endLine,
    stop_index = review.current_index,
    question = text,
    stop_item_id = item and item.id or nil,
  }
  return true
end

-- Render a ranged-question answer as an inline block annotation over
-- the pending question's range. Safe to call with partial or final
-- text. Clears pending_question when final (opts.partial == false).
function M.capture_ranged_question_answer(text, opts)
  opts = opts or {}
  local review = active_review()
  if not review or not review.pending_question then
    return false
  end
  local pq = review.pending_question
  -- Bail if the user navigated to a different stop while the answer was
  -- in flight. The annotation would anchor to the wrong range; leave
  -- the log-only version and drop the inline path.
  local item = current_item(review)
  if not item or item.id ~= pq.stop_item_id then
    if not opts.partial then
      review.pending_question = nil
    end
    return false
  end

  -- Build a synthetic "stop-like" object we can hand to the existing
  -- annotation renderer. One block annotation over the question's
  -- sub-range, no line annotations, no explanation (the block IS the
  -- explanation).
  local synthetic = {
    path = pq.path,
    startLine = pq.startLine,
    endLine = pq.endLine,
    annotations = {
      {
        kind = "block",
        startLine = pq.startLine,
        endLine = pq.endLine,
        text = text,
      },
    },
  }
  -- Clear any prior render of this same answer so streaming updates
  -- replace rather than stack.
  ui.clear_stop_annotations()
  ui.set_stop_annotations(item)          -- restore the stop's own block
  ui.set_stop_annotations(synthetic)     -- layer the question answer on top

  if not opts.partial then
    review.pending_question = nil
  end
  return true
end

-- Plan helpers. Each returns:
--   { scope = "selection"|"diff", stops = { { path, startLine, endLine, title, why, kind, excerpt, id, status } } }
-- Stops never exceed MAX_REVIEW_LINES. Coverage is validated so that the
-- union of stop ranges equals the input range(s).

local function make_plan_stop(path, start_line, end_line, kind, why)
  local stop_excerpt = excerpt(path, start_line, end_line)
  local title = chunk_title(path, kind, stop_excerpt) or relative_path(path)
  return {
    id = string.format("%s:%d-%d", path, start_line, end_line),
    path = path,
    startLine = start_line,
    endLine = end_line,
    kind = kind,
    title = title,
    why = why,
    excerpt = stop_excerpt,
    status = "pending",
  }
end

local function chunk_range(path, start_line, end_line, kind, why_fn)
  local stops = {}
  local chunk_start = start_line
  while chunk_start <= end_line do
    local chunk_end = math.min(chunk_start + MAX_REVIEW_LINES - 1, end_line)
    local why = why_fn and why_fn(chunk_start, chunk_end) or nil
    table.insert(stops, make_plan_stop(path, chunk_start, chunk_end, kind, why))
    chunk_start = chunk_end + 1
  end
  return stops
end

local function ranges_cover(target_ranges, stop_ranges)
  -- target_ranges and stop_ranges are each arrays of { path, startLine, endLine }.
  -- Returns (ok, gaps). gaps is an array of uncovered { path, startLine, endLine } entries.
  local covered = {}
  for _, stop in ipairs(stop_ranges) do
    local list = covered[stop.path] or {}
    table.insert(list, { stop.startLine, stop.endLine })
    covered[stop.path] = list
  end

  local gaps = {}
  for _, target in ipairs(target_ranges) do
    local list = covered[target.path] or {}
    table.sort(list, function(a, b) return a[1] < b[1] end)
    local cursor = target.startLine
    for _, seg in ipairs(list) do
      if seg[1] > target.endLine then break end
      if seg[2] < cursor then
        -- segment ends before the cursor; skip
      else
        if seg[1] > cursor then
          table.insert(gaps, { path = target.path, startLine = cursor, endLine = seg[1] - 1 })
        end
        if seg[2] >= cursor then
          cursor = seg[2] + 1
        end
      end
    end
    if cursor <= target.endLine then
      table.insert(gaps, { path = target.path, startLine = cursor, endLine = target.endLine })
    end
  end
  return #gaps == 0, gaps
end

function M.plan_from_range(path, start_line, end_line)
  if not path or not start_line or not end_line or start_line > end_line then
    return nil
  end
  local stops = chunk_range(path, start_line, end_line, "selection", function(s, e)
    return string.format("Selected range %d-%d", s, e)
  end)
  local ok = ranges_cover({ { path = path, startLine = start_line, endLine = end_line } }, stops)
  return {
    scope = "selection",
    stops = stops,
    coverage_ok = ok,
  }
end

local function parse_diff_hunks(diff_text)
  -- Returns a map of path -> array of { startLine, endLine } (new-file line numbers
  -- of added or context regions — any line that the user should see on the new side).
  local files = {}
  local current = nil
  for _, line in ipairs(vim.split(diff_text or "", "\n", { plain = true })) do
    local new_path = line:match("^%+%+%+ b/(.+)$") or line:match("^%+%+%+ (.+)$")
    if new_path and new_path ~= "/dev/null" then
      current = { path = new_path, hunks = {} }
      files[new_path] = current
    else
      local hunk_start, hunk_len = line:match("^@@ %-%d+,?%d* %+(%d+),?(%d*)")
      if hunk_start and current then
        local s = tonumber(hunk_start)
        local l = tonumber(hunk_len)
        if l == nil or l == 0 then l = 1 end
        table.insert(current.hunks, { s, s + l - 1 })
      end
    end
  end
  local result = {}
  for path, entry in pairs(files) do
    result[path] = entry.hunks
  end
  return result
end

function M.plan_from_diff(cwd, base)
  if not cwd or not base or base == "" then
    return nil
  end
  local diff = git_run(cwd, string.format("diff --unified=0 %s...HEAD", vim.fn.shellescape(base)))
  if not diff then
    return { scope = "diff", base = base, stops = {}, coverage_ok = true }
  end
  local diff_text = table.concat(diff, "\n")
  local per_file = parse_diff_hunks(diff_text)

  local stops = {}
  local target_ranges = {}
  local sorted_paths = {}
  for path in pairs(per_file) do table.insert(sorted_paths, path) end
  table.sort(sorted_paths)

  for _, rel_path in ipairs(sorted_paths) do
    local abs_path = vim.fs.joinpath(cwd, rel_path)
    local hunks = per_file[rel_path]
    table.sort(hunks, function(a, b) return a[1] < b[1] end)
    for _, hunk in ipairs(hunks) do
      local hs, he = hunk[1], hunk[2]
      table.insert(target_ranges, { path = abs_path, startLine = hs, endLine = he })
      local chunked = chunk_range(abs_path, hs, he, "diff", function(s, e)
        return string.format("Changed lines %d-%d in %s", s, e, rel_path)
      end)
      for _, stop in ipairs(chunked) do
        table.insert(stops, stop)
      end
    end
  end

  local ok = ranges_cover(target_ranges, stops)
  return {
    scope = "diff",
    base = base,
    stops = stops,
    coverage_ok = ok,
  }
end

function M._ranges_cover(target_ranges, stop_ranges)
  return ranges_cover(target_ranges, stop_ranges)
end

-- Search `path` for the line whose trimmed content equals `needle` and
-- whose position is closest to `hint_line`. Returns the found line
-- (1-based) or nil. Used to self-correct plans whose absolute line
-- numbers are slightly off — a common LLM failure mode.
local function find_anchor_line(path, needle, hint_line)
  if not path or not needle or needle == "" then
    return nil
  end
  local trimmed_needle = vim.trim(needle)
  if trimmed_needle == "" then
    return nil
  end

  local line_count = 0
  local all_lines
  local buf = vim.fn.bufnr(path)
  if buf > 0 and vim.api.nvim_buf_is_valid(buf) then
    all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    line_count = #all_lines
  else
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok then
      return nil
    end
    all_lines = lines
    line_count = #lines
  end
  if line_count == 0 then
    return nil
  end

  local best_line = nil
  local best_distance = math.huge
  for index = 1, line_count do
    if vim.trim(all_lines[index] or "") == trimmed_needle then
      local distance = math.abs(index - (hint_line or index))
      if distance < best_distance then
        best_distance = distance
        best_line = index
      end
    end
  end
  return best_line
end

local function normalize_plan_stop(cwd, raw)
  if not raw or not raw.path or not raw.startLine or not raw.endLine then
    return nil
  end
  local path = raw.path
  if not path:match("^/") then
    path = vim.fs.joinpath(cwd, path)
  end
  local start_line = tonumber(raw.startLine)
  local end_line = tonumber(raw.endLine)
  if not start_line or not end_line or start_line > end_line then
    return nil
  end

  -- Self-correct the model's absolute line numbers using firstLineText.
  -- LLMs frequently report line numbers that are off by several lines —
  -- they get the content right but the position wrong. When we can find
  -- an exact match for `firstLineText` elsewhere in the file, shift the
  -- whole stop (and its annotation lines) by the offset so the block and
  -- inline pins land where they should.
  local offset = 0
  if raw.firstLineText and raw.firstLineText ~= "" then
    local anchor = find_anchor_line(path, raw.firstLineText, start_line)
    if anchor and anchor ~= start_line then
      offset = anchor - start_line
      start_line = anchor
      end_line = end_line + offset
    end
  end

  local stop = make_plan_stop(path, start_line, end_line, raw.kind or "planned", raw.why)
  if raw.title and raw.title ~= "" then
    stop.title = raw.title
  end
  -- `summary` populates the sidebar's Explanation section. Fall back to
  -- `why` (one-liner) if the planner didn't supply a summary.
  if raw.summary and raw.summary ~= "" then
    stop.summary = raw.summary
  else
    stop.summary = stop.why
  end
  if raw.explanation and raw.explanation ~= "" then
    stop.explanation = raw.explanation
  end
  if type(raw.annotations) == "table" then
    local clean = {}
    for _, ann in ipairs(raw.annotations) do
      if type(ann) == "table" and ann.text and ann.text ~= "" then
        -- Apply the same offset found for the stop to any annotation
        -- line numbers. The model picks annotation lines in the same
        -- (wrong) frame as its startLine, so a uniform shift is correct.
        local line_num = tonumber(ann.line)
        local ann_start = tonumber(ann.startLine)
        local ann_end = tonumber(ann.endLine)
        if offset ~= 0 then
          if line_num then line_num = line_num + offset end
          if ann_start then ann_start = ann_start + offset end
          if ann_end then ann_end = ann_end + offset end
        end
        table.insert(clean, {
          kind = ann.kind == "line" and "line" or "block",
          line = line_num,
          startLine = ann_start,
          endLine = ann_end,
          text = tostring(ann.text),
        })
      end
    end
    if #clean > 0 then
      stop.annotations = clean
    end
  end
  return stop
end

-- Start a free-scope review in "planning" state. The plan itself arrives
-- later via M.ingest_plan (driven by the sherpa_plan tool). The sidebar
-- and status widget update immediately so the user sees activity from
-- keystroke zero.
function M.start_planning(focus, opts)
  opts = opts or {}
  local session = state.get_session()
  if not session then
    ui.notify("No active Sherpa session", vim.log.levels.WARN)
    return false
  end

  ui.clear_comment_markers()
  ui.clear_stop_annotations()
  ui.hide_log()
  session.review = {
    active = true,
    awaiting_summary = false,
    comments = {},
    current_index = 0,
    focus = focus,
    goal = focus,
    items = {},
    planned = true,
    planning = true,
    scope = nil,
    source = opts.source or "review",
    summary = nil,
    title = opts.title or "Sherpa review",
  }
  -- Optimistically seed the status widget so the user sees "planning..."
  -- immediately, before the pi extension's setWidget roundtrip lands.
  state.set_widget({
    "Sherpa operation: plan",
    "Mode: read-only",
    "Planning review...",
  })
  state.set_status("sherpa", "plan active")
  state.set_status("sherpa-operation", "plan")
  state.set_status("sherpa-kind", "plan")
  ui.show_review()
  M.render()
  return true
end

-- Ingest a plan produced by the model via the sherpa_plan tool. Replaces
-- the current (empty, planning-state) plan with the given stops and
-- activates the first stop. Only valid while review.planning == true.
function M.ingest_plan(args)
  local review = active_review()
  if not review or not review.planning then
    return nil
  end
  local session = state.get_session()
  if not session then
    return nil
  end
  args = args or {}

  local stops = {}
  for _, raw in ipairs(args.stops or {}) do
    local stop = normalize_plan_stop(session.cwd, raw)
    if stop then
      table.insert(stops, stop)
    end
  end
  if #stops == 0 then
    return nil
  end

  review.scope = args.scope or "free"
  review.base = args.base
  review.items = stops
  review.current_index = 1
  review.planning = false
  review.coverage_ok = true  -- §5 coverage validation lands in a later step
  M.focus_item(stops[1])
  M.render()
  return stops[1]
end

-- Append more stops to an active free-scope review. No-op for
-- selection/diff. The model calls this via the sherpa_append_stops tool
-- when it discovers an additional area to visit mid-review.
function M.ingest_append_stops(args)
  local review = active_review()
  if not review or not review.planned or review.planning then
    return 0
  end
  if review.scope ~= "free" then
    return 0
  end
  local session = state.get_session()
  if not session then
    return 0
  end
  args = args or {}

  local added = 0
  for _, raw in ipairs(args.stops or {}) do
    local stop = normalize_plan_stop(session.cwd, raw)
    if stop then
      table.insert(review.items, stop)
      added = added + 1
    end
  end
  if added > 0 then
    M.render()
  end
  return added
end

function M.is_planning()
  local review = active_review()
  return review ~= nil and review.planning == true
end

-- Entry point for reviews whose plan is constructed deterministically on
-- the Lua side (selection, and eventually diff). Items come from
-- plan_from_* helpers and carry the `why` field.
function M.start_planned(scope, opts)
  opts = opts or {}
  local session = state.get_session()
  if not session then
    ui.notify("No active Sherpa session", vim.log.levels.WARN)
    return nil
  end

  local plan
  if scope == "selection" then
    local path = opts.path or current_buffer_path()
    if not path or not opts.startLine or not opts.endLine then
      return nil
    end
    plan = M.plan_from_range(path, opts.startLine, opts.endLine)
  end

  if not plan or #plan.stops == 0 then
    return nil
  end

  -- `summary` is the presentation alias for `why` that panel_lines shows
  -- as "Synopsis:". Plan-from-range helpers set `why`; mirror it here so
  -- the sidebar renders a non-empty synopsis for selection stops.
  for _, stop in ipairs(plan.stops) do
    stop.summary = stop.why
  end

  ui.clear_comment_markers()
  ui.clear_stop_annotations()
  ui.hide_log()
  local source = opts.resolved_source or scope
  session.review = {
    active = true,
    awaiting_summary = false,
    base = opts.resolved_base or plan.base,
    comments = {},
    coverage_ok = plan.coverage_ok,
    current_index = 1,
    focus = opts.focus,
    goal = opts.focus,
    items = plan.stops,
    planned = true,
    scope = plan.scope,
    source = source,
    summary = nil,
    title = opts.title or ("Sherpa review: " .. source),
  }
  ui.show_review()
  M.focus_item(plan.stops[1])
  return plan.stops[1]
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
    string.format("Review stop: %d of %d", review.current_index, #review.items),
    string.format("File: %s", item.path),
    string.format("Lines: %d-%d", item.startLine, item.endLine),
    item.title and ("Title: " .. item.title) or nil,
    item.why and ("Why this stop: " .. item.why) or nil,
    "Stay focused on this stop.",
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

  local next_index = (review.current_index or 0) + direction
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
  ui.clear_stop_annotations()
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
