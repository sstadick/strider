if vim.g.loaded_strider == 1 then
  return
end

vim.g.loaded_strider = 1

vim.api.nvim_create_user_command("StriderChat", function(opts)
  require("strider").chat(opts.args, opts)
end, { nargs = "*", range = true, desc = "Toggle Strider chat; with args or a range, open compose prefilled with context" })

vim.api.nvim_create_user_command("StriderSearch", function(opts)
  require("strider").search(opts.args)
end, { nargs = "*", desc = "Run Strider search or open recent searches" })

vim.api.nvim_create_user_command("StriderReview", function(opts)
  require("strider").review(opts.args, opts)
end, { nargs = "*", range = true, desc = "Open the Strider review editor on the dedicated review lane" })

vim.api.nvim_create_user_command("StriderPatch", function(opts)
  require("strider").patch(opts.args, opts)
end, { nargs = "*", range = true, desc = "Open the Strider patch editor for a selection or active review item" })

vim.api.nvim_create_user_command("StriderComment", function(opts)
  require("strider").comment(opts.args, opts)
end, { nargs = "*", range = true, desc = "Leave a Strider review comment on the current item or visual selection" })

vim.api.nvim_create_user_command("StriderComments", function()
  require("strider").comments()
end, { desc = "Open Strider review comments" })

vim.api.nvim_create_user_command("StriderReviewItems", function()
  require("strider").review_items()
end, { desc = "Open Strider review items" })

vim.api.nvim_create_user_command("StriderNext", function(opts)
  require("strider").next_step(opts.bang)
end, { bang = true, desc = "Advance to the next Strider review item; ! accepts the current stop first" })

vim.api.nvim_create_user_command("StriderPrev", function()
  require("strider").prev_step()
end, { desc = "Move to the previous Strider review item" })

vim.api.nvim_create_user_command("StriderSearches", function()
  require("strider").searches()
end, { desc = "Open recent Strider flow searches" })

vim.api.nvim_create_user_command("StriderLogFlow", function()
  require("strider").flow_log()
end, { desc = "Toggle the Strider search/flow log" })

vim.api.nvim_create_user_command("StriderLogQ", function()
  require("strider").q_log()
end, { desc = "Toggle the StriderQ log" })

vim.api.nvim_create_user_command("StriderLogPatch", function()
  require("strider").patch_log()
end, { desc = "Toggle the Strider patch log" })

vim.api.nvim_create_user_command("StriderLogReview", function()
  require("strider").review_log()
end, { desc = "Toggle the Strider review log" })

vim.api.nvim_create_user_command("StriderQ", function(opts)
  require("strider").q(opts.args, opts)
end, { bang = true, nargs = "*", range = true, desc = "Open the StriderQ editor; bare toggles the latest card, ! creates a new one" })

vim.api.nvim_create_user_command("StriderCards", function()
  require("strider").cards()
end, { desc = "Pick a Strider card with telescope/fzf" })

vim.api.nvim_create_user_command("StriderRetry", function()
  require("strider").retry()
end, { desc = "Re-dispatch the Strider plan turn if it stalled" })

vim.api.nvim_create_user_command("StriderStop", function()
  require("strider").stop()
end, { desc = "Abort the current main-lane Strider turn" })

vim.api.nvim_create_user_command("StriderStopFlow", function()
  require("strider").stop_flow()
end, { desc = "Abort the current flow-lane Strider turn" })

vim.api.nvim_create_user_command("StriderSessions", function()
  require("strider").sessions()
end, { desc = "Browse saved Strider/pi sessions" })

vim.api.nvim_create_user_command("StriderResume", function(opts)
  require("strider").resume(opts.args)
end, { nargs = "*", complete = "file", desc = "Resume a Strider/pi session by id or path" })

vim.api.nvim_create_user_command("StriderStatus", function()
  require("strider").status()
end, { desc = "Open the Strider status surface" })
