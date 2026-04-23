if vim.g.loaded_sherpa == 1 then
  return
end

vim.g.loaded_sherpa = 1

vim.api.nvim_create_user_command("SherpaChat", function(opts)
  require("sherpa").chat(opts.args, opts)
end, { nargs = "*", range = true, desc = "Toggle Sherpa chat; with args or a range, open compose prefilled with context" })

vim.api.nvim_create_user_command("SherpaSearch", function(opts)
  require("sherpa").search(opts.args)
end, { nargs = "*", desc = "Run Sherpa search or open recent searches" })

vim.api.nvim_create_user_command("SherpaReview", function(opts)
  require("sherpa").review(opts.args, opts)
end, { nargs = "*", range = true, desc = "Open the Sherpa review editor on the dedicated review lane" })

vim.api.nvim_create_user_command("SherpaPatch", function(opts)
  require("sherpa").patch(opts.args, opts)
end, { nargs = "*", range = true, desc = "Open the Sherpa patch editor for a selection or active review item" })

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
end, { desc = "Open recent Sherpa flow searches" })

vim.api.nvim_create_user_command("SherpaLogFlow", function()
  require("sherpa").flow_log()
end, { desc = "Toggle the Sherpa flow log" })

vim.api.nvim_create_user_command("SherpaLogReview", function()
  require("sherpa").review_log()
end, { desc = "Toggle the Sherpa review log" })

vim.api.nvim_create_user_command("SherpaQ", function(opts)
  require("sherpa").q(opts.args, opts)
end, { nargs = "*", range = true, desc = "Open the Sherpa Q editor for a background flow-lane question" })

vim.api.nvim_create_user_command("SherpaRetry", function()
  require("sherpa").retry()
end, { desc = "Re-dispatch the Sherpa plan turn if it stalled" })

vim.api.nvim_create_user_command("SherpaStop", function()
  require("sherpa").stop()
end, { desc = "Abort the current in-flight Sherpa turn" })

