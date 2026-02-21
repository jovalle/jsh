# lib/gitx/gitx-timestamp.sh - Timestamp parsing, arithmetic, and randomization
# Sourced by lib/gitx/gitx-interactive.sh
# shellcheck shell=bash

# =============================================================================
# Platform Detection
# =============================================================================

# Detect if we have GNU date (Linux) or BSD date (macOS)
_ts_is_gnu_date() {
    date --version &>/dev/null
}

# =============================================================================
# Core Timestamp Functions
# =============================================================================

# Convert epoch to git-compatible format (YYYY-MM-DD HH:MM:SS +ZZZZ)
# Args: epoch_seconds
# Output: formatted date string
_ts_to_git_format() {
    local epoch="$1"
    if _ts_is_gnu_date; then
        date -d "@$epoch" "+%Y-%m-%d %H:%M:%S %z"
    else
        date -r "$epoch" "+%Y-%m-%d %H:%M:%S %z"
    fi
}

# Convert epoch to human-readable format for display
# Args: epoch_seconds
# Output: formatted date string
_ts_to_display() {
    local epoch="$1"
    if _ts_is_gnu_date; then
        date -d "@$epoch" "+%a %b %d %H:%M:%S %Y"
    else
        date -r "$epoch" "+%a %b %d %H:%M:%S %Y"
    fi
}

# Convert epoch to ISO format
# Args: epoch_seconds
# Output: ISO 8601 string
_ts_to_iso() {
    local epoch="$1"
    if _ts_is_gnu_date; then
        date -d "@$epoch" "+%Y-%m-%dT%H:%M:%S%z"
    else
        date -r "$epoch" "+%Y-%m-%dT%H:%M:%S%z"
    fi
}

# Get current epoch time
_ts_now() {
    date +%s
}

# =============================================================================
# Relative Time Parsing
# =============================================================================

# Parse relative offset to seconds
# Args: offset_string (e.g., "+30m", "-2h", "+1d", "+1h30m")
# Output: seconds (positive or negative)
# Returns: 0 on success, 1 on parse error
_ts_parse_relative() {
    local input="$1"
    local sign=1
    local total=0
    local remaining

    # Handle sign
    if [[ "$input" == -* ]]; then
        sign=-1
        remaining="${input:1}"
    elif [[ "$input" == +* ]]; then
        remaining="${input:1}"
    else
        remaining="$input"
    fi

    # Parse components (supports compound like "1h30m")
    while [[ -n "$remaining" ]]; do
        local num unit
        if [[ "$remaining" =~ ^([0-9]+)([smhdwMy])(.*)$ ]]; then
            num="${BASH_REMATCH[1]}"
            unit="${BASH_REMATCH[2]}"
            remaining="${BASH_REMATCH[3]}"

            case "$unit" in
                s) total=$((total + num)) ;;
                m) total=$((total + num * 60)) ;;
                h) total=$((total + num * 3600)) ;;
                d) total=$((total + num * 86400)) ;;
                w) total=$((total + num * 604800)) ;;
                M) total=$((total + num * 2592000)) ;;  # ~30 days
                y) total=$((total + num * 31536000)) ;; # ~365 days
                *) return 1 ;;
            esac
        else
            return 1
        fi
    done

    echo $((sign * total))
}

# Check if string looks like a relative time
# Args: string
# Returns: 0 if relative, 1 otherwise
_ts_is_relative() {
    local input="$1"
    [[ "$input" =~ ^[+-]?[0-9]+[smhdwMy] ]]
}

# =============================================================================
# Absolute Time Parsing
# =============================================================================

# Parse absolute datetime string to epoch
# Supports: "YYYY-MM-DD HH:MM:SS", "YYYY-MM-DD HH:MM", "YYYY-MM-DD", "HH:MM:SS", "HH:MM"
# Args: datetime_string
# Output: epoch timestamp
# Returns: 0 on success, 1 on parse error
_ts_parse_absolute() {
    local input="$1"
    local epoch

    # Handle special keywords
    case "$input" in
        now)
            _ts_now
            return 0
            ;;
        yesterday)
            echo $(( $(_ts_now) - 86400 ))
            return 0
            ;;
        tomorrow)
            echo $(( $(_ts_now) + 86400 ))
            return 0
            ;;
    esac

    # Try GNU date first (more flexible)
    if _ts_is_gnu_date; then
        epoch=$(date -d "$input" +%s 2>/dev/null) && { echo "$epoch"; return 0; }
    fi

    # BSD date fallback - try common formats
    local formats=(
        "%Y-%m-%d %H:%M:%S"
        "%Y-%m-%d %H:%M"
        "%Y-%m-%d"
        "%Y/%m/%d %H:%M:%S"
        "%Y/%m/%d %H:%M"
        "%Y/%m/%d"
    )

    for fmt in "${formats[@]}"; do
        if _ts_is_gnu_date; then
            epoch=$(date -d "$input" +%s 2>/dev/null)
        else
            epoch=$(date -j -f "$fmt" "$input" +%s 2>/dev/null)
        fi
        if [[ -n "$epoch" ]]; then
            echo "$epoch"
            return 0
        fi
    done

    # Try time-only formats (assume today)
    if [[ "$input" =~ ^([0-9]{1,2}):([0-9]{2})(:([0-9]{2}))?$ ]]; then
        local hour="${BASH_REMATCH[1]}"
        local min="${BASH_REMATCH[2]}"
        local sec="${BASH_REMATCH[4]:-0}"

        # Get today's date at midnight
        local today_str
        if _ts_is_gnu_date; then
            today_str=$(date +%Y-%m-%d)
            epoch=$(date -d "$today_str $hour:$min:$sec" +%s 2>/dev/null)
        else
            today_str=$(date +%Y-%m-%d)
            epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$today_str $hour:$min:$sec" +%s 2>/dev/null)
        fi

        if [[ -n "$epoch" ]]; then
            echo "$epoch"
            return 0
        fi
    fi

    return 1
}

# =============================================================================
# Main Parser
# =============================================================================

# Parse any time string to epoch
# Args: time_string, [base_epoch] (for relative times, defaults to now)
# Output: epoch timestamp
# Returns: 0 on success, 1 on parse error
_ts_parse() {
    local input="$1"
    local base="${2:-$(_ts_now)}"

    # Empty input means "now"
    if [[ -z "$input" ]]; then
        echo "$base"
        return 0
    fi

    # Check for relative time
    if _ts_is_relative "$input"; then
        local offset
        offset=$(_ts_parse_relative "$input") || return 1
        echo $((base + offset))
        return 0
    fi

    # Try absolute parsing
    _ts_parse_absolute "$input"
}

# Detect precision from a relative time string
# Args: relative_time_string (e.g., "+1h", "+30m", "+1h30m45s")
# Output: "hour" | "minute" | "second" | "full"
# Returns: 0 on success, 1 if not a relative time
_ts_detect_precision() {
    local input="$1"

    # Not a relative time
    if ! _ts_is_relative "$input"; then
        echo "full"
        return 0
    fi

    # Strip leading sign
    local remaining="${input#[+-]}"

    # Check which units are present (smallest unit determines precision)
    if [[ "$remaining" =~ [0-9]+s ]]; then
        echo "full"  # Seconds specified = no randomization
    elif [[ "$remaining" =~ [0-9]+m ]]; then
        echo "minute"  # Minutes specified = randomize seconds
    elif [[ "$remaining" =~ [0-9]+[hdwMy] ]]; then
        echo "hour"  # Hours or larger = randomize minutes and seconds
    else
        echo "full"  # Unknown, don't randomize
    fi
}

# =============================================================================
# Randomization
# =============================================================================

# Generate random integer in range [min, max]
# Args: min, max
# Output: random integer
_ts_random_range() {
    local min="$1"
    local max="$2"
    echo $(( RANDOM % (max - min + 1) + min ))
}

# Randomize seconds (0-59)
# Args: epoch
# Output: epoch with randomized seconds
_ts_randomize_seconds() {
    local epoch="$1"
    local current_sec=$(( epoch % 60 ))
    local new_sec=$(_ts_random_range 0 59)
    echo $(( epoch - current_sec + new_sec ))
}

# Randomize minutes and seconds
# Args: epoch
# Output: epoch with randomized minutes and seconds
_ts_randomize_minutes() {
    local epoch="$1"
    # First, align to hour boundary
    local hour_epoch=$(( (epoch / 3600) * 3600 ))
    local new_min=$(_ts_random_range 0 59)
    local new_sec=$(_ts_random_range 0 59)
    echo $(( hour_epoch + new_min * 60 + new_sec ))
}

# Smart randomization based on what was provided
# Args: epoch, precision ("hour" | "minute" | "second" | "full")
# Output: epoch with randomized unprovided components
_ts_randomize() {
    local epoch="$1"
    local precision="${2:-second}"  # Default to randomizing only seconds

    case "$precision" in
        full)
            # No randomization
            echo "$epoch"
            ;;
        hour)
            # Randomize minutes and seconds
            _ts_randomize_minutes "$epoch"
            ;;
        minute)
            # Randomize seconds only
            _ts_randomize_seconds "$epoch"
            ;;
        second)
            # Randomize seconds only (common case for offsets like +30m)
            _ts_randomize_seconds "$epoch"
            ;;
    esac
}

# =============================================================================
# Chronological Enforcement
# =============================================================================

# Ensure timestamp is after minimum (for commit sequences)
# Args: proposed_epoch, min_epoch, [min_gap_seconds] (default: 60)
# Output: adjusted epoch (either proposed or min + gap)
_ts_ensure_after() {
    local proposed="$1"
    local min_epoch="$2"
    local min_gap="${3:-60}"  # Default 1 minute gap

    local required=$((min_epoch + min_gap))
    if [[ "$proposed" -lt "$required" ]]; then
        # Add some randomness to the gap (min_gap to min_gap*2)
        local extra=$(_ts_random_range 0 "$min_gap")
        echo $((required + extra))
    else
        echo "$proposed"
    fi
}

# =============================================================================
# Preset Patterns
# =============================================================================

# Preset definitions (gap_min, gap_max in seconds, optional hour constraints)
declare -gA _TS_PRESETS=(
    [work-hours]="gap_min=1800 gap_max=7200 hour_min=9 hour_max=17"
    [quick-fix]="gap_min=300 gap_max=900"
    [deep-work]="gap_min=3600 gap_max=10800"
    [irl]="gap_min=900 gap_max=7200"
    [morning]="gap_min=600 gap_max=3600 hour_min=6 hour_max=12"
    [evening]="gap_min=900 gap_max=5400 hour_min=18 hour_max=23"
    [night-owl]="gap_min=1200 gap_max=4800 hour_min=22 hour_max=4"
)

# List available presets
_ts_preset_list() {
    printf '%s\n' "${!_TS_PRESETS[@]}"
}

# Get preset description
_ts_preset_description() {
    local preset="$1"
    case "$preset" in
        work-hours) echo "Business hours (9-5), 30m-2h gaps" ;;
        quick-fix)  echo "Rapid iterations, 5-15m gaps" ;;
        deep-work)  echo "Focused sessions, 1-3h gaps" ;;
        irl)        echo "Realistic simulation, 15m-2h gaps" ;;
        morning)    echo "Early bird, 6am-12pm, 10m-1h gaps" ;;
        evening)    echo "After work, 6pm-11pm, 15m-1.5h gaps" ;;
        night-owl)  echo "Late night, 10pm-4am, 20m-1.3h gaps" ;;
        *)          echo "Unknown preset" ;;
    esac
}

# Clamp epoch to hour window
# Args: epoch, hour_min, hour_max
# Output: adjusted epoch within hour window
_ts_clamp_to_hours() {
    local epoch="$1"
    local hour_min="$2"
    local hour_max="$3"

    local hour min sec
    if _ts_is_gnu_date; then
        hour=$(date -d "@$epoch" +%H)
        min=$(date -d "@$epoch" +%M)
        sec=$(date -d "@$epoch" +%S)
    else
        hour=$(date -r "$epoch" +%H)
        min=$(date -r "$epoch" +%M)
        sec=$(date -r "$epoch" +%S)
    fi
    # Remove leading zeros for arithmetic
    hour=$((10#$hour))
    min=$((10#$min))
    sec=$((10#$sec))

    # Handle wrapping (e.g., night-owl: 22-4)
    local in_window=false
    if [[ "$hour_max" -lt "$hour_min" ]]; then
        # Wraps around midnight
        if [[ "$hour" -ge "$hour_min" ]] || [[ "$hour" -lt "$hour_max" ]]; then
            in_window=true
        fi
    else
        # Normal range
        if [[ "$hour" -ge "$hour_min" ]] && [[ "$hour" -lt "$hour_max" ]]; then
            in_window=true
        fi
    fi

    if [[ "$in_window" == true ]]; then
        echo "$epoch"
        return
    fi

    # Adjust to start of window
    local new_hour=$hour_min
    local adjust_seconds=$(( (new_hour - hour) * 3600 - min * 60 - sec ))

    # If adjustment is negative and large, we need to go to next day's window
    if [[ "$adjust_seconds" -lt -43200 ]]; then  # More than 12 hours back
        adjust_seconds=$((adjust_seconds + 86400))
    elif [[ "$adjust_seconds" -gt 43200 ]]; then  # More than 12 hours forward
        adjust_seconds=$((adjust_seconds - 86400))
    fi

    # Add some randomness within the first hour of the window
    local random_offset=$(_ts_random_range 0 3599)
    echo $(( epoch + adjust_seconds + random_offset ))
}

# Apply preset to generate next timestamp
# Args: preset_name, base_epoch, [commit_index] (for progress info)
# Output: new epoch timestamp
_ts_apply_preset() {
    local preset="$1"
    local base_epoch="$2"
    local _index="${3:-0}"  # Unused but available for future features

    # Get preset config
    local config="${_TS_PRESETS[$preset]:-}"
    if [[ -z "$config" ]]; then
        warn "Unknown preset: $preset (using 'irl')"
        config="${_TS_PRESETS[irl]}"
    fi

    # Parse config into variables
    local gap_min=900 gap_max=7200 hour_min="" hour_max=""
    eval "$config"

    # Calculate random gap
    local gap=$(_ts_random_range "$gap_min" "$gap_max")
    local new_epoch=$((base_epoch + gap))

    # Apply hour window if specified
    if [[ -n "$hour_min" ]] && [[ -n "$hour_max" ]]; then
        new_epoch=$(_ts_clamp_to_hours "$new_epoch" "$hour_min" "$hour_max")
    fi

    # Randomize seconds for natural look
    new_epoch=$(_ts_randomize_seconds "$new_epoch")

    echo "$new_epoch"
}

# =============================================================================
# Batch Operations
# =============================================================================

# Apply same offset to multiple epochs
# Args: offset_string, epoch1 epoch2 epoch3...
# Output: adjusted epochs (one per line)
_ts_batch_offset() {
    local offset_str="$1"
    shift

    local offset
    offset=$(_ts_parse_relative "$offset_str") || return 1

    for epoch in "$@"; do
        echo $((epoch + offset))
    done
}

# =============================================================================
# Validation
# =============================================================================

# Validate that timestamp is reasonable (not in far future/past)
# Args: epoch
# Returns: 0 if valid, 1 if suspicious
_ts_validate() {
    local epoch="$1"
    local now=$(_ts_now)

    # Warn if more than 1 year in past or future
    local one_year=31536000
    if [[ "$epoch" -lt $((now - one_year)) ]]; then
        return 1  # Too far in past
    elif [[ "$epoch" -gt $((now + one_year)) ]]; then
        return 1  # Too far in future
    fi
    return 0
}

# Format time difference for display
# Args: epoch
# Output: human-readable relative time (e.g., "2 hours ago", "in 30 minutes")
_ts_relative_display() {
    local epoch="$1"
    local now=$(_ts_now)
    local diff=$((now - epoch))
    local abs_diff=${diff#-}
    local suffix

    if [[ "$diff" -ge 0 ]]; then
        suffix="ago"
    else
        suffix="from now"
    fi

    if [[ "$abs_diff" -lt 60 ]]; then
        echo "${abs_diff} seconds $suffix"
    elif [[ "$abs_diff" -lt 3600 ]]; then
        echo "$(( abs_diff / 60 )) minutes $suffix"
    elif [[ "$abs_diff" -lt 86400 ]]; then
        echo "$(( abs_diff / 3600 )) hours $suffix"
    elif [[ "$abs_diff" -lt 604800 ]]; then
        echo "$(( abs_diff / 86400 )) days $suffix"
    else
        echo "$(( abs_diff / 604800 )) weeks $suffix"
    fi
}
