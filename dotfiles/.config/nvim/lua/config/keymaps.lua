-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- Toggle comment with Cmd+/ (macOS) or Ctrl+/ (Linux)
-- <D-/> works in GUI Neovim (Neovide, etc.)
-- For terminal Neovim on macOS, configure your terminal to send a key sequence for Cmd+/
-- iTerm2: Preferences > Keys > Add: Cmd+/ sends escape sequence: [47;6u
-- Alacritty/Kitty: Similar key binding configuration needed
vim.keymap.set("n", "<D-/>", "gcc", { remap = true, desc = "Toggle comment" })
vim.keymap.set("v", "<D-/>", "gc", { remap = true, desc = "Toggle comment" })
vim.keymap.set("i", "<D-/>", "<Esc>gcci", { remap = true, desc = "Toggle comment" })
-- Terminal fallback: Ctrl+/ (sent as <C-_> by most terminals)
vim.keymap.set("n", "<C-_>", "gcc", { remap = true, desc = "Toggle comment" })
vim.keymap.set("v", "<C-_>", "gc", { remap = true, desc = "Toggle comment" })
vim.keymap.set("i", "<C-_>", "<Esc>gcci", { remap = true, desc = "Toggle comment" })
