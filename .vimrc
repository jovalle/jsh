" JSH Vim Configuration
" Loads the portable vim-plug config from lib/vim-config/
" Symlink this to ~/.vimrc

" Detect JSH directory
let s:jsh_dir = exists('$JSH_DIR') ? $JSH_DIR : expand('<sfile>:p:h')
let s:vimrc_path = s:jsh_dir . '/lib/vim-config/vimrc'

if filereadable(s:vimrc_path)
    execute 'source ' . s:vimrc_path
else
    " Fallback: minimal sensible defaults if vim-config not found
    set nocompatible
    set encoding=utf-8
    set number relativenumber
    set tabstop=4 shiftwidth=4 expandtab smartindent
    set ignorecase smartcase hlsearch incsearch
    set cursorline scrolloff=8 splitright splitbelow
    set mouse=a background=dark
    syntax on
    let mapleader = ' '
    inoremap jj <Esc>
    inoremap jk <Esc>
    nnoremap <leader>w :w<CR>
    nnoremap <leader>q :q<CR>
endif
