# vi-mode.sh - Vi-mode editing with cursor shape indicators
# Works in both bash and zsh
# shellcheck disable=SC2034

[[ -n "${_JSH_VIMODE_LOADED:-}" ]] && return 0
_JSH_VIMODE_LOADED=1

# =============================================================================
# Configuration
# =============================================================================

VIMODE_ENABLED="${VIMODE_ENABLED:-1}"
VIMODE_CURSOR="${VIMODE_CURSOR:-1}"           # Change cursor shape
VIMODE_JJ_ESCAPE="${VIMODE_JJ_ESCAPE:-1}"     # jj to exit insert mode
VIMODE_EMACS_INSERT="${VIMODE_EMACS_INSERT:-1}" # Emacs keys in insert mode

# Cursor shapes (DECSCUSR)
# 0 = default, 1 = blinking block, 2 = steady block
# 3 = blinking underline, 4 = steady underline
# 5 = blinking bar, 6 = steady bar
CURSOR_NORMAL="${CURSOR_NORMAL:-2}"   # Block for normal/command mode
CURSOR_INSERT="${CURSOR_INSERT:-6}"   # Bar for insert mode
CURSOR_VISUAL="${CURSOR_VISUAL:-2}"   # Block for visual mode

# =============================================================================
# Cursor Shape Functions
# =============================================================================

_cursor_shape() {
    # Set cursor shape via ANSI escape
    printf '\e[%d q' "$1"
}

_cursor_normal() {
    [[ "${VIMODE_CURSOR}" == "1" ]] && _cursor_shape "${CURSOR_NORMAL}"
}

_cursor_insert() {
    [[ "${VIMODE_CURSOR}" == "1" ]] && _cursor_shape "${CURSOR_INSERT}"
}

_cursor_visual() {
    [[ "${VIMODE_CURSOR}" == "1" ]] && _cursor_shape "${CURSOR_VISUAL}"
}

_cursor_reset() {
    # Reset to default cursor on exit
    printf '\e[0 q'
}

# =============================================================================
# Zsh Vi-Mode Setup
# =============================================================================

_vimode_setup_zsh() {
    [[ "${VIMODE_ENABLED}" != "1" ]] && return

    # Enable vi mode
    bindkey -v

    # Reduce key timeout (faster escape)
    export KEYTIMEOUT=1

    # Cursor shape hooks
    if [[ "${VIMODE_CURSOR}" == "1" ]]; then
        # shellcheck disable=SC2329  # ZLE widget, invoked on keymap change
        zle-keymap-select() {
            case "${KEYMAP}" in
                vicmd)      _cursor_normal ;;
                viins|main) _cursor_insert ;;
            esac
        }
        zle -N zle-keymap-select

        # shellcheck disable=SC2329  # ZLE widget, invoked on line init
        zle-line-init() {
            _cursor_insert
        }
        zle -N zle-line-init

        # Reset cursor on line finish
        # shellcheck disable=SC2329  # ZLE widget, invoked on line finish
        zle-line-finish() {
            _cursor_normal
        }
        zle -N zle-line-finish
    fi

    # jj to escape insert mode
    if [[ "${VIMODE_JJ_ESCAPE}" == "1" ]]; then
        bindkey -M viins 'jj' vi-cmd-mode
    fi

    # Emacs-style shortcuts in insert mode
    if [[ "${VIMODE_EMACS_INSERT}" == "1" ]]; then
        bindkey -M viins '^A' beginning-of-line
        bindkey -M viins '^E' end-of-line
        bindkey -M viins '^K' kill-line
        bindkey -M viins '^U' backward-kill-line
        bindkey -M viins '^W' backward-kill-word
        bindkey -M viins '^Y' yank
        bindkey -M viins '^?' backward-delete-char  # Backspace
        bindkey -M viins '^H' backward-delete-char
        bindkey -M viins '^D' delete-char-or-list
        bindkey -M viins '^B' backward-char
        bindkey -M viins '^F' forward-char
    fi

    # History search with arrows
    # Use history-substring-search if available (set by zsh.sh), otherwise fall back
    if (( ${+widgets[history-substring-search-up]} )); then
        bindkey -M viins '^[[A' history-substring-search-up
        bindkey -M viins '^[[B' history-substring-search-down
        bindkey -M vicmd '^[[A' history-substring-search-up
        bindkey -M vicmd '^[[B' history-substring-search-down
    else
        bindkey -M viins '^[[A' up-line-or-beginning-search
        bindkey -M viins '^[[B' down-line-or-beginning-search
        bindkey -M vicmd '^[[A' up-line-or-beginning-search
        bindkey -M vicmd '^[[B' down-line-or-beginning-search
    fi

    # History search in command mode
    bindkey -M vicmd '/' history-incremental-search-backward
    bindkey -M vicmd '?' history-incremental-search-forward

    # Word navigation (Alt+Arrow)
    bindkey -M viins '^[b' backward-word           # Alt+Left
    bindkey -M viins '^[f' forward-word            # Alt+Right
    bindkey -M viins '^[[1;3D' backward-word       # Alt+Left (alternate)
    bindkey -M viins '^[[1;3C' forward-word        # Alt+Right (alternate)

    # Ctrl+Arrow word navigation
    bindkey -M viins '^[[1;5D' backward-word       # Ctrl+Left
    bindkey -M viins '^[[1;5C' forward-word        # Ctrl+Right

    # Edit command in $EDITOR (V to edit, v remains visual mode)
    autoload -Uz edit-command-line
    zle -N edit-command-line
    bindkey -M vicmd 'V' edit-command-line
    bindkey -M viins '^X^E' edit-command-line

    # Clear screen
    bindkey -M viins '^L' clear-screen
    bindkey -M vicmd '^L' clear-screen

    # Undo/redo
    bindkey -M vicmd 'u' undo
    # Ctrl+R: use redo only if fzf available (fzf overrides for history search)
    # Otherwise, use history-beginning-search (works with complex multi-line prompts)
    if has fzf; then
        bindkey -M vicmd '^R' redo
    else
        # history-beginning-search: type prefix, then Ctrl+R cycles through matches
        # More compatible with multi-line prompts than incremental search
        bindkey -M vicmd '^R' history-beginning-search-backward
        bindkey -M viins '^R' history-beginning-search-backward
        bindkey -M vicmd '^S' history-beginning-search-forward
        bindkey -M viins '^S' history-beginning-search-forward
    fi

    # Beginning/end of history
    bindkey -M vicmd 'gg' beginning-of-buffer-or-history
    bindkey -M vicmd 'G' end-of-buffer-or-history

    # Yank to system clipboard (if available)
    if has pbcopy || has xclip || has xsel; then
        # shellcheck disable=SC2329  # ZLE widget, bound via bindkey
        _vimode_yank_clipboard() {
            zle vi-yank
            if has pbcopy; then
                echo "${CUTBUFFER}" | pbcopy
            elif has xclip; then
                echo "${CUTBUFFER}" | xclip -selection clipboard
            elif has xsel; then
                echo "${CUTBUFFER}" | xsel --clipboard
            fi
        }
        zle -N _vimode_yank_clipboard
        bindkey -M vicmd 'Y' _vimode_yank_clipboard
    fi
}

# =============================================================================
# Bash Vi-Mode Setup
# =============================================================================

_vimode_setup_bash() {
    [[ "${VIMODE_ENABLED}" != "1" ]] && return

    # Enable vi mode
    set -o vi

    # Cursor shape hooks via PROMPT_COMMAND
    if [[ "${VIMODE_CURSOR}" == "1" ]]; then
        # Insert mode cursor on new prompt
        # shellcheck disable=SC2329  # Used in PROMPT_COMMAND
        _vimode_prompt_hook() {
            _cursor_insert
        }

        if [[ -z "${PROMPT_COMMAND:-}" ]]; then
            PROMPT_COMMAND="_vimode_prompt_hook"
        else
            PROMPT_COMMAND="_vimode_prompt_hook; ${PROMPT_COMMAND}"
        fi

        # Note: Bash doesn't have native keymap-change hooks
        # Cursor changes work via readline (inputrc) bindings
    fi

    # Key bindings via bind
    # jj to escape (requires inputrc support, see config/inputrc)

    # History search with arrows
    bind '"\e[A": history-search-backward' 2>/dev/null
    bind '"\e[B": history-search-forward' 2>/dev/null

    # Word navigation
    bind '"\e[1;5D": backward-word' 2>/dev/null  # Ctrl+Left
    bind '"\e[1;5C": forward-word' 2>/dev/null   # Ctrl+Right
    bind '"\eb": backward-word' 2>/dev/null      # Alt+b
    bind '"\ef": forward-word' 2>/dev/null       # Alt+f

    # Clear screen in both modes
    bind -m vi-insert '"\C-l": clear-screen' 2>/dev/null
    bind -m vi-command '"\C-l": clear-screen' 2>/dev/null

    # Emacs shortcuts in insert mode
    if [[ "${VIMODE_EMACS_INSERT}" == "1" ]]; then
        bind -m vi-insert '"\C-a": beginning-of-line' 2>/dev/null
        bind -m vi-insert '"\C-e": end-of-line' 2>/dev/null
        bind -m vi-insert '"\C-k": kill-line' 2>/dev/null
        bind -m vi-insert '"\C-u": unix-line-discard' 2>/dev/null
        bind -m vi-insert '"\C-w": unix-word-rubout' 2>/dev/null
    fi

    # Edit command in editor
    bind -m vi-command '"\C-x\C-e": edit-and-execute-command' 2>/dev/null
    bind -m vi-insert '"\C-x\C-e": edit-and-execute-command' 2>/dev/null
}

# =============================================================================
# Public API
# =============================================================================

vimode_init() {
    if [[ "${JSH_SHELL}" == "zsh" ]]; then
        _vimode_setup_zsh
    else
        _vimode_setup_bash
    fi

    # Reset cursor on shell exit
    trap '_cursor_reset' EXIT
}

vimode_enable() {
    VIMODE_ENABLED=1
    vimode_init
}

vimode_disable() {
    VIMODE_ENABLED=0
    if [[ "${JSH_SHELL}" == "zsh" ]]; then
        bindkey -e  # Emacs mode
    else
        set +o vi
    fi
    _cursor_reset
}

# Mode indicator for prompt (if needed separately)
vimode_indicator() {
    # Returns current mode for prompt integration
    # Note: This is difficult in bash without ZLE
    if [[ "${JSH_SHELL}" == "zsh" ]]; then
        case "${KEYMAP:-viins}" in
            vicmd) echo "N" ;;  # Normal
            viins|main) echo "I" ;;  # Insert
            visual|viopp) echo "V" ;;  # Visual
            *) echo "I" ;;
        esac
    else
        echo "I"  # Bash doesn't expose this easily
    fi
}
