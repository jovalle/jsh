# Load environment variables from .env file if it exists
root_dir="${JSH_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
env_file="${root_dir}/.env"

if [[ -f "$env_file" ]]; then
  # Source the .env file to load BREW_USER and other environment variables
  # Only export variables that are defined in the file
  while IFS='=' read -r key value; do
    # Skip comments and empty lines
    [[ "$key" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$key" ]] && continue

    # Remove leading/trailing whitespace
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | xargs)

    # Export the variable
    export "$key=$value"
  done < "$env_file"
fi
