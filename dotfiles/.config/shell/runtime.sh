_jsh_tmux_has_config_arg() {
  local arg skip_next=0

  for arg in "$@"; do
    if ((skip_next)); then
      skip_next=0
      continue
    fi
    case "${arg}" in
      --) return 1 ;;
      -?*)
        case "${arg}" in
          -*f*) return 0 ;;
          -c | -L | -S | -T) skip_next=1 ;;
        esac
        ;;
      *) return 1 ;;
    esac
  done
  return 1
}

if command -v tmux >/dev/null 2>&1; then
  tmux() {
    local config

    if [[ -z ${JSH_TMUX_CONFIG+x} ]]; then
      config="${JSH_DIR}/dotfiles/.tmux.conf"
    else
      config="${JSH_TMUX_CONFIG}"
    fi
    if [[ -z ${config} ]] || _jsh_tmux_has_config_arg "$@"; then
      command tmux "$@"
    else
      command tmux -f "${config}" "$@"
    fi
  }
fi

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck() {
    local arg config_home

    for arg in "$@"; do
      case "${arg}" in
        --norc | --rcfile | --rcfile=*)
          command shellcheck "$@"
          return
          ;;
      esac
    done
    config_home="${XDG_CONFIG_HOME:-${HOME}/.config}"
    if [[ -z ${JSH_RUNTIME_CONFIG_DIR:-} ||
      -r ${config_home}/shellcheckrc || -r ${config_home}/.shellcheckrc ]]; then
      command shellcheck "$@"
    else
      XDG_CONFIG_HOME="${JSH_RUNTIME_CONFIG_DIR}" command shellcheck "$@"
    fi
  }
fi
