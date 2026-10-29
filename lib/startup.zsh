# Interactive shell start: load Git profile SSH keys and run local/init.d scripts.

# Loads each conf/git.json profile ssh_key into the agent unless it is already loaded.
_jsh_load_keys() {
  local config=${JSH}/conf/git.json key public fingerprint loaded
  local -a keys ssh_add=(ssh-add) added failed
  [[ -r ${config} ]] || return 0
  keys=("${(@f)$(command python3 -c '
import json, sys
for profile in json.load(open(sys.argv[1], encoding="utf-8")).get("profiles", {}).values():
    if profile.get("ssh_key"):
        print(profile["ssh_key"])
' "${config}" 2>/dev/null)}")
  keys=(${(u)keys:#})
  (( ${#keys} )) || return 0
  loaded=$(command ssh-add -l 2>/dev/null)
  (( $? != 2 )) || return 0
  [[ ${OSTYPE} != darwin* || ! -x /usr/bin/ssh-add ]] ||
    ssh_add=(/usr/bin/ssh-add --apple-use-keychain)
  for key in "${keys[@]}"; do
    key=${key/#\~\//${HOME}/}
    [[ ${key} == */* ]] || key=${HOME}/.ssh/${key}
    if [[ ! -r ${key} ]]; then
      failed+=("${key:t} (missing)")
      continue
    fi
    public=${key}.pub
    [[ -r ${public} ]] || public=${key}
    fingerprint=${${(z)$(command ssh-keygen -lf "${public}" 2>/dev/null)}[2]}
    [[ -n ${fingerprint} && ${loaded} == *" ${fingerprint} "* ]] && continue
    if command "${ssh_add[@]}" -q "${key}"; then
      added+=("${key:t}")
    else
      failed+=("${key:t}")
    fi
  done
  (( ! ${#added} )) || jsh::log_success "ssh: added ${(j:, :)added}"
  (( ! ${#failed} )) || jsh::log_warn "ssh: could not load ${(j:, :)failed}"
}

# Runs each executable in JSH_INIT in name order, reporting only failures.
_jsh_run_init() {
  local script
  for script in "${JSH_INIT:-${JSH}/local/init.d}"/*(N.x); do
    "${script}" || jsh::log_error "init: ${script:t} failed"
  done
}
