local root = vim.env.STRIDER_TEST_ROOT
assert(root and root ~= "", "STRIDER_TEST_ROOT must be set")

vim.cmd("syntax on")
vim.cmd("filetype plugin indent on")
vim.opt.number = true
vim.opt.autoindent = true
vim.opt.expandtab = true
vim.opt.tabstop = 2
vim.opt.shiftwidth = 2

local user_site = vim.fn.expand("~/.local/share/nvim/site")
vim.opt.packpath:prepend(user_site)
vim.opt.packpath:append(user_site .. "/after")
vim.opt.runtimepath:prepend(user_site)
vim.opt.runtimepath:append(user_site .. "/after")

pcall(vim.cmd, "packadd plenary.nvim")
pcall(vim.cmd, "packadd telescope.nvim")
pcall(vim.cmd, "packadd fzf-lua")

pcall(function()
	require("telescope").setup({})
end)

vim.opt.rtp:append(root)
vim.cmd("runtime plugin/strider.lua")

local pi_cmd
if vim.env.STRIDER_TEST_REAL_PI == "1" then
	pi_cmd = { "pi" }
else
	pi_cmd = { vim.fn.exepath("python3"), vim.fs.joinpath(root, "tests", "support", "fake_pi.py") }
end

require("strider").setup({
	auto_jump = true,
	open_log_on_start = false,
	pi_cmd = pi_cmd,
})
