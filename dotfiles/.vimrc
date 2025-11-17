" Enable syntax
syntax on

" Enable 256 colors palette
set t_Co=256

" 24-bit true color
if (has("termguicolors"))
 set termguicolors
endif

" Set dark bg for tmux compatibility
set background=dark

" Set number of lines for VIM to remember
set history=500

" Increase memory limit
set maxmempattern=5000000

" Enable filetype plugins
filetype plugin on
filetype indent on

" Auto read external file changes
set autoread

" Quicksave
nmap <leader>w :w!<cr>

" :W sudo saves the file
command W w !sudo tee % > /dev/null

" Always show current position
set ruler

" Height of the command bar
set cmdheight=1

" Configure backspace so it acts as it should act
set backspace=eol,start,indent
set whichwrap+=<,>,h,l

" Ignore case when searching
set ignorecase

" When searching try to be smart about cases
set smartcase

" Highlight search results
set hlsearch

" Makes search act like search in modern browsers
set incsearch

" For regular expressions turn magic on
set magic

" Show matching brackets when text indicator is over them
set showmatch

" No annoying sound on errors
set noerrorbells
set novisualbell
set t_vb=
set tm=500

" Set utf8 as standard encoding and en_US as the standard language
set encoding=utf8

" Use Unix as the standard file type
set ffs=unix,dos,mac

" Turn backup off, since most stuff is in SVN, git, etc. anyway...
set nobackup
set nowb
set noswapfile

" 1 tab == 2 spaces
set tabstop=2
set softtabstop=2
set shiftwidth=2

" Linebreak on 500 characters
set lbr
set tw=500

" Preferred indentation and formatting
set ai "Auto indent
set si "Smart indent
set wrap "Wrap lines

" Always paste mode
set paste

" Always show status line
set laststatus=2

" Combat distro specific nuances
set nocompatible

" Combat syntax highlighting issues in large files
set redrawtime=10000

" Improve visibility of cursor
set cursorline

" Use spaces instead of tabs
set expandtab

" Be smart when using tabs ;)
set smarttab

" Attach to clipboard (<Leader> == \)
noremap <Leader>y "*y
noremap <Leader>p "*p
noremap <Leader>Y "+y
noremap <Leader>P "+p

" Clear highlighting
noremap <Leader><space> :noh<cr>

" Visual mode pressing * or # searches for the current selection
" Super useful! From an idea by Michael Naumann
vnoremap <silent> * :<C-u>call VisualSelection('', '')<CR>/<C-R>=@/<CR><CR>
vnoremap <silent> # :<C-u>call VisualSelection('', '')<CR>?<C-R>=@/<CR><CR>

" Map <Space> to / (search) and Ctrl-<Space> to ? (backwards search)
map <space> /
map <c-space> ?

" Enable mouse
set ttymouse=xterm2
set mouse=a

" Return to last known position
if has("autocmd")
  au BufReadPost * if line("'\"") > 1 && line("'\"") <= line("$") | exe "normal! g'\"" | endif
endif

" Remove all trailing whitespace on save
autocmd BufWritePre * %s/\s\+$//e

" Avoid Vim plugins on remote hosts
if !exists("$SSHHOME")
  " Install Vim Plug if not installed
  if empty(glob('~/.vim/autoload/plug.vim'))
    silent !proxy curl -fLo ~/.vim/autoload/plug.vim --create-dirs https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
    autocmd VimEnter * PlugInstall
  endif

  " Start plugin injection
  call plug#begin('~/.vim/plugged')

  " Show start/end of any surroundings
  Plug 'tpope/vim-surround'

  " For terraform syntax
  Plug 'hashivim/vim-terraform'

  " Live syntax review (requires vim >=8)
  Plug 'w0rp/ale'

  " Dynamic commenting
  Plug 'preservim/nerdcommenter'

  " Snippeting
  Plug 'neoclide/coc.nvim', {'branch': 'release'}

  " Fancy status line
  Plug 'itchyny/lightline.vim'

  " For NerdTree file explorer
  Plug 'preservim/nerdtree'

  " Syntax highlighting for languages
  Plug 'sheerun/vim-polyglot'

  " Go support
  Plug 'fatih/vim-go', { 'do': ':GoUpdateBinaries' }

  " General-purpose command-line fuzzy finder
  Plug 'junegunn/fzf', { 'do': { -> fzf#install() } }
  Plug 'junegunn/fzf.vim'

  " Initialize plugin system
  call plug#end()
endif

" Comment and uncomment lines
nnoremap <leader><leader>c :call NERDComment(0,"toggle")<CR>
vnoremap <leader><leader>c :call NERDComment(0,"toggle")<CR>

" For NerdTree
autocmd StdinReadPre * let s:std_in=1
autocmd VimEnter * if argc() == 0 && !exists("s:std_in") | NERDTree | endif
autocmd VimEnter * if argc() == 1 && isdirectory(argv()[0]) && !exists("s:std_in") | exe 'NERDTree' argv()[0] | wincmd p | ene | exe 'cd '.argv()[0] | endif
map <C-n> :NERDTreeToggle<CR>

" For netrw
let g:netrw_browse_split=4  " open in prior window
let g:netrw_altv=1          " open splits to the right
let g:netrw_liststyle=3     " tree view

" Enable completion where available.
let g:ale_completion_enabled = 1

" Set this. Airline will handle the rest.
let g:airline#extensions#ale#enabled = 1

" python
autocmd FileType python setlocal shiftwidth=4 softtabstop=4 expandtab
autocmd FileType python map <buffer> <F9> :w<CR>:exec '!python3' shellescape(@%, 1)<CR>
autocmd FileType python imap <buffer> <F9> <esc>:w<CR>:exec '!python3' shellescape(@%, 1)<CR>

let python_highlight_all = 1
au FileType python syn keyword pythonDecorator True None False self

au BufNewFile,BufRead *.jinja set syntax=htmljinja
au BufNewFile,BufRead *.html,*.htm,*.shtml,*.stm,*.j2 set ft=jinja
au BufNewFile,BufRead *.mako set ft=mako

au FileType python map <buffer> F :set foldmethod=indent<cr>

au FileType python inoremap <buffer> $r return
au FileType python inoremap <buffer> $i import
au FileType python inoremap <buffer> $p print
au FileType python inoremap <buffer> $f # --- <esc>a
au FileType python map <buffer> <leader>1 /class
au FileType python map <buffer> <leader>2 /def
au FileType python map <buffer> <leader>C ?class
au FileType python map <buffer> <leader>D ?def
au FileType python set cindent
au FileType python set cinkeys-=0#
au FileType python set indentkeys-=0#

" yaml
au FileType yaml set ts=2 sts=2 sw=2 indentexpr= nosmartindent et
au FileType yml set ts=2 sts=2 sw=2 indentexpr= nosmartindent et

silent! helptags ALL
