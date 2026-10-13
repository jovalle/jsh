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
  local installed artifact field actual process running=0 attempt apt_stage apt_artifact

  installed=$(jsh_debian_installed_version "${package_name}" || true)
  if [[ -n ${installed} ]] && dpkg --compare-versions "${installed}" ge "${version}"; then
    jsh::log_note "${id} is current (${installed})."
    return
  fi
  if [[ ${JSH_CONFIGURE_DRY_RUN:-0} == 1 || ${JSH_INSTALL_DRY_RUN:-0} == 1 ]]; then
    jsh::log_detail "Would install ${id} ${version}."
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
        jsh::log_warn "Skipping update for running app: ${id} (noninteractive)."
        return
      fi
      if ! JSH_NON_INTERACTIVE=0 JSH_INTERACTIVE=1 \
        jsh::confirm "Close ${id} before updating?" --default no; then
        jsh::log_note "Skipped update for ${id}."
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
      jsh::log_error "${id} did not stop; package update cancelled."
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
      jsh::log_error "Unexpected ${id} package ${field}: ${actual}"
      return 1
    }
  done
  # apt fetches local packages as _apt, which cannot traverse a private home directory.
  apt_stage=$(mktemp -d /tmp/jsh-apt.XXXXXXXXXX) || return 1
  declare -F jsh_interrupt_cleanup_path >/dev/null && jsh_interrupt_cleanup_path "${apt_stage}"
  apt_artifact=${apt_stage}/${id}.deb
  if ! chmod 0755 "${apt_stage}" || ! install -m 0644 -- "${artifact}" "${apt_artifact}"; then
    rm -rf -- "${apt_stage}"
    return 1
  fi
  if ! jsh_run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -- "${apt_artifact}"; then
    rm -rf -- "${apt_stage}"
    return 1
  fi
  rm -rf -- "${apt_stage}"
  installed=$(jsh_debian_installed_version "${package_name}" || true)
  [[ -n ${installed} ]] && dpkg --compare-versions "${installed}" ge "${version}" || {
    jsh::log_error "${id} package verification failed."
    return 1
  }
  jsh::log_success "Installed ${id} ${installed}."
}
