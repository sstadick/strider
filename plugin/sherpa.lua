if vim.g.loaded_sherpa == 1 then
  return
end

vim.g.loaded_sherpa = 1

vim.api.nvim_create_user_command("SherpaWork", function(opts)
  require("sherpa").work(opts.args)
end, { nargs = "*", desc = "Run a broader Sherpa work request" })

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

vim.api.nvim_create_user_command("SherpaLog", function()
  require("sherpa").show_log()
end, { desc = "Open the Sherpa transcript / agent buffer" })
