" =============================================================================
" JSH Vim Configuration
" =============================================================================
" Symlinked to ~/.vimrc
" Designed for SSH sessions - works with bundled plugins or standalone
" Inspired by LazyVim keybindings and sensible defaults

set nocompatible
set encoding=utf-8
scriptencoding utf-8

" =============================================================================
" Plugin Manager (vim-plug)
" =============================================================================

" Detect config directory (supports JSH_EPHEMERAL for SSH sessions)
let s:config_dir = exists('$JSH_EPHEMERAL')
      \ ? $JSH_EPHEMERAL . '/lib/vim-config'
      \ : exists('$JSH_DIR')
      \ ? $JSH_DIR . '/lib/vim-config'
      \ : expand('~/.jsh/lib/vim-config')

let s:plug_file = s:config_dir . '/autoload/plug.vim'
let s:plugged_dir = s:config_dir . '/plugged'

" Load vim-plug if available
if filereadable(s:plug_file)
    execute 'source ' . s:plug_file

    call plug#begin(s:plugged_dir)

    " Standard plugin declarations
    " vim-plug automatically uses existing plugins from plugged_dir if present
    " (no network calls if already downloaded)
    Plug 'junegunn/fzf', { 'do': { -> fzf#install() } }
    Plug 'junegunn/fzf.vim'
    Plug 'tpope/vim-fugitive'
    Plug 'airblade/vim-gitgutter'
    Plug 'itchyny/lightline.vim'
    Plug 'preservim/nerdtree'
    Plug 'tpope/vim-surround'
    Plug 'tpope/vim-commentary'

    call plug#end()

    " Lightline config (must be after plug#end)
    let g:lightline = {
          \ 'colorscheme': 'one',
          \ 'active': {
          \   'left': [ [ 'mode', 'paste' ],
          \             [ 'gitbranch', 'filename', 'modified' ] ],
          \   'right': [ [ 'lineinfo' ],
          \              [ 'percent' ],
          \              [ 'filetype' ] ]
          \ },
          \ 'inactive': {
          \   'left': [ [ 'filename' ] ],
          \   'right': [ [ 'lineinfo' ] ]
          \ },
          \ 'component_function': {
          \   'gitbranch': 'LightlineGitBranch',
          \   'filename': 'LightlineFilename',
          \ },
          \ 'mode_map': {
          \   'n': 'NORMAL', 'i': 'INSERT', 'R': 'REPLACE',
          \   'v': 'VISUAL', 'V': 'V-LINE', "\<C-v>": 'V-BLOCK',
          \   'c': 'COMMAND', 's': 'SELECT', 'S': 'S-LINE', "\<C-s>": 'S-BLOCK', 't': 'TERMINAL',
          \ },
          \ 'separator': { 'left': '', 'right': '' },
          \ 'subseparator': { 'left': '', 'right': '' },
          \ }

    " Git branch with icon for lightline
    function! LightlineGitBranch()
        if exists('*FugitiveHead')
            let l:branch = FugitiveHead()
            return l:branch !=# '' ? ' ' . l:branch : ''
        endif
        return ''
    endfunction

    " Relative filepath for lightline
    function! LightlineFilename()
        let l:filename = expand('%:~:.')
        return l:filename !=# '' ? l:filename : '[No Name]'
    endfunction
endif

" =============================================================================
" Core Settings
" =============================================================================

" Appearance
set number                      " Line numbers
set relativenumber              " Relative line numbers
set cursorline                  " Highlight current line
set cursorlineopt=number        " Only highlight line number, not whole line
set scrolloff=8                 " Keep 8 lines above/below cursor
set sidescrolloff=8             " Keep 8 columns left/right of cursor
set signcolumn=auto             " Show sign column only when needed
set numberwidth=4               " Consistent line number column width
set showmatch                   " Highlight matching brackets
set laststatus=2                " Always show statusline
set showcmd                     " Show command in bottom bar
set wildmenu                    " Visual command autocomplete
set wildmode=list:longest,full  " Complete longest common, then all

" Colors
syntax enable
set background=dark
if has('termguicolors')
    set termguicolors
endif

" Clean line numbers (transparent background, current line bright)
highlight CursorLine   cterm=NONE ctermbg=NONE guibg=NONE
highlight CursorLineNr cterm=NONE ctermfg=255 ctermbg=NONE guifg=#ffffff guibg=NONE
highlight LineNr       ctermfg=240 ctermbg=NONE guifg=#585858 guibg=NONE
highlight SignColumn   ctermbg=NONE guibg=NONE

" Behavior
set hidden                      " Allow hidden buffers
set autoread                    " Auto-reload changed files
set backspace=indent,eol,start  " Backspace over everything
set mouse=a                     " Enable mouse support
set clipboard=unnamed           " Use system clipboard
set splitright                  " Open vertical splits to the right
set splitbelow                  " Open horizontal splits below

" Indentation
set tabstop=4                   " Tab width
set shiftwidth=4                " Indent width
set softtabstop=4               " Soft tab width
set expandtab                   " Use spaces instead of tabs
set smartindent                 " Smart auto-indentation
set autoindent                  " Copy indent from previous line

" Search
set ignorecase                  " Case-insensitive search
set smartcase                   " Case-sensitive if uppercase present
set hlsearch                    " Highlight search results
set incsearch                   " Show matches while typing

" Performance
set lazyredraw                  " Don't redraw during macros
set timeoutlen=500              " Faster key sequence timeout
set ttimeoutlen=10              " Faster escape key
set updatetime=250              " Faster CursorHold events

" Files
set noswapfile                  " Disable swap files
set nobackup                    " Disable backup files
set nowritebackup               " Disable write backup
set undofile                    " Persistent undo
set undodir=~/.vim/undodir      " Undo directory

" Ensure undo directory exists
if !isdirectory(expand('~/.vim/undodir'))
    silent! call mkdir(expand('~/.vim/undodir'), 'p')
endif

" =============================================================================
" Key Mappings (LazyVim-inspired)
" =============================================================================

" Leader key
let mapleader = ' '
let maplocalleader = ','

" Better escape
inoremap jj <Esc>
inoremap jk <Esc>

" Clear search highlight
nnoremap <Esc> :nohlsearch<CR>
nnoremap <leader>h :nohlsearch<CR>

" Save and quit
nnoremap <leader>w :w<CR>
nnoremap <leader>q :q<CR>
nnoremap <leader>x :x<CR>
nnoremap <leader>Q :qa!<CR>

" Window navigation (Ctrl + hjkl)
nnoremap <C-h> <C-w>h
nnoremap <C-j> <C-w>j
nnoremap <C-k> <C-w>k
nnoremap <C-l> <C-w>l

" Window splitting
nnoremap <leader>- :split<CR>
nnoremap <leader>\| :vsplit<CR>
nnoremap <leader>sv :vsplit<CR>
nnoremap <leader>sh :split<CR>

" Buffer navigation
nnoremap <S-h> :bprevious<CR>
nnoremap <S-l> :bnext<CR>
nnoremap <leader>bd :bdelete<CR>
nnoremap <leader>bb :Buffers<CR>

" Better movement
nnoremap j gj
nnoremap k gk
nnoremap <C-d> <C-d>zz
nnoremap <C-u> <C-u>zz
nnoremap n nzzzv
nnoremap N Nzzzv

" Move lines up/down
vnoremap J :m '>+1<CR>gv=gv
vnoremap K :m '<-2<CR>gv=gv

" Keep visual selection when indenting
vnoremap < <gv
vnoremap > >gv

" Yank to end of line (consistent with D, C)
nnoremap Y y$

" Quick access to vimrc
nnoremap <leader>ve :edit $MYVIMRC<CR>
nnoremap <leader>vr :source $MYVIMRC<CR>

" =============================================================================
" Plugin Mappings
" =============================================================================

" FZF (fuzzy finder)
if exists(':Files')
    nnoremap <leader>ff :Files<CR>
    nnoremap <leader>fg :GFiles<CR>
    nnoremap <leader>fb :Buffers<CR>
    nnoremap <leader>fh :History<CR>
    nnoremap <leader>fr :History<CR>
    nnoremap <leader>fc :History:<CR>
    nnoremap <leader>fs :Rg<Space>
    nnoremap <leader>fw :Rg <C-r><C-w><CR>
    nnoremap <leader>/ :BLines<CR>
    nnoremap <C-p> :Files<CR>
endif

" NERDTree (file explorer)
if exists(':NERDTree')
    nnoremap <leader>e :NERDTreeToggle<CR>
    nnoremap <leader>E :NERDTreeFind<CR>
    " Close NERDTree when opening a file
    let NERDTreeQuitOnOpen = 1
    let NERDTreeShowHidden = 1
    let NERDTreeMinimalUI = 1
    let NERDTreeIgnore = ['\.pyc$', '__pycache__', '\.git$', 'node_modules']
endif

" Git (fugitive)
if exists(':Git')
    nnoremap <leader>gs :Git<CR>
    nnoremap <leader>gc :Git commit<CR>
    nnoremap <leader>gp :Git push<CR>
    nnoremap <leader>gl :Git pull<CR>
    nnoremap <leader>gb :Git blame<CR>
    nnoremap <leader>gd :Gdiffsplit<CR>
    nnoremap <leader>gL :Git log --oneline<CR>
endif

" GitGutter
if exists(':GitGutter')
    nnoremap ]h :GitGutterNextHunk<CR>
    nnoremap [h :GitGutterPrevHunk<CR>
    nnoremap <leader>ghs :GitGutterStageHunk<CR>
    nnoremap <leader>ghu :GitGutterUndoHunk<CR>
    nnoremap <leader>ghp :GitGutterPreviewHunk<CR>
    let g:gitgutter_sign_added = '+'
    let g:gitgutter_sign_modified = '~'
    let g:gitgutter_sign_removed = '-'
endif

" Commentary (commenting)
" gcc - toggle comment on line
" gc in visual mode - toggle comment on selection
" gcap - comment a paragraph

" Surround
" cs"' - change surrounding " to '
" ds" - delete surrounding "
" ysiw" - surround word with "

" =============================================================================
" Plugin Configuration
" =============================================================================

" FZF layout
if exists('g:loaded_fzf')
    let g:fzf_layout = { 'down': '40%' }
    let g:fzf_preview_window = ['right:50%', 'ctrl-/']

    " Use bundled fzf binary if available
    if executable($JSH_DIR . '/lib/bin/' . $JSH_PLATFORM . '/fzf')
        let $FZF_DEFAULT_COMMAND = $JSH_DIR . '/lib/bin/' . $JSH_PLATFORM . '/fzf'
    endif
endif

" =============================================================================
" Autocommands
" =============================================================================

augroup jsh_vimrc
    autocmd!

    " Return to last edit position when opening files
    autocmd BufReadPost *
          \ if line("'\"") > 1 && line("'\"") <= line("$") |
          \   execute "normal! g'\"" |
          \ endif

    " Trim trailing whitespace on save
    autocmd BufWritePre * :%s/\s\+$//e

    " Auto-resize splits when window is resized
    autocmd VimResized * wincmd =

    " Highlight yanked text briefly
    if exists('##TextYankPost')
        autocmd TextYankPost * silent! lua vim.highlight.on_yank({timeout=200})
    endif

    " Filetype-specific settings
    autocmd FileType python setlocal tabstop=4 shiftwidth=4
    autocmd FileType javascript,typescript,json,yaml setlocal tabstop=2 shiftwidth=2
    autocmd FileType make setlocal noexpandtab
    autocmd FileType gitcommit setlocal spell textwidth=72

augroup END

" =============================================================================
" Which-Key Style Help
" =============================================================================

" Show available keymaps with <leader>?
function! s:ShowHelp()
    echo "JSH Vim Keybindings"
    echo "─────────────────────────────"
    echo "<Space>f  - Find files/buffers/grep"
    echo "<Space>e  - File explorer (NERDTree)"
    echo "<Space>g  - Git commands"
    echo "<Space>w  - Save file"
    echo "<Space>q  - Quit"
    echo "<Space>-  - Split horizontal"
    echo "<Space>|  - Split vertical"
    echo "<Space>b  - Buffer commands"
    echo "Ctrl+hjkl - Navigate windows"
    echo "gcc       - Toggle comment"
    echo "]h / [h   - Next/prev git hunk"
endfunction
nnoremap <leader>? :call <SID>ShowHelp()<CR>

" =============================================================================
" End of Configuration
" =============================================================================
