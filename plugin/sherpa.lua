if vim.g.loaded_sherpa == 1 then
  return
end

vim.g.loaded_sherpa = 1

vim.api.nvim_create_user_command("SherpaChat", function(opts)
  require("sherpa").chat(opts.args)
end, { nargs = "*", desc = "Open or toggle the Sherpa chat surfaces; with args, send the message" })

vim.api.nvim_create_user_command("SherpaSearch", function(opts)
  require("sherpa").search(opts.args)
end, { nargs = "*", desc = "Run Sherpa search or open recent searches" })

vim.api.nvim_create_user_command("SherpaReview", function(opts)
  require("sherpa").review(opts.args, opts)
end, { nargs = "*", range = true, desc = "Start Sherpa review mode or ask about the active review item" })

vim.api.nvim_create_user_command("SherpaPatch", function(opts)
  require("sherpa").patch(opts.args, opts)
end, { nargs = "*", range = true, desc = "Apply a selection-scoped Sherpa patch" })

vim.api.nvim_create_user_command("SherpaComment", function(opts)
  require("sherpa").comment(opts.args, opts)
end, { nargs = "*", range = true, desc = "Leave a Sherpa review comment on the current item or visual selection" })

vim.api.nvim_create_user_command("SherpaComments", function()
  require("sherpa").comments()
end, { desc = "Open Sherpa review comments" })

vim.api.nvim_create_user_command("SherpaReviewItems", function()
  require("sherpa").review_items()
end, { desc = "Open Sherpa review items" })

vim.api.nvim_create_user_command("SherpaNext", function()
  require("sherpa").next_step()
end, { desc = "Advance to the next Sherpa review item" })

vim.api.nvim_create_user_command("SherpaPrev", function()
  require("sherpa").prev_step()
end, { desc = "Move to the previous Sherpa review item" })

vim.api.nvim_create_user_command("SherpaSearches", function()
  require("sherpa").searches()
end, { desc = "Open recent Sherpa searches" })

vim.api.nvim_create_user_command("SherpaQ", function(opts)
  require("sherpa").q(opts.args, opts)
end, { nargs = "*", range = true, desc = "Ask a tangent that branches off the active session (re-invoke with no args to end)" })

vim.api.nvim_create_user_command("SherpaRetry", function()
  require("sherpa").retry()
end, { desc = "Re-dispatch the Sherpa plan turn if it stalled" })

vim.api.nvim_create_user_command("SherpaStop", function()
  require("sherpa").stop()
end, { desc = "Abort the current in-flight Sherpa turn" })

