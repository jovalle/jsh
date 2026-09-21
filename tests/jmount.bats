#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

: "${BATS_TEST_DIRNAME:=.}"
: "${BATS_TEST_TMPDIR:=${TMPDIR:-./tmp}}"

setup() {
  export JSH_ROOT
  JSH_ROOT=$(cd -- "${BATS_TEST_DIRNAME}/.." && pwd -P)
  export HOME="${BATS_TEST_TMPDIR}/home"
  export JMOUNT_TEST_BIN="${BATS_TEST_TMPDIR}/bin"
  export JMOUNT_TEST_LOG="${BATS_TEST_TMPDIR}/jmount.log"
  export JMOUNT_TEST_MOUNTS_FILE="${BATS_TEST_TMPDIR}/mounts.log"
  export JMOUNT_MOUNT_ROOT="${BATS_TEST_TMPDIR}/mounts"
  export JMOUNT_SHELL="${JMOUNT_TEST_BIN}/shell"
  export JSH_COLOR=never
  export JSH_INTERACTIVE=1
  export JSH_UI_BACKEND=plain
  mkdir -p "${HOME}/.local" "${JMOUNT_TEST_BIN}" "${JMOUNT_MOUNT_ROOT}"

  cat > "${JMOUNT_TEST_BIN}/mount" <<'EOF'
#!/usr/bin/env bash
if (($# == 0)); then
  printf '%s\n' "${JMOUNT_TEST_MOUNTS:-}"
  [[ ! -f ${JMOUNT_TEST_MOUNTS_FILE} ]] || cat "${JMOUNT_TEST_MOUNTS_FILE}"
else
  printf 'mount:%s\n' "$*" >> "${JMOUNT_TEST_LOG}"
  case $* in
    *credentials=*)
      credentials=${*#*credentials=}
      credentials=${credentials%%,*}
      grep -Fxq 'username=jay' "${credentials}"
      grep -Fxq 'password=secret' "${credentials}"
      printf 'credentials:ok\n' >> "${JMOUNT_TEST_LOG}"
      ;;
  esac
fi
EOF

  cat > "${JMOUNT_TEST_BIN}/open" <<'EOF'
#!/usr/bin/env bash
printf 'open:%s\n' "$*" >> "${JMOUNT_TEST_LOG}"
mkdir -p -- "${JMOUNT_TEST_OPEN_TARGET}"
printf '%s on %s (smbfs)\n' "${JMOUNT_TEST_OPEN_SOURCE}" "${JMOUNT_TEST_OPEN_TARGET}" > "${JMOUNT_TEST_MOUNTS_FILE}"
EOF

  cat > "${JMOUNT_TEST_BIN}/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo:%s\n' "$*" >> "${JMOUNT_TEST_LOG}"
exec "$@"
EOF

  cat > "${JMOUNT_TEST_BIN}/mount_smbfs" <<'EOF'
#!/usr/bin/env bash
printf 'mount_smbfs:%s\n' "$*" >> "${JMOUNT_TEST_LOG}"
mkdir -p -- "$2"
EOF

  cat > "${JMOUNT_TEST_BIN}/mount_nfs" <<'EOF'
#!/usr/bin/env bash
printf 'mount_nfs:%s\n' "$*" >> "${JMOUNT_TEST_LOG}"
mkdir -p -- "$2"
EOF

  cat > "${JMOUNT_SHELL}" <<'EOF'
#!/usr/bin/env bash
printf 'shell:%s\n' "${PWD}" >> "${JMOUNT_TEST_LOG}"
EOF

  chmod +x "${JMOUNT_TEST_BIN}"/*
  export PATH="${JMOUNT_TEST_BIN}:${PATH}"
}

@test "Linux SMB profile mounts with local credentials and opens the mount directory" {
  local uid gid
  uid=$(id -u)
  gid=$(id -g)
  cat > "${HOME}/.local/.mounts.json" <<'EOF'
{
  "media": {
    "host": "nas",
    "share": "media",
    "user": "jay",
    "pass": "secret"
  }
}
EOF

  run env JSH_UNAME=Linux "${JSH_ROOT}/bin/jmount" media

  [[ ${status} -eq 0 ]]
  grep -Fq "sudo:mount -t cifs //nas/media ${JMOUNT_MOUNT_ROOT}/media -o credentials=" "${JMOUNT_TEST_LOG}"
  grep -Fq ",uid=${uid},gid=${gid}" "${JMOUNT_TEST_LOG}"
  grep -Fxq 'credentials:ok' "${JMOUNT_TEST_LOG}"
  [[ $(< "${JMOUNT_TEST_LOG}") != *'password=secret,uid='* ]]
  [[ -z $(find "${JSH_ROOT}/tmp" -name 'jmount-credentials.*' -print -quit) ]]
  grep -Fq "shell:${JMOUNT_MOUNT_ROOT}/media" "${JMOUNT_TEST_LOG}"
  [[ ${output} == *'Mounting smb://nas/media'* ]]
}

@test "macOS SMB URI prompts for missing fields and URL-encodes credentials" {
  local input_file="${BATS_TEST_TMPDIR}/input"
  printf 'nas.local\njay doe\np@ ss\n' > "${input_file}"
  mkdir -p "${JMOUNT_MOUNT_ROOT}/media"

  run env JSH_UNAME=Darwin JMOUNT_TEST_OPEN_SOURCE='//jay doe@nas.local/media' \
    JMOUNT_TEST_OPEN_TARGET="${JMOUNT_MOUNT_ROOT}/media" \
    "${JSH_ROOT}/bin/jmount" smb:///media < "${input_file}"

  [[ ${status} -eq 0 ]]
  grep -Fq 'open:-g smb://jay%20doe@nas.local/media' "${JMOUNT_TEST_LOG}"
  [[ $(< "${JMOUNT_TEST_LOG}") != *'p%40%20ss'* ]]
  grep -Fq "shell:${JMOUNT_MOUNT_ROOT}/media" "${JMOUNT_TEST_LOG}"
  run grep -Fq 'sudo:' "${JMOUNT_TEST_LOG}"
  [[ ${status} -ne 0 ]]
  [[ ${output} != *'p@ ss'* ]]
}

@test "Linux NFS URI uses the standard export source without credentials" {
  run env JSH_UNAME=Linux "${JSH_ROOT}/bin/jmount" nfs://files/export/archive

  [[ ${status} -eq 0 ]]
  grep -Fq "sudo:mount -t nfs files:/export/archive ${JMOUNT_MOUNT_ROOT}/archive" "${JMOUNT_TEST_LOG}"
  grep -Fq "shell:${JMOUNT_MOUNT_ROOT}/archive" "${JMOUNT_TEST_LOG}"
  [[ ${output} != *'Password:'* ]]
}

@test "an existing mount skips password input and the mount command" {
  local mountpoint="${JMOUNT_MOUNT_ROOT}/media"
  mkdir -p "${mountpoint}"
  export JMOUNT_TEST_MOUNTS="//jay@nas/media on ${mountpoint} (smbfs)"

  run env JSH_UNAME=Darwin "${JSH_ROOT}/bin/jmount" smb://jay@nas/media < /dev/null

  [[ ${status} -eq 0 ]]
  [[ ! -s ${JMOUNT_TEST_LOG} || $(< "${JMOUNT_TEST_LOG}") != *'mount_smbfs:'* ]]
  grep -Fq "shell:${mountpoint}" "${JMOUNT_TEST_LOG}"
  [[ ${output} == *"Already mounted: ${mountpoint}"* ]]
  [[ ${output} != *'Password:'* ]]
}

@test "local profile fields select NFS without prompting for SMB credentials" {
  cat > "${HOME}/.local/.mounts.json" <<'EOF'
{
  "archive": {
    "type": "nfs",
    "host": "files",
    "share": "/exports/archive"
  }
}
EOF

  run env JSH_UNAME=Darwin JMOUNT_TEST_OPEN_SOURCE='files:/exports/archive' \
    JMOUNT_TEST_OPEN_TARGET="${JMOUNT_MOUNT_ROOT}/archive" \
    "${JSH_ROOT}/bin/jmount" archive

  [[ ${status} -eq 0 ]]
  grep -Fq 'open:-g nfs://files/exports/archive' "${JMOUNT_TEST_LOG}"
  [[ ${output} != *'User:'* ]]
  [[ ${output} != *'Password:'* ]]
}

@test "local profile fields override repository configuration" {
  local fixture_root="${BATS_TEST_TMPDIR}/jsh"
  mkdir -p "${fixture_root}/conf"
  ln -s "${JSH_ROOT}/lib" "${fixture_root}/lib"
  cat > "${fixture_root}/conf/mounts.json" <<'EOF'
{
  "media": {
    "host": "old-nas",
    "share": "media",
    "user": "old-user",
    "pass": "old-pass"
  }
}
EOF
  cat > "${HOME}/.local/.mounts.json" <<'EOF'
{
  "media": {
    "host": "new-nas",
    "user": "jay",
    "pass": "secret"
  }
}
EOF

  run env JSH_ROOT="${fixture_root}" JSH_UNAME=Linux "${JSH_ROOT}/bin/jmount" media

  [[ ${status} -eq 0 ]]
  grep -Fq "sudo:mount -t cifs //new-nas/media ${JMOUNT_MOUNT_ROOT}/media -o credentials=" "${JMOUNT_TEST_LOG}"
  run grep -Fq 'old-nas' "${JMOUNT_TEST_LOG}"
  [[ ${status} -ne 0 ]]
}

@test "profile mountpoint overrides the platform default" {
  local custom_mount="${BATS_TEST_TMPDIR}/custom/media"
  mkdir -p "${custom_mount}"
  cat > "${HOME}/.local/.mounts.json" <<EOF
{
  "media": {
    "host": "nas",
    "share": "media",
    "user": "jay",
    "pass": "secret",
    "mountpoint": "${custom_mount}"
  }
}
EOF

  run env JSH_UNAME=Darwin "${JSH_ROOT}/bin/jmount" media

  [[ ${status} -eq 0 ]]
  grep -Fq "mount_smbfs://jay@nas/media ${custom_mount}" "${JMOUNT_TEST_LOG}"
  [[ $(< "${JMOUNT_TEST_LOG}") != *secret* ]]
  grep -Fq "shell:${custom_mount}" "${JMOUNT_TEST_LOG}"
}
