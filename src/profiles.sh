# profiles.sh - Git profile management helpers
#
# Provides helper functions for managing git user profiles.
# Profiles are defined in config/profiles.json and can be applied
# to git repositories to set user.name and user.email.
#
# Profile detection works by matching the repo's user.email against
# configured profiles.

# shellcheck disable=SC2034

# =============================================================================
# Configuration
# =============================================================================

_PROFILES_CONFIG="${JSH_DIR:-${HOME}/.jsh}/local/profiles.json"

# =============================================================================
# Helper Functions
# =============================================================================

# Get profile data by name
# Arguments:
#   $1 - Profile name
# Output: JSON object with name, email, username
_profiles_get() {
  local name="$1"

  [[ -f "$_PROFILES_CONFIG" ]] || return 1
  command -v jq &>/dev/null || return 1

  jq -r --arg name "$name" '.profiles[$name] // empty' "$_PROFILES_CONFIG" 2>/dev/null
}

# List all profile names
# Output: Profile names, one per line
_profiles_list() {
  [[ -f "$_PROFILES_CONFIG" ]] || return 0
  command -v jq &>/dev/null || return 0

  jq -r '.profiles | keys[]' "$_PROFILES_CONFIG" 2>/dev/null
}

# Check if profile exists
# Arguments:
#   $1 - Profile name
# Returns: 0 if exists, 1 otherwise
_profiles_exists() {
  local name="$1"
  local result

  result="$(_profiles_get "$name")"
  [[ -n "$result" ]]
}

# Apply a profile to a git repository
# Arguments:
#   $1 - Profile name
#   $2 - Directory (optional, defaults to PWD)
# Returns: 0 on success, 1 on failure
_profiles_apply() {
  local profile_name="$1"
  local dir="${2:-.}"
  local profile_data name email username ssh_host host

  profile_data="$(_profiles_get "$profile_name")"
  if [[ -z "$profile_data" ]]; then
    printf '%s\n' "Profile not found: $profile_name" >&2
    return 1
  fi

  # Check if directory is a git repo
  if ! git -C "$dir" rev-parse --git-dir &>/dev/null; then
    printf '%s\n' "Not a git repository: $dir" >&2
    return 1
  fi

  name=$(printf '%s' "$profile_data" | jq -r '.name // empty')
  email=$(printf '%s' "$profile_data" | jq -r '.email // empty')
  username=$(printf '%s' "$profile_data" | jq -r '.user // empty')
  ssh_host=$(printf '%s' "$profile_data" | jq -r '.ssh_host // empty')
  host=$(printf '%s' "$profile_data" | jq -r '.host // empty')

  # Note: host and ssh_host are kept separate intentionally
  # - ssh_host: SSH alias from ~/.ssh/config (e.g., github-jovalle)
  # - host: actual hostname for HTTPS (e.g., github.com)
  # They should NOT be merged - SSH aliases don't work for HTTPS

  if [[ -n "$name" ]]; then
    git -C "$dir" config user.name "$name"
  fi

  if [[ -n "$email" ]]; then
    git -C "$dir" config user.email "$email"
  fi

  if [[ -n "$username" ]]; then
    git -C "$dir" config github.user "$username"
  fi

  # Store profile's ssh_host in git config for SSH checking
  if [[ -n "$ssh_host" ]]; then
    git -C "$dir" config jsh.ssh-host "$ssh_host"
  fi

  # Update origin remote to point to user's fork
  if [[ -n "$username" ]]; then
    local origin_url repo_name new_origin_url
    local url_host url_protocol target_host target_protocol
    local C_CYAN=$'\033[36m' C_YELLOW=$'\033[33m' C_DIM=$'\033[2m' C_RESET=$'\033[0m'
    origin_url=$(git -C "$dir" remote get-url origin 2>/dev/null)

    if [[ -n "$origin_url" ]]; then
      # Extract repo name (last path component without .git)
      repo_name="${origin_url##*/}"
      repo_name="${repo_name%.git}"

      # Detect protocol and extract host from existing URL
      if [[ "$origin_url" == https://* ]]; then
        # HTTPS: https://host/owner/repo.git
        url_protocol="https"
        url_host="${origin_url#https://}"
        url_host="${url_host%%/*}"
      elif [[ "$origin_url" == git@* ]]; then
        # SSH: git@host:owner/repo.git
        url_protocol="ssh"
        url_host="${origin_url#git@}"
        url_host="${url_host%%:*}"
      elif [[ "$origin_url" == ssh://* ]]; then
        # SSH alternate: ssh://git@host/owner/repo.git
        url_protocol="ssh-alt"
        url_host="${origin_url#ssh://git@}"
        url_host="${url_host%%/*}"
      else
        # Unknown format, skip origin update
        return 0
      fi

      # Determine target protocol based on profile config vs current URL
      target_protocol="$url_protocol"

      # Check for protocol mismatch and prompt user
      if [[ -n "$ssh_host" ]] && [[ "$url_protocol" == "https" ]]; then
        # Profile has ssh_host but remote is HTTPS - offer to convert to SSH
        printf '%b\n' "${C_YELLOW}Note:${C_RESET} Profile has ${C_CYAN}ssh_host${C_RESET} configured but remote uses HTTPS"
        printf '%b\n' "  Current: ${C_DIM}${origin_url}${C_RESET}"
        printf '%b\n' "  SSH would be: ${C_CYAN}git@${ssh_host}:${username}/${repo_name}.git${C_RESET}"
        printf '%s' "Convert to SSH? [y/N] "
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
          target_protocol="ssh"
        fi
      elif [[ -z "$ssh_host" ]] && [[ "$url_protocol" == "ssh" || "$url_protocol" == "ssh-alt" ]]; then
        # Profile has no ssh_host but remote is SSH - offer to convert to HTTPS
        printf '%b\n' "${C_YELLOW}Note:${C_RESET} Profile has no ${C_CYAN}ssh_host${C_RESET} configured but remote uses SSH"
        printf '%b\n' "  Current: ${C_DIM}${origin_url}${C_RESET}"
        printf '%b\n' "  HTTPS would be: ${C_CYAN}https://${host:-$url_host}/${username}/${repo_name}.git${C_RESET}"
        printf '%s' "Convert to HTTPS? [y/N] "
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
          target_protocol="https"
        fi
      fi

      # Determine target host based on final protocol
      case "$target_protocol" in
        https)
          # For HTTPS, only use explicit 'host' setting, never ssh_host
          target_host="${host:-$url_host}"
          ;;
        ssh|ssh-alt)
          # For SSH, prefer ssh_host (the alias), fallback to host, then original
          target_host="${ssh_host:-${host:-$url_host}}"
          ;;
      esac

      if [[ -n "$repo_name" ]]; then
        # Build new URL with appropriate host for protocol
        case "$target_protocol" in
          https)
            new_origin_url="https://${target_host}/${username}/${repo_name}.git"
            ;;
          ssh|ssh-alt)
            new_origin_url="git@${target_host}:${username}/${repo_name}.git"
            ;;
        esac

        git -C "$dir" remote set-url origin "$new_origin_url"
      fi
    fi
  fi

  return 0
}

# Get current git config for a directory
# Arguments:
#   $1 - Directory (optional, defaults to PWD)
# Output: "name|email" or empty if not a git repo
_profiles_get_current() {
  local dir="${1:-.}"
  local name email

  git -C "$dir" rev-parse --git-dir &>/dev/null || return 1

  name=$(git -C "$dir" config user.name 2>/dev/null)
  email=$(git -C "$dir" config user.email 2>/dev/null)

  printf '%s|%s\n' "$name" "$email"
}

# Detect which profile matches a git repo's config
# Matches by email address
# Arguments:
#   $1 - Directory (optional, defaults to PWD)
# Output: Profile name or empty if no match
_profiles_detect() {
  local dir="${1:-.}"
  local current_config current_email profile_name profile_data p_email

  current_config="$(_profiles_get_current "$dir")"
  [[ -z "$current_config" ]] && return 1

  current_email="${current_config#*|}"
  [[ -z "$current_email" ]] && return 1

  while IFS= read -r profile_name; do
    [[ -z "$profile_name" ]] && continue
    profile_data="$(_profiles_get "$profile_name")"
    p_email=$(printf '%s' "$profile_data" | jq -r '.email // empty')

    if [[ "$p_email" == "$current_email" ]]; then
      printf '%s\n' "$profile_name"
      return 0
    fi
  done < <(_profiles_list)

  return 1
}

# =============================================================================
# SSH Configuration Helpers
# =============================================================================

# Extract SSH host from a git remote URL
# Arguments:
#   $1 - Git remote URL
# Output: SSH host (e.g., "github.com" or "github-personal")
_profiles_extract_ssh_host() {
  local url="$1"

  case "$url" in
    git@*:*)
      # SSH format: git@host:user/repo.git
      local host="${url#git@}"
      printf '%s\n' "${host%%:*}"
      ;;
    ssh://git@*)
      # SSH alternate: ssh://git@host/user/repo.git
      local host="${url#ssh://git@}"
      printf '%s\n' "${host%%/*}"
      ;;
    *)
      # HTTPS or other - no SSH host
      return 1
      ;;
  esac
}

# Check SSH config for a specific host
# Arguments:
#   $1 - SSH host to check
# Output: IdentityFile path if configured, empty otherwise
_profiles_get_ssh_identity() {
  local host="$1"
  local ssh_config="${HOME}/.ssh/config"

  [[ -f "$ssh_config" ]] || return 1

  # Parse SSH config to find IdentityFile for this host
  # This is a simplified parser - handles common formats
  local in_host_block=false
  local identity_file=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Trim leading/trailing whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    # Skip comments and empty lines
    [[ -z "$line" || "$line" == \#* ]] && continue

    # Check for Host directive
    if [[ "$line" == Host\ * || "$line" == Host$'\t'* ]]; then
      local host_pattern="${line#Host}"
      host_pattern="${host_pattern#"${host_pattern%%[![:space:]]*}"}"

      # Check if this host block matches our target
      if [[ "$host_pattern" == "$host" || "$host_pattern" == *"$host"* ]]; then
        in_host_block=true
      else
        in_host_block=false
      fi
      continue
    fi

    # If in matching host block, look for IdentityFile
    if [[ "$in_host_block" == true ]]; then
      if [[ "$line" == IdentityFile\ * || "$line" == IdentityFile$'\t'* ]]; then
        identity_file="${line#IdentityFile}"
        identity_file="${identity_file#"${identity_file%%[![:space:]]*}"}"
        # Expand ~ to $HOME
        identity_file="${identity_file/#\~/$HOME}"
        printf '%s\n' "$identity_file"
        return 0
      fi
    fi
  done < "$ssh_config"

  return 1
}

# Check if SSH is properly configured for the current repo's profile
# Arguments:
#   $1 - Directory (optional, defaults to PWD)
# Output: Status message about SSH configuration
# Returns: 0 if OK, 1 if warning, 2 if not applicable
_profiles_check_ssh() {
  local dir="${1:-.}"
  local C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_RED=$'\033[31m' C_DIM=$'\033[2m' C_CYAN=$'\033[36m' C_RESET=$'\033[0m'

  # Get origin URL
  local origin_url
  origin_url=$(git -C "$dir" remote get-url origin 2>/dev/null)
  [[ -z "$origin_url" ]] && return 2

  # Extract SSH host from current URL
  local current_ssh_host
  current_ssh_host="$(_profiles_extract_ssh_host "$origin_url")"
  [[ -z "$current_ssh_host" ]] && return 2  # Not using SSH

  # Get expected SSH host from profile config (stored when profile was applied)
  local expected_ssh_host
  expected_ssh_host=$(git -C "$dir" config jsh.ssh-host 2>/dev/null)

  # Also check the detected profile's ssh_host setting
  local detected_profile profile_ssh_host
  detected_profile="$(_profiles_detect "$dir" 2>/dev/null)"
  if [[ -n "$detected_profile" ]]; then
    local profile_data
    profile_data="$(_profiles_get "$detected_profile")"
    if [[ -n "$profile_data" ]]; then
      profile_ssh_host=$(printf '%s' "$profile_data" | jq -r '.ssh_host // empty')
    fi
  fi

  # Use profile's ssh_host if jsh.ssh-host not set
  [[ -z "$expected_ssh_host" ]] && expected_ssh_host="$profile_ssh_host"

  # Check if using an SSH alias (not a real domain)
  local is_alias=false
  if [[ "$current_ssh_host" != *.* ]]; then
    is_alias=true
  fi

  # Get identity file from SSH config for current host
  local identity_file
  identity_file="$(_profiles_get_ssh_identity "$current_ssh_host")"

  # Check for mismatch between current and expected SSH host
  if [[ -n "$expected_ssh_host" ]] && [[ "$current_ssh_host" != "$expected_ssh_host" ]]; then
    printf '%b⚠ SSH host mismatch:%b\n' "$C_YELLOW" "$C_RESET"
    printf '%b  Current:  %s%b\n' "$C_RED" "$current_ssh_host" "$C_RESET"
    printf '%b  Expected: %s (from profile)%b\n' "$C_GREEN" "$expected_ssh_host" "$C_RESET"
    printf '%b  Run: project profile %s  to update remote URL%b\n' "$C_DIM" "${detected_profile:-<profile>}" "$C_RESET"
    return 1
  fi

  if [[ "$is_alias" == true ]]; then
    # Using SSH alias - good practice for multi-account setups
    if [[ -n "$identity_file" ]]; then
      if [[ -f "$identity_file" ]]; then
        printf '%b✓ SSH: %s → %s%b\n' "$C_GREEN" "$current_ssh_host" "$identity_file" "$C_RESET"
        return 0
      else
        printf '%b⚠ SSH key not found: %s%b\n' "$C_YELLOW" "$identity_file" "$C_RESET"
        return 1
      fi
    else
      printf '%b⚠ SSH alias "%s" not found in ~/.ssh/config%b\n' "$C_YELLOW" "$current_ssh_host" "$C_RESET"
      return 1
    fi
  else
    # Using direct hostname (e.g., github.com)
    # Check if there are multiple profiles - if so, warn about potential issues
    local profile_count
    profile_count=$(_profiles_list 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$profile_count" -gt 1 ]]; then
      # Check if the current profile has ssh_host configured
      if [[ -n "$profile_ssh_host" ]]; then
        printf '%b⚠ Profile has ssh_host "%s" but remote uses "%s"%b\n' "$C_YELLOW" "$profile_ssh_host" "$current_ssh_host" "$C_RESET"
        printf '%b  Run: project profile %s  to update remote URL%b\n' "$C_DIM" "$detected_profile" "$C_RESET"
        return 1
      elif [[ -n "$identity_file" ]]; then
        printf '%b✓ SSH key: %s%b\n' "$C_DIM" "$identity_file" "$C_RESET"
        return 0
      else
        printf '%b⚠ Using %s with %s profiles but no explicit SSH key%b\n' "$C_YELLOW" "$current_ssh_host" "$profile_count" "$C_RESET"
        printf '%b  Consider adding ssh_host to your profile config%b\n' "$C_DIM" "$C_RESET"
        printf '%b  Run: project profile docs%b\n' "$C_DIM" "$C_RESET"
        return 1
      fi
    else
      # Single profile - no warning needed
      if [[ -n "$identity_file" ]]; then
        printf '%bSSH: %s%b\n' "$C_DIM" "$identity_file" "$C_RESET"
      fi
      return 0
    fi
  fi
}

# =============================================================================
# Profile Subcommand Handlers
# =============================================================================

# Show current profile status
_profile_cmd_status() {
  local current_config detected_profile origin_url
  local C_CYAN=$'\033[36m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_DIM=$'\033[2m' C_RESET=$'\033[0m'

  if ! git rev-parse --git-dir &>/dev/null; then
    printf '%s\n' "Not in a git repository" >&2
    return 1
  fi

  current_config="$(_profiles_get_current)"
  detected_profile="$(_profiles_detect)"
  origin_url=$(git remote get-url origin 2>/dev/null)
  github_user=$(git config github.user 2>/dev/null)
  local jsh_ssh_host
  jsh_ssh_host=$(git config jsh.ssh-host 2>/dev/null)

  local current_name="${current_config%|*}"
  local current_email="${current_config#*|}"

  printf '%s\n' "Current git user:"
  if [[ -n "$current_name" ]]; then
    printf '  Name:   %s\n' "$current_name"
  else
    printf '  Name:   %b(not set)%b\n' "$C_DIM" "$C_RESET"
  fi
  if [[ -n "$current_email" ]]; then
    printf '  Email:  %s\n' "$current_email"
  else
    printf '  Email:  %b(not set)%b\n' "$C_DIM" "$C_RESET"
  fi
  if [[ -n "$origin_url" ]]; then
    printf '  Origin: %b%s%b\n' "$C_CYAN" "$origin_url" "$C_RESET"
  else
    printf '  Origin: %b(not set)%b\n' "$C_DIM" "$C_RESET"
  fi
  if [[ -n "$github_user" ]]; then
    printf '  GitHub: %b%s%b\n' "$C_CYAN" "$github_user" "$C_RESET"
  else
    printf '  GitHub: %b(not set)%b\n' "$C_DIM" "$C_RESET"
  fi

  printf '%s\n' ""
  if [[ -n "$detected_profile" ]]; then
    printf 'Profile: %b%s%b\n' "$C_GREEN" "$detected_profile" "$C_RESET"

    # Show profile's SSH host configuration
    local profile_data profile_ssh_host
    profile_data="$(_profiles_get "$detected_profile")"
    if [[ -n "$profile_data" ]]; then
      profile_ssh_host=$(printf '%s' "$profile_data" | jq -r '.ssh_host // empty')
      if [[ -n "$profile_ssh_host" ]]; then
        printf '  ssh_host: %b%s%b\n' "$C_CYAN" "$profile_ssh_host" "$C_RESET"
      fi
    fi
  else
    printf 'Profile: %b(none)%b\n' "$C_DIM" "$C_RESET"
  fi

  # Check SSH configuration for potential push issues
  printf '%s\n' ""
  local ssh_check_result
  _profiles_check_ssh
  ssh_check_result=$?

  # Only propagate actual warnings (1), not "not applicable" (2)
  if [[ $ssh_check_result -eq 1 ]]; then
    return 1
  fi
  return 0
}

# List all profiles
_profile_cmd_list() {
  local C_CYAN=$'\033[36m' C_GREEN=$'\033[32m' C_DIM=$'\033[2m' C_YELLOW=$'\033[33m' C_RESET=$'\033[0m'
  local profile_name profile_data name email ssh_host current_profile marker ssh_display

  if [[ ! -f "$_PROFILES_CONFIG" ]]; then
    printf '%s\n' "No profiles configured."
    printf '%s\n' "Create config at: $_PROFILES_CONFIG"
    return 0
  fi

  current_profile="$(_profiles_detect 2>/dev/null)"

  printf '%b%-12s %-25s %-20s %s%b\n' "$C_DIM" "PROFILE" "EMAIL" "SSH_HOST" "NAME" "$C_RESET"
  printf '%s\n' "$(printf '%80s' '' | tr ' ' '-')"

  while IFS= read -r profile_name; do
    [[ -z "$profile_name" ]] && continue
    profile_data="$(_profiles_get "$profile_name")"
    name=$(printf '%s' "$profile_data" | jq -r '.name // empty')
    email=$(printf '%s' "$profile_data" | jq -r '.email // empty')
    ssh_host=$(printf '%s' "$profile_data" | jq -r '.ssh_host // empty')

    marker=""
    if [[ "$profile_name" == "$current_profile" ]]; then
      marker="${C_GREEN}* ${C_RESET}"
    else
      marker="  "
    fi

    # Show ssh_host or indicate if not configured
    if [[ -n "$ssh_host" ]]; then
      ssh_display="${C_CYAN}${ssh_host}${C_RESET}"
    else
      ssh_display="${C_DIM}-${C_RESET}"
    fi

    printf '%s%b%-12s%b %-25s %-20b %s\n' "$marker" "$C_CYAN" "$profile_name" "$C_RESET" "$email" "$ssh_display" "$name"
  done < <(_profiles_list)
}

# Apply a profile to the current repo
_profile_cmd_apply() {
  local profile_name="$1"
  local C_GREEN=$'\033[32m' C_CYAN=$'\033[36m' C_RESET=$'\033[0m'

  if [[ -z "$profile_name" ]]; then
    printf '%s\n' "Usage: project profile <name>" >&2
    printf '%s\n' "" >&2
    printf '%s\n' "Available profiles:" >&2
    _profiles_list | while read -r p; do
      printf '%s\n' "  $p" >&2
    done
    return 1
  fi

  if ! git rev-parse --git-dir &>/dev/null; then
    printf '%s\n' "Not in a git repository" >&2
    return 1
  fi

  if _profiles_apply "$profile_name"; then
    printf '%b\n' "${C_GREEN}Applied profile:${C_RESET} ${C_CYAN}${profile_name}${C_RESET}"
    printf '%s\n' ""
    _profile_cmd_status
  fi
}

# Check all projects for their profile status
_profile_cmd_check() {
  local dir display_name detected_profile
  local C_CYAN=$'\033[36m' C_GREEN=$'\033[32m' C_DIM=$'\033[2m' C_RESET=$'\033[0m'

  printf '%b%-40s %s%b\n' "$C_DIM" "PROJECT" "PROFILE" "$C_RESET"
  printf '%s\n' "$(printf '%55s' '' | tr ' ' '-')"

  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    [[ ! -d "$dir/.git" ]] && continue

    display_name="$(_projects_display_name "$dir")"
    detected_profile="$(_profiles_detect "$dir")"

    if [[ -n "$detected_profile" ]]; then
      printf '%-40s %b%s%b\n' "$display_name" "$C_GREEN" "$detected_profile" "$C_RESET"
    else
      printf '%-40s %b-%b\n' "$display_name" "$C_DIM" "$C_RESET"
    fi
  done < <(_projects_get_all)
}

# Show SSH config documentation
_profile_cmd_docs() {
  cat << 'EOF'
# SSH Config for Git Profiles
# ===========================
#
# STEP 1: Configure SSH host aliases in ~/.ssh/config
# ---------------------------------------------------
#
# Example for personal profile (GitHub.com):
#
#   Host github-personal
#       HostName github.com
#       User git
#       IdentityFile ~/.ssh/id_personal
#       IdentitiesOnly yes
#
# Example for work profile (GitHub Enterprise):
#
#   Host github-work
#       HostName github.company.com
#       User git
#       IdentityFile ~/.ssh/id_work
#       IdentitiesOnly yes
#
# STEP 2: Add ssh_host to your profile config
# -------------------------------------------
#
# In ~/.jsh/local/profiles.json:
#
#   {
#     "profiles": {
#       "personal": {
#         "name": "Your Name",
#         "email": "personal@example.com",
#         "user": "yourusername",
#         "ssh_host": "github-personal"
#       },
#       "work": {
#         "name": "Your Name",
#         "email": "work@company.com",
#         "user": "workusername",
#         "ssh_host": "github-work",
#         "host": "github.company.com"
#       }
#     }
#   }
#
# Profile Schema:
#   name      - Git user.name
#   email     - Git user.email
#   user      - GitHub/GitLab username (updates origin URL)
#   ssh_host  - SSH host alias from ~/.ssh/config (for SSH remotes)
#   host      - Actual hostname for HTTPS (defaults to ssh_host)
#
# STEP 3: Apply profile to update remote URL
# ------------------------------------------
#
#   project profile personal
#
# This sets:
#   - git user.name and user.email
#   - Updates origin to: git@github-personal:yourusername/repo.git
#   - SSH will use the correct key automatically
#
# The `project profile` command will warn you if:
#   - The SSH host alias is not in ~/.ssh/config
#   - The remote URL doesn't match the profile's expected ssh_host
#   - You have multiple profiles but no ssh_host configured
EOF
}

# Show help for profile subcommand
_profile_cmd_help() {
  cat << EOF
Usage: project profile [command] [args]

Commands:
  (none)        Show current profile for this repo
  list          List all configured profiles
  <name>        Apply profile to current repo
  check         Check all projects and show profiles
  docs          Show SSH config documentation

Examples:
  project profile                # Show current profile
  project profile list           # List all profiles
  project profile work           # Apply work profile
  project profile check          # Check all projects

Config: $_PROFILES_CONFIG
EOF
}
