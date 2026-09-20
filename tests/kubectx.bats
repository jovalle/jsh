#!/usr/bin/env bats

: "${BATS_TEST_DIRNAME:=.}"
: "${BATS_TEST_TMPDIR:=${TMPDIR:-./tmp}}"

setup() {
  export JSH_ROOT
  JSH_ROOT=$(cd -- "${BATS_TEST_DIRNAME}/.." && pwd -P)
}

@test "context deletion selects and confirms through the shared Gum UI" {
  local commands="${BATS_TEST_TMPDIR}/commands" calls="${BATS_TEST_TMPDIR}/calls"
  mkdir -p "${commands}"
  cat > "${commands}/gum" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${CALLS}"
case $1 in
  choose) printf '%s\n' beta ;;
  confirm) exit 1 ;;
esac
EOF
  cat > "${commands}/kubectl" <<'EOF'
#!/bin/sh
if [ "$1 $2" = 'config get-contexts' ]; then
  printf '%s\n' alpha beta
  exit 0
fi
exit 1
EOF
  chmod +x "${commands}/gum" "${commands}/kubectl"

  run env PATH="${commands}:${PATH}" CALLS="${calls}" KUBECTL="${commands}/kubectl" \
    JSH_INTERACTIVE=1 JSH_REMOTE=0 JSH_UI_BACKEND=gum JSH_GUM="${commands}/gum" \
    "${JSH_ROOT}/bin/kubectx" --delete

  [[ ${status} -eq 0 ]]
  [[ ${output} == *'beta'* ]]
  [[ ${output} == *'Deletion cancelled.'* ]]
  grep -Fq 'choose --header     Contexts to delete --no-limit --ordered' "${calls}"
  grep -Fqx 'confirm --default=false Are you sure you want to delete these contexts?' "${calls}"
}
