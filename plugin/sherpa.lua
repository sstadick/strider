if vim.g.loaded_sherpa == 1 then
  return
end

vim.g.loaded_sherpa = 1

vim.api.nvim_create_user_command("SherpaStart", function(opts)
  require("sherpa").start(opts.args)
end, { nargs = "+", desc = "Start a guided Sherpa task" })

vim.api.nvim_create_user_command("SherpaQ", function(opts)
  require("sherpa").question(opts.args)
end, { nargs = "+", desc = "Ask Sherpa about the current chunk" })

vim.api.nvim_create_user_command("SherpaNext", function()
  require("sherpa").next_step()
end, { desc = "Advance Sherpa to the next chunk" })

vim.api.nvim_create_user_command("SherpaRevise", function(opts)
  require("sherpa").revise(opts.args)
end, { nargs = "+", desc = "Revise the current Sherpa chunk" })

vim.api.nvim_create_user_command("SherpaStatus", function()
  require("sherpa").status()
end, { desc = "Show Sherpa status" })
