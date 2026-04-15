-- VS Code Dark Modern UI and syntax.
return {
  {
    "Mofiqul/vscode.nvim",
    lazy = false,
    priority = 1000,
    opts = {
      style = "dark",
      transparent = false,
      italic_comments = true,
      underline_links = true,
      disable_nvimtree_bg = true,
      terminal_colors = false,
      color_overrides = {
        vscFront = "#CCCCCC",
        vscBack = "#1F1F1F",
        vscTabCurrent = "#1F1F1F",
        vscTabOther = "#181818",
        vscTabOutside = "#181818",
        vscLeftDark = "#181818",
        vscLeftMid = "#313131",
        vscLeftLight = "#616161",
        vscPopupFront = "#CCCCCC",
        vscPopupBack = "#202020",
        vscPopupHighlightBlue = "#0078D4",
        vscPopupHighlightGray = "#313131",
        vscSplitLight = "#2B2B2B",
        vscSplitDark = "#2B2B2B",
        vscCursorLight = "#CCCCCC",
        vscSelection = "#264F78",
        vscLineNumber = "#6E7681",
        vscGitAdded = "#2EA043",
        vscGitModified = "#E2C08D",
        vscGitDeleted = "#F85149",
        vscGitRenamed = "#2EA043",
        vscGitUntracked = "#2EA043",
        vscGitIgnored = "#9D9D9D",
        vscGitStageModified = "#E2C08D",
        vscGitStageDeleted = "#F85149",
        vscGitConflicting = "#F85149",
      },
    },
  },

  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "vscode",
    },
  },

  {
    "nvim-telescope/telescope.nvim",
    cmd = "Telescope",
    opts = {
      defaults = {
        selection_caret = " ",
        prompt_prefix = " ",
      },
    },
  },
}
