#!/usr/bin/env bats

: "${BATS_TEST_DIRNAME:=.}"
: "${BATS_TEST_TMPDIR:=${TMPDIR:-./tmp}}"

setup() {
  export JSH_ROOT
  JSH_ROOT=$(cd -- "${BATS_TEST_DIRNAME}/.." && pwd -P)
}

@test "multiple backends are selected through the shared Gum chooser" {
  local commands="${BATS_TEST_TMPDIR}/commands" project="${BATS_TEST_TMPDIR}/project"
  local calls="${BATS_TEST_TMPDIR}/calls"
  mkdir -p "${commands}" "${project}"
  project=$(cd -- "${project}" && pwd -P)
  cat > "${commands}/gum" <<'EOF'
#!/bin/sh
printf 'gum %s\n' "$*" >> "${CALLS}"
printf '%s\n' openai
EOF
  cat > "${commands}/graphify" <<'EOF'
#!/bin/sh
printf 'graphify %s\n' "$*" >> "${CALLS}"
mkdir -p "$2/graphify-out"
printf '{}\n' > "$2/graphify-out/graph.json"
EOF
  chmod +x "${commands}/gum" "${commands}/graphify"

  run env PATH="${commands}:${PATH}" CALLS="${calls}" GEMINI_API_KEY=test OPENAI_API_KEY=test \
    JSH_INTERACTIVE=1 JSH_REMOTE=0 JSH_UI_BACKEND=gum JSH_GUM="${commands}/gum" \
    "${JSH_ROOT}/bin/jgraphify" "${project}"

  [[ ${status} -eq 0 ]]
  grep -Fq 'gum choose --header     GRAPHIFY BACKEND --label-delimiter=' "${calls}"
  grep -Fqx "graphify extract ${project} --backend openai" "${calls}"
}
