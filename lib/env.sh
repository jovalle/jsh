#!/usr/bin/env bash
# Detect the host, running shell, terminal policy, and available UI backend.

unset JSH_INTERACTIVE_OVERRIDE JSH_UI_BACKEND_REQUEST

jsh_env_detect() {
  local requested_backend platform_name architecture shell_version max_tier package_gum

  if [[ -z ${JSH_INTERACTIVE_OVERRIDE+x} ]]; then
    if [[ -n ${JSH_INTERACTIVE+x} ]]; then
      JSH_INTERACTIVE_OVERRIDE=1
    else
      JSH_INTERACTIVE_OVERRIDE=0
    fi
  fi

  if [[ -n ${ZSH_VERSION:-} ]]; then
    JSH_SHELL=zsh
    shell_version=${ZSH_VERSION}
  elif [[ -n ${BASH_VERSION:-} ]]; then
    JSH_SHELL=bash
    shell_version=${BASH_VERSION}
  else
    JSH_SHELL='sh'
    shell_version=0.0
  fi
  JSH_SHELL_VERSION=${shell_version}
  JSH_SHELL_MAJOR=${shell_version%%.*}
  shell_version=${shell_version#*.}
  JSH_SHELL_MINOR=${shell_version%%.*}

  JSH_HAS_ASSOCIATIVE_ARRAYS=0
  JSH_HAS_PROCESS_SUBSTITUTION=0
  case ${JSH_SHELL} in
    zsh)
      JSH_HAS_ASSOCIATIVE_ARRAYS=1
      JSH_HAS_PROCESS_SUBSTITUTION=1
      ;;
    bash)
      ((JSH_SHELL_MAJOR >= 4)) && JSH_HAS_ASSOCIATIVE_ARRAYS=1
      JSH_HAS_PROCESS_SUBSTITUTION=1
      ;;
  esac

  platform_name=${JSH_UNAME:-$(uname -s)}
  case ${platform_name} in
    Darwin) JSH_PLATFORM=darwin ;;
    Linux) JSH_PLATFORM=linux ;;
    *) JSH_PLATFORM=unknown ;;
  esac

  architecture=${JSH_MACHINE:-$(uname -m)}
  case ${architecture} in
    amd64 | x86_64) JSH_ARCH=amd64 ;;
    aarch64 | arm64) JSH_ARCH=arm64 ;;
    *) JSH_ARCH=${architecture} ;;
  esac

  JSH_NON_INTERACTIVE=${JSH_NON_INTERACTIVE:-0}
  [[ ${JSH_ASSUME_YES:-0} != 1 ]] || JSH_NON_INTERACTIVE=1
  if [[ ${JSH_NON_INTERACTIVE} == 1 ]]; then
    JSH_INTERACTIVE=0
  elif [[ ${JSH_INTERACTIVE_OVERRIDE} != 1 ]]; then
    if [[ -t ${JSH_UI_INPUT_FD:-0} && -t ${JSH_UI_OUTPUT_FD:-2} && ${TERM:-} != dumb ]]; then
      JSH_INTERACTIVE=1
    else
      JSH_INTERACTIVE=0
    fi
  fi

  if [[ -z ${JSH_REMOTE+x} ]]; then
    if [[ -n ${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-} ]]; then
      JSH_REMOTE=1
    else
      JSH_REMOTE=0
    fi
  fi

  JSH_DATA_HOME=${JSH_DATA_HOME:-${XDG_DATA_HOME:-${HOME}/.local/share}/jsh}
  package_gum=$(command -v gum 2> /dev/null || true)
  if [[ -n ${JSH_GUM_VERSION:-} ]]; then
    case ${JSH_GUM:-} in
      '' | "${JSH_DATA_HOME}"/tools/gum/*/"${JSH_PLATFORM}-${JSH_ARCH}"/gum)
        JSH_GUM=${JSH_DATA_HOME}/tools/gum/${JSH_GUM_VERSION#v}/${JSH_PLATFORM}-${JSH_ARCH}/gum
        ;;
    esac
  elif [[ -n ${package_gum} ]]; then
    case ${JSH_GUM:-} in
      '' | "${JSH_DATA_HOME}"/tools/gum/*/"${JSH_PLATFORM}-${JSH_ARCH}"/gum)
        JSH_GUM=${package_gum}
        ;;
    esac
  elif [[ -z ${JSH_GUM+x} ]]; then
    JSH_GUM=
  fi

  requested_backend=${JSH_UI_BACKEND_REQUEST:-${JSH_UI_BACKEND:-auto}}
  JSH_UI_BACKEND_REQUEST=${requested_backend}
  case ${requested_backend} in
    plain)
      JSH_TIER=0
      JSH_UI_BACKEND=plain
      ;;
    shell)
      JSH_TIER=1
      JSH_UI_BACKEND=shell
      ;;
    gum)
      if [[ -x ${JSH_GUM} && ${JSH_INTERACTIVE} == 1 && ${JSH_REMOTE} != 1 ]]; then
        JSH_TIER=2
        JSH_UI_BACKEND=gum
      elif [[ ${JSH_INTERACTIVE} == 1 ]]; then
        JSH_TIER=1
        JSH_UI_BACKEND=shell
      else
        JSH_TIER=0
        JSH_UI_BACKEND=plain
      fi
      ;;
    auto | '')
      if [[ ${JSH_PLAIN_OUTPUT:-0} == 1 || ${JSH_INTERACTIVE} != 1 ]]; then
        JSH_TIER=0
        JSH_UI_BACKEND=plain
      elif [[ ${JSH_REMOTE} != 1 && -x ${JSH_GUM} ]]; then
        JSH_TIER=2
        JSH_UI_BACKEND=gum
      elif [[ ${JSH_SHELL} == zsh ]] ||
        [[ ${JSH_SHELL} == bash && ${JSH_SHELL_MAJOR} -gt 5 ]] ||
        [[ ${JSH_SHELL} == bash && ${JSH_SHELL_MAJOR} -eq 5 && ${JSH_SHELL_MINOR} -ge 1 ]]; then
        JSH_TIER=1
        JSH_UI_BACKEND=shell
      else
        JSH_TIER=0
        JSH_UI_BACKEND=plain
      fi
      ;;
    *) return 2 ;;
  esac

  max_tier=${JSH_UI_MAX_TIER:-2}
  case ${max_tier} in 0 | 1 | 2) ;; *) return 2 ;; esac
  if ((JSH_TIER > max_tier)); then
    JSH_TIER=${max_tier}
    case ${JSH_TIER} in
      0) JSH_UI_BACKEND=plain ;;
      1) JSH_UI_BACKEND=shell ;;
    esac
  fi
  if [[ ${JSH_NON_INTERACTIVE} == 1 ]]; then
    JSH_INTERACTIVE=0
    JSH_TIER=0
    JSH_UI_BACKEND=plain
  fi

  export JSH_SHELL JSH_SHELL_VERSION JSH_SHELL_MAJOR JSH_SHELL_MINOR
  export JSH_HAS_ASSOCIATIVE_ARRAYS JSH_HAS_PROCESS_SUBSTITUTION
  export JSH_PLATFORM JSH_ARCH JSH_NON_INTERACTIVE JSH_INTERACTIVE JSH_REMOTE
  export JSH_GUM_VERSION JSH_DATA_HOME JSH_GUM JSH_TIER JSH_UI_BACKEND
  typeset +x JSH_INTERACTIVE_OVERRIDE JSH_UI_BACKEND_REQUEST
}

jsh_env_detect
