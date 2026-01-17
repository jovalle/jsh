# profiler.sh - Shell startup profiler for jsh
# Activate with JSH_PROFILE=1 for millisecond-precision timing
# Zero overhead when disabled (no-op stubs)
# shellcheck disable=SC2034

# Load guard
[[ -n "${_JSH_PROFILER_LOADED:-}" ]] && return 0
_JSH_PROFILER_LOADED=1

# =============================================================================
# Configuration
# =============================================================================

JSH_PROFILE="${JSH_PROFILE:-0}"
JSH_PROFILE_FORMAT="${JSH_PROFILE_FORMAT:-table}"  # table or json

# =============================================================================
# No-op Stubs (zero overhead when profiling disabled)
# =============================================================================

if [[ "${JSH_PROFILE}" != "1" ]]; then
    # Define no-op functions for zero overhead
    _profile_start() { :; }
    _profile_end() { :; }
    _profile_section() { :; }
    _profile_mark() { :; }
    _profile_report() { :; }
    return 0
fi

# =============================================================================
# Profiler Implementation (only loaded when JSH_PROFILE=1)
# =============================================================================

# Storage for timing data
declare -a _PROFILE_NAMES=()
declare -a _PROFILE_STARTS=()
declare -a _PROFILE_ENDS=()
declare -a _PROFILE_MARKS=()

_PROFILE_INIT_TIME=""

# Get current time in milliseconds with high precision
_profile_now() {
    # Prefer EPOCHREALTIME (bash 5+, zsh) for sub-millisecond precision
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        # EPOCHREALTIME is seconds.microseconds, convert to milliseconds
        # Use awk for floating point math (portable across bash/zsh)
        awk "BEGIN {printf \"%.3f\", ${EPOCHREALTIME} * 1000}"
    elif command -v gdate >/dev/null 2>&1; then
        # GNU date with nanoseconds
        gdate +%s%3N
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        # macOS: use perl for high precision
        perl -MTime::HiRes=time -e 'printf "%.3f\n", time * 1000' 2>/dev/null || date +%s000
    else
        # Fallback: second precision
        date +%s000
    fi
}

# Initialize profiler (call at very start of init.sh)
_profile_init() {
    _PROFILE_INIT_TIME=$(_profile_now)
}

# Start timing a section
_profile_start() {
    local name="$1"
    local now
    now=$(_profile_now)
    _PROFILE_NAMES+=("${name}")
    _PROFILE_STARTS+=("${now}")
    _PROFILE_ENDS+=("")  # Placeholder
}

# End timing a section
_profile_end() {
    local name="$1"
    local now
    now=$(_profile_now)

    # Find the section and record end time
    local i
    for i in "${!_PROFILE_NAMES[@]}"; do
        if [[ "${_PROFILE_NAMES[i]}" == "${name}" ]] && [[ -z "${_PROFILE_ENDS[i]}" ]]; then
            _PROFILE_ENDS[i]="${now}"
            return 0
        fi
    done
}

# Combined start/end for a single operation
# Usage: _profile_section "name" command args...
_profile_section() {
    local name="$1"
    shift
    _profile_start "${name}"
    "$@"
    local result=$?
    _profile_end "${name}"
    return $result
}

# Add a simple timestamp mark (for milestones)
_profile_mark() {
    local name="$1"
    local now
    now=$(_profile_now)
    _PROFILE_MARKS+=("${name}:${now}")
}

# =============================================================================
# Report Generation
# =============================================================================

_profile_report() {
    local format="${1:-${JSH_PROFILE_FORMAT}}"
    local total_time

    if [[ -n "${_PROFILE_INIT_TIME}" ]]; then
        local end_time
        end_time=$(_profile_now)
        total_time=$(awk "BEGIN {printf \"%.1f\", ${end_time} - ${_PROFILE_INIT_TIME}}")
    else
        total_time="?"
    fi

    case "${format}" in
        json)
            _profile_report_json "${total_time}"
            ;;
        *)
            _profile_report_table "${total_time}"
            ;;
    esac
}

_profile_report_table() {
    local total_time="$1"

    echo ""
    echo "┌─────────────────────────────────────────────────────────────┐"
    echo "│                    jsh Startup Profile                      │"
    echo "├─────────────────────────────────────────────────────────────┤"
    printf "│ %-35s %20s │\n" "Total startup time:" "${total_time}ms"
    echo "├─────────────────────────────────────────────────────────────┤"
    printf "│ %-35s %10s %8s │\n" "Section" "Duration" "%"
    echo "├─────────────────────────────────────────────────────────────┤"

    local i duration pct
    for i in "${!_PROFILE_NAMES[@]}"; do
        local name="${_PROFILE_NAMES[$i]}"
        local start="${_PROFILE_STARTS[$i]}"
        local end="${_PROFILE_ENDS[$i]}"

        if [[ -n "${end}" ]]; then
            duration=$(awk "BEGIN {printf \"%.1f\", ${end} - ${start}}")
            if [[ "${total_time}" != "?" ]] && [[ "${total_time}" != "0" ]]; then
                pct=$(awk "BEGIN {printf \"%.1f\", (${duration} / ${total_time}) * 100}")
            else
                pct="?"
            fi
            printf "│ %-35s %8sms %7s%% │\n" "${name}" "${duration}" "${pct}"
        fi
    done

    # Print marks
    if [[ ${#_PROFILE_MARKS[@]} -gt 0 ]]; then
        echo "├─────────────────────────────────────────────────────────────┤"
        printf "│ %-35s %20s │\n" "Marks" "Offset"
        echo "├─────────────────────────────────────────────────────────────┤"
        for mark in "${_PROFILE_MARKS[@]}"; do
            local mark_name="${mark%%:*}"
            local mark_time="${mark#*:}"
            local offset
            if [[ -n "${_PROFILE_INIT_TIME}" ]]; then
                offset=$(awk "BEGIN {printf \"%.1f\", ${mark_time} - ${_PROFILE_INIT_TIME}}")
            else
                offset="?"
            fi
            printf "│ %-35s %18sms │\n" "${mark_name}" "${offset}"
        done
    fi

    echo "└─────────────────────────────────────────────────────────────┘"
    echo ""
}

_profile_report_json() {
    local total_time="$1"

    echo "{"
    echo "  \"total_ms\": ${total_time},"
    echo "  \"sections\": ["

    local i duration first=true
    for i in "${!_PROFILE_NAMES[@]}"; do
        local name="${_PROFILE_NAMES[$i]}"
        local start="${_PROFILE_STARTS[$i]}"
        local end="${_PROFILE_ENDS[$i]}"

        if [[ -n "${end}" ]]; then
            duration=$(awk "BEGIN {printf \"%.3f\", ${end} - ${start}}")
            [[ "${first}" != "true" ]] && echo ","
            printf "    {\"name\": \"%s\", \"duration_ms\": %s}" "${name}" "${duration}"
            first=false
        fi
    done

    echo ""
    echo "  ],"
    echo "  \"marks\": ["

    first=true
    for mark in "${_PROFILE_MARKS[@]}"; do
        local mark_name="${mark%%:*}"
        local mark_time="${mark#*:}"
        local offset
        if [[ -n "${_PROFILE_INIT_TIME}" ]]; then
            offset=$(awk "BEGIN {printf \"%.3f\", ${mark_time} - ${_PROFILE_INIT_TIME}}")
        else
            offset="0"
        fi
        [[ "${first}" != "true" ]] && echo ","
        printf "    {\"name\": \"%s\", \"offset_ms\": %s}" "${mark_name}" "${offset}"
        first=false
    done

    echo ""
    echo "  ]"
    echo "}"
}

# =============================================================================
# Initialize on load
# =============================================================================

# Start profiling immediately when this file is sourced
_profile_init
