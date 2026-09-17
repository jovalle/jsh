#!/usr/bin/env bash
# Inspect and install verified Debian package artifacts for component scripts.

jsh_debian_installed_version() {
  local package_name=$1 installed
  installed=$(dpkg-query -W -f='${db:Status-Status}\t${Version}' "${package_name}" 2>/dev/null) || return 1
  [[ ${installed%%$'\t'*} == installed ]] || return 1
  printf '%s\n' "${installed#*$'\t'}"
}

jsh_debian_install_package() {
  local id=$1 package_name=$2 version=$3 url=$4 expected=$5
  shift 5
  local installed artifact field actual process answer running=0 attempt

  installed=$(jsh_debian_installed_version "${package_name}" || true)
  if [[ -n ${installed} ]] && dpkg --compare-versions "${installed}" ge "${version}"; then
    jsh_note "${id} is current (${installed})."
    return
  fi
  if [[ ${JSH_CONFIGURE_DRY_RUN:-0} == 1 || ${JSH_INSTALL_DRY_RUN:-0} == 1 ]]; then
    jsh_detail "Would install ${id} ${version}."
    return
  fi

  for process in "$@"; do
    if pgrep -x "${process}" >/dev/null 2>&1; then
      running=1
      break
    fi
  done
  if ((running)); then
    if [[ ${JSH_ASSUME_YES:-0} != 1 ]]; then
      if [[ ! -t 0 ]]; then
        jsh_warn "Skipping update for running app: ${id} (noninteractive)."
        return
      fi
      jsh_prompt "Close ${id} before updating? [y/N]: "
      read -r answer || answer=
      if [[ ${answer,,} != y && ${answer,,} != yes ]]; then
        jsh_note "Skipped update for ${id}."
        return
      fi
    fi
    for process in "$@"; do
      pkill -TERM -x "${process}" >/dev/null 2>&1 || true
    done
    for ((attempt = 0; attempt < 30; attempt++)); do
      running=0
      for process in "$@"; do
        pgrep -x "${process}" >/dev/null 2>&1 && running=1 && break
      done
      ((running)) || break
      sleep 0.1
    done
    ((running == 0)) || {
      jsh_error "${id} did not stop; package update cancelled."
      return 1
    }
  fi
  artifact=$(jsh_download_artifact "${id}" "${version}" "${url}" .deb "${expected}")
  for field in Package Architecture Version; do
    actual=$(dpkg-deb -f "${artifact}" "${field}")
    case ${field} in
      Package) [[ ${actual} == "${package_name}" ]] ;;
      Architecture) [[ ${actual} == amd64 ]] ;;
      Version) [[ ${actual} == "${version}" ]] ;;
    esac || {
      jsh_error "Unexpected ${id} package ${field}: ${actual}"
      return 1
    }
  done
  jsh_run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -- "${artifact}"
  installed=$(jsh_debian_installed_version "${package_name}" || true)
  [[ -n ${installed} ]] && dpkg --compare-versions "${installed}" ge "${version}" || {
    jsh_error "${id} package verification failed."
    return 1
  }
  jsh_success "Installed ${id} ${installed}."
}
