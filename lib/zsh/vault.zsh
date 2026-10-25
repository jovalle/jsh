# Save a secret to 1Password and print its op:// reference: vault NAME, or pbpaste | vault NAME.
vault() {
  local name=$1 store=${JSH_VAULT:-Cyber} secret ids item
  local -a matches
  setopt local_options pipefail
  if [[ $# -ne 1 || -z ${name} || ${name} == */* ]]; then
    print -u2 'usage: vault NAME  (or: pbpaste | vault NAME)'
    return 64
  fi
  if ! has op || ! has jq; then
    jsh::log_error 'vault requires the 1Password CLI (op) and jq.'
    return 1
  fi

  if [[ -t 0 ]]; then
    read -rs "secret?Secret for ${name}: " || { print -u2; return 1; }
    print -u2
  else
    secret=$(command cat)
  fi
  if [[ -z ${secret} ]]; then
    jsh::log_error 'Nothing to vault.'
    return 1
  fi

  ids=$(op item list --vault "${store}" --format json |
    jq -r --arg title "${name}" '.[] | select(.title == $title) | .id') || {
    unset secret
    jsh::log_error "Cannot list the ${store} vault."
    return 1
  }
  matches=(${(f)ids})

  # Values travel through pipes and /dev/fd, never argv, so ps and history never see them.
  case ${#matches} in
    0)
      jq -n --arg title "${name}" --rawfile value <(print -rn -- "${secret}") \
        '{title: $title, category: "API_CREDENTIAL",
          fields: [{id: "credential", type: "CONCEALED", value: $value}]}' |
        op item create --vault "${store}" - >/dev/null
      ;;
    1)
      item=$(op item get "${matches[1]}" --vault "${store}" --format json) &&
        print -r -- "${item}" | jq -e --rawfile value <(print -rn -- "${secret}") \
          'if any(.fields[]; .id == "credential")
           then (.fields[] | select(.id == "credential")).value = $value
           else error("\(.title) has no credential field") end' |
        op item edit "${matches[1]}" --vault "${store}" >/dev/null
      ;;
    *)
      unset secret
      jsh::log_error "${store} has ${#matches} items named ${name}; rename one first."
      return 1
      ;;
  esac || {
    unset secret item
    jsh::log_error "Cannot save ${name} to ${store}."
    return 1
  }
  unset secret item
  print -r -- "op://${store}/${name}/credential"
}
