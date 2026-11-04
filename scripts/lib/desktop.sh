#!/usr/bin/env bash
# Shared native desktop settings and shortcut helpers.

: "${JSH_HOST:=$(hostname -s)}"
if [[ -z ${JSH_DESKTOP:-} ]]; then
  if [[ $(uname -s) == Darwin ]]; then
    JSH_DESKTOP=darwin
  else
    case ${XDG_CURRENT_DESKTOP:-}:${DESKTOP_SESSION:-} in
      *[Xx][Ff][Cc][Ee]*) JSH_DESKTOP=xfce ;;
      *[Gg][Nn][Oo][Mm][Ee]*) JSH_DESKTOP=gnome ;;
      *) JSH_DESKTOP= ;;
    esac
  fi
fi

# Short labels for desktop entries in change reports; configuration keeps full paths.
jsh::desktop_names() {
  local entry name result='' separator=''
  while IFS= read -r entry; do
    [[ -n ${entry} ]] || continue
    name=${entry##*/}
    name=${name%.desktop}
    case ${name} in
      com.mitchellh.ghostty) name=Ghostty ;;
      xfce4-terminal*) name='XFCE Terminal' ;;
      waterfox | net.waterfox.waterfox) name=Waterfox ;;
      helium) name=Helium ;;
      code | visual-studio-code | com.visualstudio.code | code-oss) name='VS Code' ;;
      com.spotify.Client) name=Spotify ;;
      com.todoist.Todoist) name=Todoist ;;
    esac
    result+="${separator}${name}"
    separator=', '
  done < <(tr ';' '\n' <<<"$1")
  printf '%s\n' "${result:-(empty)}"
}

jsh::gsetting() {
  local schema=$1 key=$2 value=$3 directory=${4:-} current normalized
  jsh::activity "Checking GNOME setting ${schema} ${key}"
  local -a settings_command=(gsettings)
  [[ -z ${directory} ]] || settings_command+=(--schemadir "${directory}")
  current=$("${settings_command[@]}" get "${schema}" "${key}") || return
  # GVariant accepts JSON double-quoted strings and arrays, but prints single quotes.
  normalized=${current#@as }
  normalized=${normalized//\'/\"}
  if [[ ${current} == "${value}" ]] ||
    jq -e -n --argjson before "${normalized}" --argjson after "${value}" '$before == $after' >/dev/null 2>&1; then
    jsh::current
  else
    jsh::run "${settings_command[@]}" set "${schema}" "${key}" "${value}"
    jsh::changed "${schema} ${key}"
  fi
}

jsh::xfsetting() {
  local channel=$1 key=$2 value=$3 current
  jsh::activity "Checking XFCE setting ${channel} ${key}"
  local -a args=(xfconf-query -c "${channel}" -p "${key}" -s "${value}")
  if current=$(xfconf-query -c "${channel}" -p "${key}" 2>/dev/null); then
    if [[ ${current} == "${value}" ]]; then
      jsh::current
      return
    fi
  else
    args+=(--create --type string)
  fi
  jsh::run "${args[@]}"
  jsh::changed "${channel} ${key}"
}

jsh::gnome_list() {
  local raw
  raw=$(gsettings get "$1" "$2") || return
  # These lists contain extension IDs and settings paths, never arbitrary display text.
  printf '%s\n' "${raw#@as }" | tr "'" '"' | jq -ce 'if type=="array" then . else error("expected array") end'
}

jsh::shortcut() {
  local name=$1 gnome=$2 xfce=$3 shortcut_command=$4 slug path schema paths key value
  if [[ ${JSH_DESKTOP} == xfce ]]; then
    jsh::xfsetting xfce4-keyboard-shortcuts "/commands/custom/${xfce}" "${shortcut_command}"
  elif [[ ${JSH_DESKTOP} == gnome ]]; then
    slug=$(printf '%s' "${name}" | tr '[:upper:] ' '[:lower:]-')
    path=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/${slug}/
    schema=org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${path}
    for key in name binding command; do
      case ${key} in name) value=${name} ;; binding) value=${gnome} ;; command) value=${shortcut_command} ;; esac
      jsh::gsetting "${schema}" "${key}" "$(jq -Rn --arg text "${value}" '$text')"
    done
    paths=$(jsh::gnome_list org.gnome.settings-daemon.plugins.media-keys custom-keybindings)
    if ! jq -e --arg path "${path}" 'index($path)' <<<"${paths}" >/dev/null; then
      jsh::gsetting org.gnome.settings-daemon.plugins.media-keys custom-keybindings \
        "$(jq -c --arg path "${path}" '. + [$path]' <<<"${paths}")"
    fi
  fi
}

jsh::system_file() {
  local source=$1 destination=$2 backup
  jsh::activity "Checking system file ${destination}"
  export JSH_FILE_CHANGED=0
  if cmp -s -- "${source}" "${destination}"; then
    jsh::current
    return
  fi
  if [[ ${JSH_DRY_RUN:-0} != 1 ]] && ! jsh::admin; then
    jsh::notice "${destination} needs sudo; run sudo -v first, then rerun"
    return 0
  fi
  if [[ -e ${destination} ]]; then
    backup=${destination}.$(date +%Y%m%d-%H%M%S)-$$.bak
    jsh::root cp -p -- "${destination}" "${backup}"
  fi
  jsh::root install -d -m 0755 -- "${destination%/*}"
  jsh::root install -m 0644 -- "${source}" "${destination}"
  export JSH_FILE_CHANGED=1
  jsh::changed "${destination}"
}
