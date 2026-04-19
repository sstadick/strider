if vim.g.loaded_sherpa == 1 then
  return
end

vim.g.loaded_sherpa = 1

vim.api.nvim_create_user_command("SherpaQ", function(opts)
  require("sherpa").question(opts.args)
end, { nargs = "+", desc = "Start or continue a Sherpa chunk flow" })

vim.api.nvim_create_user_command("SherpaNext", function()
  require("sherpa").next_step()
end, { desc = "Accept the current Sherpa chunk and continue" })

vim.api.nvim_create_user_command("SherpaChangeNext", function()
  require("sherpa").next_change()
end, { desc = "Jump to the next changed line in the current chunk" })

vim.api.nvim_create_user_command("SherpaChangePrev", function()
  require("sherpa").prev_change()
end, { desc = "Jump to the previous changed line in the current chunk" })
