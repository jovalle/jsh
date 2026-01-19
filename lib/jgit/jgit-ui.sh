# lib/jgit/jgit-ui.sh - Claude-style tabbed interview UI framework
# Sourced by lib/jgit/jgit-interactive.sh
# shellcheck shell=bash

# =============================================================================
# UI State (Global)
# =============================================================================

declare -gA _UI_ANSWERS=()          # Collected answers from interview
declare -ga _UI_TABS=()             # Tab names
declare -ga _UI_TAB_STATUS=()       # Tab status: pending|current|completed
declare -g _UI_CURRENT_TAB=0        # Current tab index
declare -g _UI_CANCELLED=0          # Set to 1 if user cancelled

# =============================================================================
# Colors and Symbols (terminal-aware)
# =============================================================================

_ui_init_colors() {
    if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]] && [[ "${TERM:-}" != "dumb" ]]; then
        _UI_RESET=$'\033[0m'
        _UI_BOLD=$'\033[1m'
        _UI_DIM=$'\033[2m'
        _UI_UNDERLINE=$'\033[4m'
        _UI_CYAN=$'\033[36m'
        _UI_GREEN=$'\033[32m'
        _UI_YELLOW=$'\033[33m'
        _UI_RED=$'\033[31m'
        _UI_BLUE=$'\033[34m'
        _UI_MAGENTA=$'\033[35m'
        _UI_INVERT=$'\033[7m'

        # Cursor control
        _UI_HIDE_CURSOR=$'\033[?25l'
        _UI_SHOW_CURSOR=$'\033[?25h'
        _UI_CLEAR_LINE=$'\033[2K'
        _UI_CURSOR_UP=$'\033[A'
        _UI_CURSOR_DOWN=$'\033[B'
        _UI_CURSOR_SAVE=$'\033[s'
        _UI_CURSOR_RESTORE=$'\033[u'

        # Symbols
        _UI_CHECK="${_UI_GREEN}✓${_UI_RESET}"
        _UI_CROSS="${_UI_RED}✗${_UI_RESET}"
        _UI_BOX_EMPTY="[ ]"
        _UI_BOX_CHECKED="[${_UI_GREEN}✓${_UI_RESET}]"
        _UI_RADIO_EMPTY="( )"
        _UI_RADIO_CHECKED="(${_UI_GREEN}●${_UI_RESET})"
        _UI_ARROW="›"
        _UI_TAB_CURRENT="●"
        _UI_TAB_PENDING="○"
        _UI_TAB_DONE="✓"
    else
        _UI_RESET='' _UI_BOLD='' _UI_DIM='' _UI_UNDERLINE=''
        _UI_CYAN='' _UI_GREEN='' _UI_YELLOW='' _UI_RED=''
        _UI_BLUE='' _UI_MAGENTA='' _UI_INVERT=''
        _UI_HIDE_CURSOR='' _UI_SHOW_CURSOR=''
        _UI_CLEAR_LINE='' _UI_CURSOR_UP='' _UI_CURSOR_DOWN=''
        _UI_CURSOR_SAVE='' _UI_CURSOR_RESTORE=''

        _UI_CHECK="[x]" _UI_CROSS="[!]"
        _UI_BOX_EMPTY="[ ]" _UI_BOX_CHECKED="[x]"
        _UI_RADIO_EMPTY="( )" _UI_RADIO_CHECKED="(*)"
        _UI_ARROW=">" _UI_TAB_CURRENT="*" _UI_TAB_PENDING="o" _UI_TAB_DONE="+"
    fi
}

# Initialize on source
_ui_init_colors

# =============================================================================
# Terminal Control
# =============================================================================

# Get terminal dimensions
_ui_term_width() {
    tput cols 2>/dev/null || echo 80
}

_ui_term_height() {
    tput lines 2>/dev/null || echo 24
}

# Move cursor
_ui_cursor_to() {
    local row="$1" col="$2"
    printf '\033[%d;%dH' "$row" "$col"
}

# Clear screen below cursor
_ui_clear_below() {
    printf '\033[J'
}

# Move cursor up N lines
_ui_move_up() {
    local n="${1:-1}"
    printf '\033[%dA' "$n"
}

# Move cursor down N lines
_ui_move_down() {
    local n="${1:-1}"
    printf '\033[%dB' "$n"
}

# =============================================================================
# Key Reading
# =============================================================================

# Read a single key press, handling escape sequences
# Output: Key name (UP, DOWN, LEFT, RIGHT, TAB, SHIFT_TAB, ENTER, ESC, or the key itself)
_ui_read_key() {
    local key
    IFS= read -rsn1 key

    # Handle escape sequences (arrows, etc.)
    if [[ "$key" == $'\x1b' ]]; then
        local seq
        IFS= read -rsn2 -t 0.1 seq
        case "$seq" in
            '[A') echo "UP" ;;
            '[B') echo "DOWN" ;;
            '[C') echo "RIGHT" ;;
            '[D') echo "LEFT" ;;
            '[Z') echo "SHIFT_TAB" ;;
            '[H') echo "HOME" ;;
            '[F') echo "END" ;;
            '[5') read -rsn1 -t 0.1; echo "PGUP" ;;
            '[6') read -rsn1 -t 0.1; echo "PGDN" ;;
            *)
                # Plain escape
                if [[ -z "$seq" ]]; then
                    echo "ESC"
                else
                    echo "UNKNOWN"
                fi
                ;;
        esac
    elif [[ "$key" == '' ]]; then
        echo "ENTER"
    elif [[ "$key" == $'\t' ]]; then
        echo "TAB"
    elif [[ "$key" == $'\x7f' ]] || [[ "$key" == $'\b' ]]; then
        echo "BACKSPACE"
    elif [[ "$key" == ' ' ]]; then
        echo "SPACE"
    else
        echo "$key"
    fi
}

# =============================================================================
# Tab Bar
# =============================================================================

# Render the tab bar
# Uses global _UI_TABS and _UI_TAB_STATUS arrays
_ui_render_tabs() {
    local output=""
    local i

    for i in "${!_UI_TABS[@]}"; do
        local name="${_UI_TABS[$i]}"
        local status="${_UI_TAB_STATUS[$i]:-pending}"
        local indicator

        case "$status" in
            current)   indicator="${_UI_INVERT}${_UI_TAB_CURRENT}${_UI_RESET}" ;;
            completed) indicator="${_UI_GREEN}${_UI_TAB_DONE}${_UI_RESET}" ;;
            *)         indicator="${_UI_DIM}${_UI_TAB_PENDING}${_UI_RESET}" ;;
        esac

        if [[ "$i" -eq "$_UI_CURRENT_TAB" ]]; then
            output+="${_UI_BOLD}${indicator} ${name}${_UI_RESET}"
        else
            output+="${_UI_DIM}${indicator} ${name}${_UI_RESET}"
        fi

        # Add separator between tabs
        if [[ "$i" -lt $(( ${#_UI_TABS[@]} - 1 )) ]]; then
            output+=" ${_UI_DIM}│${_UI_RESET} "
        fi
    done

    printf '%s\n' "$output"
}

# =============================================================================
# Multi-Select Component
# =============================================================================

# Multi-select list with keyboard navigation
# Args: question, options (array name), descriptions (array name), defaults (array name)
# Sets: _UI_ANSWERS[key] = space-separated indices of selected items
# Returns: 0 on confirm, 1 on cancel
_ui_multiselect() {
    local question="$1"
    local -n options_ref="$2"
    local -n desc_ref="$3"
    local -n defaults_ref="$4"
    local result_key="$5"

    local -a selected=()
    local cursor=0
    local total=${#options_ref[@]}

    # Initialize selection from defaults
    for i in "${!defaults_ref[@]}"; do
        if [[ "${defaults_ref[$i]}" == "1" ]] || [[ "${defaults_ref[$i]}" == "true" ]]; then
            selected+=("$i")
        fi
    done

    # Check if array contains a value
    _contains() {
        local needle="$1"
        shift
        for item in "$@"; do
            [[ "$item" == "$needle" ]] && return 0
        done
        return 1
    }

    # Render function
    _render() {
        # Clear previous render
        printf '%s' "$_UI_CLEAR_LINE"
        printf '\r%s%s%s\n\n' "$_UI_BOLD" "$question" "$_UI_RESET"

        for i in "${!options_ref[@]}"; do
            printf '%s' "$_UI_CLEAR_LINE"

            local prefix="  "
            local checkbox
            if _contains "$i" "${selected[@]}"; then
                checkbox="$_UI_BOX_CHECKED"
            else
                checkbox="$_UI_BOX_EMPTY"
            fi

            if [[ "$i" -eq "$cursor" ]]; then
                prefix="${_UI_CYAN}${_UI_ARROW}${_UI_RESET} "
            fi

            printf '%s%s %s' "$prefix" "$checkbox" "${options_ref[$i]}"

            # Add description if available
            if [[ -n "${desc_ref[$i]:-}" ]]; then
                printf ' %s%s%s' "$_UI_DIM" "${desc_ref[$i]}" "$_UI_RESET"
            fi
            printf '\n'
        done

        printf '\n%s%sSpace%s toggle · %sEnter%s confirm · %sEsc%s cancel\n' \
            "$_UI_DIM" "$_UI_RESET" "$_UI_DIM" "$_UI_RESET" "$_UI_DIM" "$_UI_RESET" "$_UI_DIM"
    }

    # Initial render
    printf '%s' "$_UI_HIDE_CURSOR"
    _render

    # Input loop
    while true; do
        local key
        key=$(_ui_read_key)

        case "$key" in
            UP|k)
                ((cursor--))
                [[ "$cursor" -lt 0 ]] && cursor=$((total - 1))
                ;;
            DOWN|j)
                ((cursor++))
                [[ "$cursor" -ge "$total" ]] && cursor=0
                ;;
            SPACE)
                # Toggle selection
                if _contains "$cursor" "${selected[@]}"; then
                    # Remove from selected
                    local new_selected=()
                    for s in "${selected[@]}"; do
                        [[ "$s" != "$cursor" ]] && new_selected+=("$s")
                    done
                    selected=("${new_selected[@]}")
                else
                    selected+=("$cursor")
                fi
                ;;
            ENTER)
                printf '%s' "$_UI_SHOW_CURSOR"
                # Move cursor up to clear our output
                _ui_move_up $((total + 4))
                _ui_clear_below

                # Store result
                _UI_ANSWERS["$result_key"]="${selected[*]}"
                return 0
                ;;
            ESC|q)
                printf '%s' "$_UI_SHOW_CURSOR"
                _ui_move_up $((total + 4))
                _ui_clear_below
                _UI_CANCELLED=1
                return 1
                ;;
        esac

        # Re-render
        _ui_move_up $((total + 4))
        _render
    done
}

# =============================================================================
# Single-Select Component
# =============================================================================

# Single-select list with keyboard navigation
# Args: question, options (array name), descriptions (array name), default_index, result_key
# Returns: 0 on confirm, 1 on cancel
_ui_singleselect() {
    local question="$1"
    local -n options_ref="$2"
    local -n desc_ref="$3"
    local cursor="${4:-0}"
    local result_key="$5"

    local total=${#options_ref[@]}

    _render() {
        printf '%s' "$_UI_CLEAR_LINE"
        printf '\r%s%s%s\n\n' "$_UI_BOLD" "$question" "$_UI_RESET"

        for i in "${!options_ref[@]}"; do
            printf '%s' "$_UI_CLEAR_LINE"

            local prefix="  "
            local radio
            if [[ "$i" -eq "$cursor" ]]; then
                prefix="${_UI_CYAN}${_UI_ARROW}${_UI_RESET} "
                radio="$_UI_RADIO_CHECKED"
            else
                radio="$_UI_RADIO_EMPTY"
            fi

            printf '%s%s %s' "$prefix" "$radio" "${options_ref[$i]}"

            if [[ -n "${desc_ref[$i]:-}" ]]; then
                printf ' %s%s%s' "$_UI_DIM" "${desc_ref[$i]}" "$_UI_RESET"
            fi
            printf '\n'
        done

        printf '\n%s%sEnter%s select · %sEsc%s cancel\n' \
            "$_UI_DIM" "$_UI_RESET" "$_UI_DIM" "$_UI_RESET" "$_UI_DIM"
    }

    printf '%s' "$_UI_HIDE_CURSOR"
    _render

    while true; do
        local key
        key=$(_ui_read_key)

        case "$key" in
            UP|k)
                ((cursor--))
                [[ "$cursor" -lt 0 ]] && cursor=$((total - 1))
                ;;
            DOWN|j)
                ((cursor++))
                [[ "$cursor" -ge "$total" ]] && cursor=0
                ;;
            ENTER)
                printf '%s' "$_UI_SHOW_CURSOR"
                _ui_move_up $((total + 4))
                _ui_clear_below
                _UI_ANSWERS["$result_key"]="$cursor"
                return 0
                ;;
            ESC|q)
                printf '%s' "$_UI_SHOW_CURSOR"
                _ui_move_up $((total + 4))
                _ui_clear_below
                _UI_CANCELLED=1
                return 1
                ;;
        esac

        _ui_move_up $((total + 4))
        _render
    done
}

# =============================================================================
# Text Input Component
# =============================================================================

# Text input with optional validation
# Args: prompt, default_value, result_key, [validator_function]
# Returns: 0 on confirm, 1 on cancel
_ui_input() {
    local prompt="$1"
    local default="$2"
    local result_key="$3"
    local validator="${4:-}"

    local value="$default"
    local cursor_pos=${#value}
    local error_msg=""

    _render() {
        printf '%s\r' "$_UI_CLEAR_LINE"
        printf '%s%s%s' "$_UI_BOLD" "$prompt" "$_UI_RESET"

        if [[ -n "$default" ]] && [[ "$value" == "$default" ]]; then
            printf ' %s(%s)%s' "$_UI_DIM" "$default" "$_UI_RESET"
        fi
        printf ': '

        # Show value with cursor
        printf '%s' "${value:0:$cursor_pos}"
        printf '%s_%s' "$_UI_UNDERLINE" "$_UI_RESET"
        printf '%s' "${value:$cursor_pos}"

        if [[ -n "$error_msg" ]]; then
            printf '\n%s%s%s' "$_UI_RED" "$error_msg" "$_UI_RESET"
        fi
    }

    _render

    while true; do
        local key
        key=$(_ui_read_key)

        case "$key" in
            ENTER)
                # Validate if validator provided
                if [[ -n "$validator" ]]; then
                    error_msg=$("$validator" "$value" 2>&1)
                    if [[ $? -ne 0 ]]; then
                        _render
                        continue
                    fi
                fi

                # Clear error line if present
                [[ -n "$error_msg" ]] && { _ui_move_up 1; printf '%s' "$_UI_CLEAR_LINE"; }
                printf '\n'

                _UI_ANSWERS["$result_key"]="$value"
                return 0
                ;;
            ESC)
                printf '\n'
                _UI_CANCELLED=1
                return 1
                ;;
            BACKSPACE)
                if [[ "$cursor_pos" -gt 0 ]]; then
                    value="${value:0:$((cursor_pos-1))}${value:$cursor_pos}"
                    ((cursor_pos--))
                fi
                ;;
            LEFT)
                [[ "$cursor_pos" -gt 0 ]] && ((cursor_pos--))
                ;;
            RIGHT)
                [[ "$cursor_pos" -lt "${#value}" ]] && ((cursor_pos++))
                ;;
            HOME)
                cursor_pos=0
                ;;
            END)
                cursor_pos=${#value}
                ;;
            UP|DOWN|TAB|SHIFT_TAB|PGUP|PGDN|UNKNOWN)
                # Ignore navigation keys in text input
                ;;
            *)
                # Insert character at cursor
                if [[ ${#key} -eq 1 ]]; then
                    value="${value:0:$cursor_pos}${key}${value:$cursor_pos}"
                    ((cursor_pos++))
                fi
                ;;
        esac

        error_msg=""
        printf '\r'
        _render
    done
}

# =============================================================================
# Timestamp Input (Specialized)
# =============================================================================

# Timestamp input with live preview
# Args: prompt, base_epoch, result_key
# Returns: 0 on confirm, 1 on cancel
_ui_timestamp_input() {
    local prompt="$1"
    local base_epoch="$2"
    local result_key="$3"

    local value=""
    local cursor_pos=0
    local preview=""
    local preview_epoch=""
    local error_msg=""

    # Source timestamp library if not already
    [[ -z "${_TS_PRESETS[irl]:-}" ]] && source "${JSH_DIR:-$HOME/.jsh}/lib/jgit/jgit-timestamp.sh"

    _update_preview() {
        if [[ -z "$value" ]]; then
            preview_epoch="$base_epoch"
            preview=$(_ts_to_display "$base_epoch")
            preview+=" (now)"
        elif _ts_is_relative "$value"; then
            preview_epoch=$(_ts_parse "$value" "$base_epoch" 2>/dev/null)
            if [[ -n "$preview_epoch" ]]; then
                # Randomize seconds for relative times
                preview_epoch=$(_ts_randomize_seconds "$preview_epoch")
                preview=$(_ts_to_display "$preview_epoch")
                local rel=$(_ts_relative_display "$preview_epoch")
                preview+=" ($rel)"
            else
                preview="Invalid format"
                preview_epoch=""
            fi
        else
            preview_epoch=$(_ts_parse "$value" 2>/dev/null)
            if [[ -n "$preview_epoch" ]]; then
                preview=$(_ts_to_display "$preview_epoch")
            else
                preview="Invalid format"
                preview_epoch=""
            fi
        fi
    }

    _render() {
        printf '%s\r' "$_UI_CLEAR_LINE"
        printf '%s%s%s: ' "$_UI_BOLD" "$prompt" "$_UI_RESET"

        # Show value with cursor
        printf '%s' "${value:0:$cursor_pos}"
        if [[ -z "$value" ]] || [[ "$cursor_pos" -eq "${#value}" ]]; then
            printf '%s_%s' "$_UI_UNDERLINE" "$_UI_RESET"
        else
            printf '%s%s%s' "$_UI_UNDERLINE" "${value:$cursor_pos:1}" "$_UI_RESET"
            printf '%s' "${value:$((cursor_pos+1))}"
        fi

        printf '\n%s' "$_UI_CLEAR_LINE"
        if [[ -n "$preview_epoch" ]]; then
            printf '  %s→%s %s\n' "$_UI_CYAN" "$_UI_RESET" "$preview"
        else
            printf '  %s→ %s%s\n' "$_UI_RED" "$preview" "$_UI_RESET"
        fi

        printf '%s' "$_UI_CLEAR_LINE"
        printf '%s  Formats: +30m, -2h, 2024-01-15 14:30, 14:30, now%s\n' "$_UI_DIM" "$_UI_RESET"
    }

    _update_preview
    _render

    while true; do
        local key
        key=$(_ui_read_key)

        case "$key" in
            ENTER)
                if [[ -z "$preview_epoch" ]]; then
                    # Invalid input
                    continue
                fi

                # Clear and move past our UI
                _ui_move_up 3
                _ui_clear_below

                _UI_ANSWERS["$result_key"]="$preview_epoch"
                return 0
                ;;
            ESC)
                _ui_move_up 3
                _ui_clear_below
                _UI_CANCELLED=1
                return 1
                ;;
            BACKSPACE)
                if [[ "$cursor_pos" -gt 0 ]]; then
                    value="${value:0:$((cursor_pos-1))}${value:$cursor_pos}"
                    ((cursor_pos--))
                fi
                ;;
            LEFT)
                [[ "$cursor_pos" -gt 0 ]] && ((cursor_pos--))
                ;;
            RIGHT)
                [[ "$cursor_pos" -lt "${#value}" ]] && ((cursor_pos++))
                ;;
            HOME)
                cursor_pos=0
                ;;
            END)
                cursor_pos=${#value}
                ;;
            UP|DOWN|TAB|SHIFT_TAB|PGUP|PGDN|UNKNOWN)
                ;;
            *)
                if [[ ${#key} -eq 1 ]]; then
                    value="${value:0:$cursor_pos}${key}${value:$cursor_pos}"
                    ((cursor_pos++))
                fi
                ;;
        esac

        _update_preview
        _ui_move_up 3
        _render
    done
}

# =============================================================================
# Confirmation Dialog
# =============================================================================

# Yes/No confirmation
# Args: question, [default: n]
# Returns: 0 for yes, 1 for no
_ui_confirm() {
    local question="$1"
    local default="${2:-n}"

    local yn_hint
    if [[ "$default" == "y" ]]; then
        yn_hint="[Y/n]"
    else
        yn_hint="[y/N]"
    fi

    printf '%s%s%s %s ' "$_UI_YELLOW" "$question" "$_UI_RESET" "$yn_hint"

    local response
    read -r response

    case "$response" in
        [yY]|[yY][eE][sS]) return 0 ;;
        [nN]|[nN][oO])     return 1 ;;
        "")
            [[ "$default" == "y" ]] && return 0 || return 1
            ;;
        *) return 1 ;;
    esac
}

# =============================================================================
# FZF Integration (when available)
# =============================================================================

# Check if fzf is available
_ui_has_fzf() {
    command -v fzf &>/dev/null
}

# Multi-select using fzf
# Args: options (array name), descriptions (array name), defaults (array name), result_key
# Returns: 0 on confirm, 1 on cancel
_ui_multiselect_fzf() {
    local -n options_ref="$1"
    local -n desc_ref="$2"
    local -n defaults_ref="$3"
    local result_key="$4"

    local -a fzf_input=()
    local -a pre_selected=()

    for i in "${!options_ref[@]}"; do
        local line="${options_ref[$i]}"
        if [[ -n "${desc_ref[$i]:-}" ]]; then
            line+=$'\t'"${desc_ref[$i]}"
        fi
        fzf_input+=("$line")

        if [[ "${defaults_ref[$i]:-}" == "1" ]] || [[ "${defaults_ref[$i]:-}" == "true" ]]; then
            pre_selected+=("$line")
        fi
    done

    local selections
    selections=$(printf '%s\n' "${fzf_input[@]}" | fzf --ansi --multi \
        --prompt="Select (Tab=toggle): " \
        --bind 'tab:toggle+down' \
        --header="Space to toggle, Enter to confirm" \
        --preview-window=hidden \
        2>/dev/null)

    if [[ -z "$selections" ]]; then
        _UI_CANCELLED=1
        return 1
    fi

    # Convert selections back to indices
    local -a selected_indices=()
    while IFS= read -r sel; do
        for i in "${!fzf_input[@]}"; do
            if [[ "${fzf_input[$i]}" == "$sel" ]]; then
                selected_indices+=("$i")
                break
            fi
        done
    done <<< "$selections"

    _UI_ANSWERS["$result_key"]="${selected_indices[*]}"
    return 0
}

# Single-select using fzf
# Args: options (array name), descriptions (array name), result_key
# Returns: 0 on confirm, 1 on cancel
_ui_singleselect_fzf() {
    local -n options_ref="$1"
    local -n desc_ref="$2"
    local result_key="$3"

    local -a fzf_input=()

    for i in "${!options_ref[@]}"; do
        local line="${options_ref[$i]}"
        if [[ -n "${desc_ref[$i]:-}" ]]; then
            line+=$'\t'"${desc_ref[$i]}"
        fi
        fzf_input+=("$line")
    done

    local selection
    selection=$(printf '%s\n' "${fzf_input[@]}" | fzf --ansi \
        --prompt="Select: " \
        --header="Enter to select" \
        --preview-window=hidden \
        2>/dev/null)

    if [[ -z "$selection" ]]; then
        _UI_CANCELLED=1
        return 1
    fi

    # Convert selection to index
    for i in "${!fzf_input[@]}"; do
        if [[ "${fzf_input[$i]}" == "$selection" ]]; then
            _UI_ANSWERS["$result_key"]="$i"
            return 0
        fi
    done

    return 1
}

# =============================================================================
# Smart Select (auto-chooses fzf or native)
# =============================================================================

# Multi-select that uses fzf if available, native otherwise
_ui_smart_multiselect() {
    local question="$1"
    local options_name="$2"
    local desc_name="$3"
    local defaults_name="$4"
    local result_key="$5"

    if _ui_has_fzf && [[ -t 0 ]]; then
        printf '%s%s%s\n\n' "$_UI_BOLD" "$question" "$_UI_RESET"
        _ui_multiselect_fzf "$options_name" "$desc_name" "$defaults_name" "$result_key"
    else
        _ui_multiselect "$question" "$options_name" "$desc_name" "$defaults_name" "$result_key"
    fi
}

# Single-select that uses fzf if available, native otherwise
_ui_smart_singleselect() {
    local question="$1"
    local options_name="$2"
    local desc_name="$3"
    local default_idx="$4"
    local result_key="$5"

    if _ui_has_fzf && [[ -t 0 ]]; then
        printf '%s%s%s\n\n' "$_UI_BOLD" "$question" "$_UI_RESET"
        _ui_singleselect_fzf "$options_name" "$desc_name" "$result_key"
    else
        _ui_singleselect "$question" "$options_name" "$desc_name" "$default_idx" "$result_key"
    fi
}

# =============================================================================
# Utility Functions
# =============================================================================

# Print a horizontal divider
# shellcheck disable=SC2120  # $1 is optional with default value
_ui_divider() {
    local char="${1:-─}"
    local width
    width=$(_ui_term_width)
    printf '%s' "$_UI_DIM"
    printf '%s' "$(printf "${char}%.0s" $(seq 1 "$width"))"
    printf '%s\n' "$_UI_RESET"
}

# Print a section header
_ui_section() {
    local title="$1"
    printf '\n%s%s %s%s\n' "$_UI_BOLD" "$_UI_CYAN" "$title" "$_UI_RESET"
    _ui_divider
}

# Print info text
_ui_info() {
    printf '%s%s%s\n' "$_UI_DIM" "$1" "$_UI_RESET"
}

# Print a key-value pair
_ui_kv() {
    local key="$1"
    local value="$2"
    printf '  %s%-15s%s %s\n' "$_UI_DIM" "$key:" "$_UI_RESET" "$value"
}

# Print success message
_ui_success() {
    printf '%s %s\n' "$_UI_CHECK" "$1"
}

# Print error message
_ui_error() {
    printf '%s %s\n' "$_UI_CROSS" "$1" >&2
}

# Print warning
_ui_warn() {
    printf '%s%s!%s %s\n' "$_UI_YELLOW" "$_UI_BOLD" "$_UI_RESET" "$1" >&2
}

# Reset UI state for new interview
_ui_reset() {
    _UI_ANSWERS=()
    _UI_TABS=()
    _UI_TAB_STATUS=()
    _UI_CURRENT_TAB=0
    _UI_CANCELLED=0
}

# =============================================================================
# Progress Indicator
# =============================================================================

# Simple spinner for long operations
# Usage: _ui_spinner_start "message"; do_work; _ui_spinner_stop
declare -g _UI_SPINNER_PID=""

_ui_spinner_start() {
    local msg="$1"
    local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

    (
        while true; do
            for (( i=0; i<${#chars}; i++ )); do
                printf '\r%s%s%s %s' "$_UI_CYAN" "${chars:$i:1}" "$_UI_RESET" "$msg"
                sleep 0.1
            done
        done
    ) &
    _UI_SPINNER_PID=$!
}

_ui_spinner_stop() {
    if [[ -n "$_UI_SPINNER_PID" ]]; then
        kill "$_UI_SPINNER_PID" 2>/dev/null
        wait "$_UI_SPINNER_PID" 2>/dev/null
        _UI_SPINNER_PID=""
        printf '\r%s\r' "$_UI_CLEAR_LINE"
    fi
}
