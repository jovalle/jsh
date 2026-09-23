#!/usr/bin/env bats

: "${BATS_TEST_DIRNAME:=.}"
: "${BATS_TEST_TMPDIR:=${TMPDIR:-./tmp}}"

setup() {
  export JSH_ROOT
  JSH_ROOT=$(cd -- "${BATS_TEST_DIRNAME}/.." && pwd -P)
  export HOME="${BATS_TEST_TMPDIR}/home"
  export JGIT_CONFIG="${BATS_TEST_TMPDIR}/git.json"
  export JSH_PLAIN_OUTPUT=1
  export JSH_INTERACTIVE=0
  export JSH_NON_INTERACTIVE=0
  export JSH_UI_BACKEND=auto
  export TZ=UTC
  mkdir -p "${HOME}/.ssh"
  printf 'test key\n' > "${HOME}/.ssh/id_test"
  chmod 600 "${HOME}/.ssh/id_test"
  cat > "${JGIT_CONFIG}" <<'EOF'
{
  "profiles": {
    "personal": {
      "name": "Test User",
      "email": "test@example.com",
      "user": "tester",
      "ssh_key": "id_test"
    }
  }
}
EOF
}

init_repo() {
  local repository=$1
  git init -q -b main "${repository}"
  git -C "${repository}" config user.name 'Test User'
  git -C "${repository}" config user.email test@example.com
}

commit_file() {
  local repository=$1 file=$2 content=$3 subject=$4 author_date=$5 committer_date=${6:-$5}
  printf '%s\n' "${content}" > "${repository}/${file}"
  git -C "${repository}" add "${file}"
  GIT_AUTHOR_DATE="${author_date}" GIT_COMMITTER_DATE="${committer_date}" \
    git -C "${repository}" commit -q -m "${subject}"
}

add_broken_codex_ref() {
  local repository=$1
  mkdir -p "${repository}/.git/refs/codex/turn-diffs/checkpoints/session"
  printf '%s\n' ffffffffffffffffffffffffffffffffffffffff > \
    "${repository}/.git/refs/codex/turn-diffs/checkpoints/session/broken"
}

run_jgit() {
  "${JSH_ROOT}/bin/jgit" "$@"
}

@test "help version dashboard and Git passthrough are available" {
  local repository="${BATS_TEST_TMPDIR}/repository"
  init_repo "${repository}"
  commit_file "${repository}" file one Initial '2026-09-15 10:00:00 +0000'

  run run_jgit --help
  [[ ${status} -eq 0 ]]
  [[ ${output} == *'amend [REF] -t TIME'* ]]

  run run_jgit --version
  [[ ${status} -eq 0 ]]
  [[ ${output} == 'jgit 1.0.0' ]]

  cd "${repository}"
  run run_jgit
  [[ ${status} -eq 0 ]]
  [[ ${output} == *'Repository'* ]]
  [[ ${output} == *'Recent commits'* ]]

  run run_jgit rev-parse --is-inside-work-tree
  [[ ${status} -eq 0 ]]
  [[ ${output} == true ]]
}

@test "identity and profile commands list and apply configured identities" {
  local repository="${BATS_TEST_TMPDIR}/repository"
  init_repo "${repository}"
  cd "${repository}"

  for command in identity identities profile profiles; do
    if [[ ${command} == identity || ${command} == profile ]]; then
      run run_jgit "${command}" list
    else
      run run_jgit "${command}"
    fi
    [[ ${status} -eq 0 ]]
    [[ ${output} == *personal* ]]
    [[ ${output} == *'Test User'* ]]
  done

  run run_jgit identity set personal
  [[ ${status} -eq 0 ]]
  [[ $(git config --local user.email) == test@example.com ]]
  [[ $(git config --local jsh.profile) == personal ]]

  run run_jgit profile personal
  [[ ${status} -eq 0 ]]
  [[ $(git config --local user.name) == 'Test User' ]]
}

@test "interactive identity selection uses the shared Gum chooser" {
  local repository="${BATS_TEST_TMPDIR}/repository" gum="${BATS_TEST_TMPDIR}/gum"
  init_repo "${repository}"
  cat > "${gum}" <<'EOF'
#!/bin/sh
[ "$1" = choose ] || exit 1
printf '%s\n' personal
EOF
  chmod +x "${gum}"
  cd "${repository}"

  run env JSH_INTERACTIVE=1 JSH_REMOTE=0 JSH_UI_BACKEND=gum JSH_GUM="${gum}" \
    "${JSH_ROOT}/bin/jgit" identity

  [[ ${status} -eq 0 ]]
  [[ $(git config --local jsh.profile) == personal ]]
}

@test "identity rewrites GitHub HTTPS remotes to SSH" {
  local repository="${BATS_TEST_TMPDIR}/repository"
  init_repo "${repository}"
  git -C "${repository}" remote add origin https://github.com/example/repository.git
  git -C "${repository}" remote set-url --push origin https://github.com/tester/repository.git
  git -C "${repository}" remote add upstream git@github.com:upstream/repository.git
  git -C "${repository}" remote add external https://gitlab.com/example/repository.git
  cd "${repository}"

  run run_jgit identity set personal

  [[ ${status} -eq 0 ]]
  [[ $(git remote get-url origin) == git@github.com:example/repository.git ]]
  [[ $(git remote get-url --push origin) == git@github.com:tester/repository.git ]]
  [[ $(git remote get-url upstream) == git@github.com:upstream/repository.git ]]
  [[ $(git remote get-url external) == https://gitlab.com/example/repository.git ]]
}

@test "create initializes a project and applies the selected profile" {
  local launcher="${BATS_TEST_TMPDIR}/launcher" projects="${BATS_TEST_TMPDIR}/Projects"
  init_repo "${launcher}"
  cd "${launcher}"

  run bash -c 'printf "personal\n" | JSH_INTERACTIVE=1 JSH_PROJECT_DIR="$1" "$2/bin/jgit" create example' \
    _ "${projects}" "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
  [[ -d ${projects}/example/.git ]]
  [[ $(git -C "${projects}/example" config user.email) == test@example.com ]]
}

@test "completion exposes profiles and native Git commands" {
  run run_jgit __complete profile
  [[ ${status} -eq 0 ]]
  [[ ${output} == *$'personal\tGit identity'* ]]

  run run_jgit __complete git-command
  [[ ${status} -eq 0 ]]
  [[ ${output} == *$'commit\t'* ]]
}

@test "commit accepts relative and partial absolute timestamps" {
  local repository="${BATS_TEST_TMPDIR}/repository"
  init_repo "${repository}"
  commit_file "${repository}" first one Initial '2026-09-15 10:10:10 +0000'
  cd "${repository}"

  printf 'two\n' > second
  git add second
  run env JGIT_RANDOM_VALUE=754 "${JSH_ROOT}/bin/jgit" commit -t +5h -m Relative
  [[ ${status} -eq 0 ]]
  [[ $(git show -s --format='%ct') -eq 1789485154 ]]

  printf 'three\n' > third
  git add third
  run env JGIT_RANDOM_VALUE=754 "${JSH_ROOT}/bin/jgit" commit -t '2026-09-17 22' -m Absolute
  [[ ${status} -eq 0 ]]
  [[ $(git show -s --format='%ct') -eq 1789683154 ]]
}

@test "commit chains unsigned durations after now or a future HEAD" {
  local repository="${BATS_TEST_TMPDIR}/repository" before after first_epoch
  init_repo "${repository}"
  before=$(date +%s)
  commit_file "${repository}" first one Initial "@$((before - 3600)) +0000"
  cd "${repository}"

  printf 'two\n' > second
  git add second
  run run_jgit commit -t 30m0s -m Second
  [[ ${status} -eq 0 ]]
  after=$(date +%s)
  first_epoch=$(git show -s --format='%ct')
  [[ ${first_epoch} -ge $((before + 1800)) ]]
  [[ ${first_epoch} -le $((after + 1800)) ]]

  printf 'three\n' > third
  git add third
  run run_jgit commit -t 21m0s -m Third
  [[ ${status} -eq 0 ]]
  [[ $(git show -s --format='%ct') -eq $((first_epoch + 1260)) ]]
}

@test "partial timestamp parsing is portable to GNU date" {
  local repository="${BATS_TEST_TMPDIR}/repository" shim="${BATS_TEST_TMPDIR}/gnu-bin"
  local date_command
  if command -v gdate > /dev/null 2>&1; then
    date_command=$(command -v gdate)
  elif date --version > /dev/null 2>&1; then
    date_command=$(command -v date)
  else
    skip 'GNU date is unavailable'
  fi
  mkdir -p "${shim}"
  ln -s "${date_command}" "${shim}/date"
  init_repo "${repository}"
  commit_file "${repository}" file one Initial '2026-09-15 10:10:10 +0000'
  cd "${repository}"

  run env PATH="${shim}:${PATH}" JGIT_RANDOM_VALUE=754 \
    "${JSH_ROOT}/bin/jgit" amend -t '2026-09-17 22' --yes

  [[ ${status} -eq 0 ]]
  [[ $(git show -s --format='%ct') -eq 1789683154 ]]

  run env PATH="${shim}:${PATH}" "${JSH_ROOT}/bin/jgit" amend -t '2026-02-30 10:00' --yes
  [[ ${status} -ne 0 ]]
  [[ ${output} == *'invalid timestamp'* ]]
}

@test "amend shifts the target and all following commits by one effective delta" {
  local repository="${BATS_TEST_TMPDIR}/repository" old_tree old_tip status_before identities
  init_repo "${repository}"
  commit_file "${repository}" first one A '2026-09-15 10:10:10 +0000'
  commit_file "${repository}" second two B '2026-09-15 11:00:00 +0000' \
    '2026-09-15 11:20:30 +0000'
  commit_file "${repository}" third three C '2026-09-15 12:30:40 +0000'
  old_tree=$(git -C "${repository}" rev-parse 'HEAD^{tree}')
  old_tip=$(git -C "${repository}" rev-parse HEAD)
  identities=$(git -C "${repository}" log --reverse --format='%an <%ae>|%cn <%ce>|%s')
  printf 'dirty\n' >> "${repository}/third"
  printf 'untracked\n' > "${repository}/untracked"
  status_before=$(git -C "${repository}" status --porcelain)
  cd "${repository}"

  run env JGIT_RANDOM_VALUE=754 "${JSH_ROOT}/bin/jgit" amend HEAD~2 -t '2026-09-15 15' --yes

  [[ ${status} -eq 0 ]]
  [[ ${output} == *'Moved 3 commits'* ]]
  [[ ${output} == *"git update-ref refs/heads/"* ]]
  [[ $(git log --reverse --format='%s %at %ct') == $'A 1789485154 1789485154\nB 1789488144 1789489374\nC 1789493584 1789493584' ]]
  [[ $(git rev-parse 'HEAD^{tree}') == "${old_tree}" ]]
  [[ $(git log --reverse --format='%an <%ae>|%cn <%ce>|%s') == "${identities}" ]]
  [[ $(git status --porcelain) == "${status_before}" ]]
  [[ $(git rev-parse HEAD) != "${old_tip}" ]]
}

@test "amend supports exact offsets dry runs and HEAD by default" {
  local repository="${BATS_TEST_TMPDIR}/repository" old_tip
  init_repo "${repository}"
  commit_file "${repository}" first one Parent '2026-09-15 10:10:10 +0000'
  commit_file "${repository}" second two Target '2026-09-15 12:10:10 +0000'
  cd "${repository}"
  old_tip=$(git rev-parse HEAD)
  git update-ref refs/remotes/origin/main "${old_tip}"

  run run_jgit amend -t +5h0m0s --dry-run
  [[ ${status} -eq 0 ]]
  [[ ${output} == *'+10800 seconds'* ]]
  [[ $(git rev-parse HEAD) == "${old_tip}" ]]

  run run_jgit amend -t +5h0m0s
  [[ ${status} -eq 0 ]]
  [[ ${output} == *'Local branch updated; no remote refs were changed.'* ]]
  [[ $(git show -s --format='%ct') -eq 1789485010 ]]
  [[ $(git rev-parse refs/remotes/origin/main) == "${old_tip}" ]]
}

@test "amend supports offsets relative to the previous first-parent commit" {
  local repository="${BATS_TEST_TMPDIR}/repository"
  init_repo "${repository}"
  commit_file "${repository}" first one Parent '2026-09-15 09:00:00 +0000'
  commit_file "${repository}" second two Target '2026-09-15 11:00:00 +0000'
  commit_file "${repository}" third three Following '2026-09-15 12:00:00 +0000'
  cd "${repository}"

  run env JGIT_RANDOM_VALUE=0 "${JSH_ROOT}/bin/jgit" amend HEAD~1 -t +30m --yes

  [[ ${status} -eq 0 ]]
  [[ $(git log --reverse --format='%s %ct') == $'Parent 1789462800\nTarget 1789464600\nFollowing 1789468200' ]]

  run run_jgit amend HEAD -t -30m0s --yes
  [[ ${status} -ne 0 ]]
  [[ ${output} == *'before parent'* ]]
}

@test "amend rejects signed offsets for a root commit" {
  local repository="${BATS_TEST_TMPDIR}/repository"
  init_repo "${repository}"
  commit_file "${repository}" file one Initial '2026-09-15 10:00:00 +0000'
  cd "${repository}"

  run run_jgit amend -t +30m0s --yes

  [[ ${status} -ne 0 ]]
  [[ ${output} == *'signed offset for the root commit'* ]]
}

@test "amend resolves unsigned durations after now or the branch tip" {
  local repository="${BATS_TEST_TMPDIR}/repository" future
  init_repo "${repository}"
  future=$(($(date +%s) + 3600))
  commit_file "${repository}" first one Parent "@$((future - 7200)) +0000"
  commit_file "${repository}" second two Target "@$((future - 3600)) +0000"
  commit_file "${repository}" third three Following "@${future} +0000"
  cd "${repository}"

  run run_jgit amend HEAD~1 -t 30m0s --yes

  [[ ${status} -eq 0 ]]
  [[ $(git show -s --format='%ct' HEAD~1) -eq $((future + 1800)) ]]
  [[ $(git show -s --format='%ct' HEAD) -eq $((future + 5400)) ]]
}

@test "amend preserves merge topology and leaves side history unchanged" {
  local repository="${BATS_TEST_TMPDIR}/repository" target side old_tree
  init_repo "${repository}"
  commit_file "${repository}" base base Base '2026-09-15 09:00:00 +0000'
  commit_file "${repository}" target target Target '2026-09-15 10:00:00 +0000'
  target=$(git -C "${repository}" rev-parse HEAD)
  git -C "${repository}" branch side
  commit_file "${repository}" main main Main '2026-09-15 11:00:00 +0000'
  git -C "${repository}" switch -q side
  commit_file "${repository}" side side Side '2026-09-15 11:30:00 +0000'
  side=$(git -C "${repository}" rev-parse HEAD)
  git -C "${repository}" switch -q main
  GIT_AUTHOR_DATE='2026-09-15 12:00:00 +0000' GIT_COMMITTER_DATE='2026-09-15 12:00:00 +0000' \
    git -C "${repository}" merge -q --no-ff side -m Merge
  old_tree=$(git -C "${repository}" rev-parse 'HEAD^{tree}')
  cd "${repository}"

  run run_jgit amend "${target}" -t +2h0m0s --yes

  [[ ${status} -eq 0 ]]
  [[ $(git rev-list --parents -n 1 HEAD | wc -w | tr -d ' ') -eq 3 ]]
  [[ $(git rev-parse HEAD^2) == "${side}" ]]
  [[ $(git rev-parse 'HEAD^{tree}') == "${old_tree}" ]]
  [[ $(git log --first-parent --reverse --format='%s %ct' | tail -3) == $'Target 1789470000\nMain 1789473600\nMerge 1789477200' ]]
}

@test "amend rejects invalid refs detached heads and non-first-parent commits" {
  local repository="${BATS_TEST_TMPDIR}/repository" side
  init_repo "${repository}"
  commit_file "${repository}" base base Base '2026-09-15 09:00:00 +0000'
  git -C "${repository}" branch side
  commit_file "${repository}" main main Main '2026-09-15 10:00:00 +0000'
  git -C "${repository}" switch -q side
  commit_file "${repository}" side side Side '2026-09-15 10:30:00 +0000'
  side=$(git -C "${repository}" rev-parse HEAD)
  git -C "${repository}" switch -q main
  cd "${repository}"

  run run_jgit amend missing -t +1h --yes
  [[ ${status} -ne 0 ]]
  [[ ${output} == *'invalid commit ref'* ]]

  run run_jgit amend "${side}" -t +1h --yes
  [[ ${status} -ne 0 ]]
  [[ ${output} == *'first-parent history'* ]]

  git switch -q --detach
  run run_jgit amend -t +1h --yes
  [[ ${status} -ne 0 ]]
  [[ ${output} == *'requires a branch checkout'* ]]
}

@test "amend rejects invalid timestamps and chronology inversions" {
  local repository="${BATS_TEST_TMPDIR}/repository"
  init_repo "${repository}"
  commit_file "${repository}" first one Parent '2026-09-15 09:00:00 +0000'
  commit_file "${repository}" second two A '2026-09-15 10:00:00 +0000'
  commit_file "${repository}" third three B '2026-09-15 11:00:00 +0000'
  cd "${repository}"

  run run_jgit amend -t '2026-02-30 10:00' --yes
  [[ ${status} -ne 0 ]]
  [[ ${output} == *'invalid timestamp'* ]]

  run run_jgit amend HEAD~1 -t '2026-09-15 08:00:00' --yes
  [[ ${status} -ne 0 ]]
  [[ ${output} == *'before parent'* ]]
}

@test "amend rejects signed commit metadata without moving the branch" {
  local repository="${BATS_TEST_TMPDIR}/repository" raw signed old_tip
  init_repo "${repository}"
  commit_file "${repository}" file one Initial '2026-09-15 10:00:00 +0000'
  raw="${BATS_TEST_TMPDIR}/signed.commit"
  git -C "${repository}" cat-file commit HEAD | awk '
    !added && /^$/ { print "gpgsig fake-signature"; print " continuation"; added = 1 }
    { print }
  ' > "${raw}"
  signed=$(git -C "${repository}" hash-object -t commit -w "${raw}")
  git -C "${repository}" update-ref refs/heads/main "${signed}"
  old_tip=$(git -C "${repository}" rev-parse HEAD)
  cd "${repository}"

  run run_jgit amend -t '2026-09-15 11:00:00' --yes

  [[ ${status} -ne 0 ]]
  [[ ${output} == *'unsupported gpgsig header'* ]]
  [[ $(git rev-parse HEAD) == "${old_tip}" ]]
}

@test "rewrite exposes selection modes and rejects an empty selection" {
  local repository="${BATS_TEST_TMPDIR}/repository"
  init_repo "${repository}"
  commit_file "${repository}" file one Initial '2026-09-15 10:00:00 +0000'
  cd "${repository}"

  run run_jgit rewrite --help

  [[ ${status} -eq 0 ]]
  [[ ${output} == *'jgit rewrite REF'* ]]
  [[ ${output} == *'jgit rewrite --last N'* ]]

  run run_jgit rewrite
  [[ ${status} -ne 0 ]]
  [[ ${output} == *'requires one or more refs'* ]]
}

@test "rewrite resolves signed offsets from the selected commit parent" {
  local repository="${BATS_TEST_TMPDIR}/repository"
  init_repo "${repository}"
  commit_file "${repository}" first one Parent '2026-09-15 09:00:00 +0000'
  commit_file "${repository}" second two Target '2026-09-15 11:00:00 +0000'
  commit_file "${repository}" third three Following '2026-09-15 12:00:00 +0000'
  cd "${repository}"

  run bash -c 'printf "+30m0s\n" | JSH_ASSUME_YES=1 GIT_EDITOR=true "$1/bin/jgit" rewrite HEAD~1' \
    _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
  [[ $(git log --reverse --format='%s %ct') == $'Parent 1789462800\nTarget 1789464600\nFollowing 1789473600' ]]
}

@test "heal previews broken Codex refs without changing them" {
  local repository="${BATS_TEST_TMPDIR}/repository"
  init_repo "${repository}"
  commit_file "${repository}" file one Initial '2026-09-15 10:00:00 +0000'
  add_broken_codex_ref "${repository}"
  cd "${repository}"

  run run_jgit heal

  [[ ${status} -ne 0 ]]
  [[ ${output} == *'Would remove refs/codex/turn-diffs/checkpoints/session/broken'* ]]
  [[ -f .git/refs/codex/turn-diffs/checkpoints/session/broken ]]
}

@test "heal backs up and removes broken Codex refs" {
  local repository="${BATS_TEST_TMPDIR}/repository" backup
  init_repo "${repository}"
  commit_file "${repository}" file one Initial '2026-09-15 10:00:00 +0000'
  add_broken_codex_ref "${repository}"
  cd "${repository}"

  run run_jgit heal --yes

  [[ ${status} -eq 0 ]]
  [[ ${output} == *'Removed refs/codex/turn-diffs/checkpoints/session/broken'* ]]
  [[ ! -e .git/refs/codex/turn-diffs/checkpoints/session/broken ]]
  backup=$(find .git -maxdepth 1 -name 'jgit-heal-refs.*.txt')
  [[ -f ${backup} ]]
  grep -q 'refs/codex/turn-diffs/checkpoints/session/broken' "${backup}"
  git for-each-ref --format='%(refname)' | grep -q '^refs/heads/main$'
}

@test "heal never removes a broken branch" {
  local repository="${BATS_TEST_TMPDIR}/repository"
  init_repo "${repository}"
  commit_file "${repository}" file one Initial '2026-09-15 10:00:00 +0000'
  printf '%s\n' ffffffffffffffffffffffffffffffffffffffff > \
    "${repository}/.git/refs/heads/broken"
  cd "${repository}"

  run run_jgit heal --yes

  [[ ${status} -ne 0 ]]
  [[ ${output} == *'Broken protected ref requires manual recovery: refs/heads/broken'* ]]
  [[ -f .git/refs/heads/broken ]]
}

@test "update fast-forwards one repository and discovers repositories with all" {
  local remote="${BATS_TEST_TMPDIR}/remote.git" seed="${BATS_TEST_TMPDIR}/seed"
  local base="${BATS_TEST_TMPDIR}/projects" first second
  first=${base}/first
  second=${base}/second
  git init -q --bare "${remote}"
  init_repo "${seed}"
  commit_file "${seed}" file one Initial '2026-09-15 10:00:00 +0000'
  git -C "${seed}" remote add origin "${remote}"
  git -C "${seed}" push -q -u origin main
  git -C "${remote}" symbolic-ref HEAD refs/heads/main
  mkdir -p "${base}"
  git clone -q "${remote}" "${first}"
  git clone -q "${remote}" "${second}"
  printf 'two\n' >> "${seed}/file"
  git -C "${seed}" add file
  git -C "${seed}" commit -q -m Second
  git -C "${seed}" push -q

  cd "${first}"
  run run_jgit update
  [[ ${status} -eq 0 ]]
  [[ $(git rev-parse HEAD) == $(git -C "${seed}" rev-parse HEAD) ]]

  cd "${base}"
  run run_jgit update --all "${base}"
  [[ ${status} -eq 0 ]]
  [[ ${output} == *'Updated 2 repositories; 0 failed'* ]]
  [[ $(git -C "${second}" rev-parse HEAD) == $(git -C "${seed}" rev-parse HEAD) ]]
}

@test "save backup load and restore expose offline-safe help" {
  local repository="${BATS_TEST_TMPDIR}/repository" command canonical
  init_repo "${repository}"
  commit_file "${repository}" file one Initial '2026-09-15 10:00:00 +0000'
  git -C "${repository}" remote add origin git@github.com:example/repository.git
  cd "${repository}"

  for command in save backup load restore; do
    case ${command} in
      save | backup) canonical=save ;;
      load | restore) canonical=load ;;
    esac
    run run_jgit "${command}" --help
    [[ ${status} -eq 0 ]]
    [[ ${output} == "Usage: jgit ${canonical}"* ]]
  done
}

@test "backup helpers accept no excludes under nounset" {
  run /bin/bash -u -c '
    source "$1/lib/backup.sh"
    JGIT_BACKUP_ROOT=$2 JGIT_BACKUP_ACTION=load
    _jgit_backup_parse_excludes
    _jgit_backup_map_excludes ""
    _jgit_backup_build_pathspecs
    [[ ${#JGIT_BACKUP_EXCLUDES[@]} -eq 0 ]]
    [[ ${#JGIT_BACKUP_LOCAL_EXCLUDES[@]} -eq 0 ]]
    [[ ${JGIT_BACKUP_PATHS[*]} == "-- ." ]]
  ' test "${JSH_ROOT}" "${BATS_TEST_TMPDIR}"

  [[ ${status} -eq 0 ]]
}

@test "backup load rolls back ordinary conflicts and retains recovery stash" {
  local repository="${BATS_TEST_TMPDIR}/repository" snapshot="${BATS_TEST_TMPDIR}/snapshot"
  local work="${BATS_TEST_TMPDIR}/work" before_status
  init_repo "${repository}"
  commit_file "${repository}" file $'before\nbase\nafter' Initial '2026-09-15 10:00:00 +0000'
  mkdir -p "${snapshot}/main" "${snapshot}/submodules" "${work}"
  printf 'before\nbackup\nafter\n' > "${repository}/file"
  git -C "${repository}" diff --binary --full-index > "${snapshot}/main/tracked.patch"
  : > "${snapshot}/main/staged.patch"
  : > "${snapshot}/main/untracked.list"
  git -C "${repository}" checkout -q -- file
  printf 'before\ncurrent\nafter\n' > "${repository}/file"
  before_status=$(git -C "${repository}" status --porcelain=v1)

  run bash -c '
    source "$1/lib/backup.sh"
    jsh::log_error() { printf "error: %s\n" "$*" >&2; }
    jsh::log_info() { :; }
    jsh::log_warn() { :; }
    JGIT_BACKUP_ROOT=$2 JGIT_BACKUP_SNAPSHOT=$3 JGIT_BACKUP_WORK_DIR=$4
    JGIT_BACKUP_EXCLUDES=()
    _jgit_backup_stash_current_changes && _jgit_backup_apply_transaction
  ' test "${JSH_ROOT}" "${repository}" "${snapshot}" "${work}"

  [[ ${status} -ne 0 ]]
  [[ $(< "${repository}/file") == $'before\ncurrent\nafter' ]]
  [[ $(git -C "${repository}" status --porcelain=v1) == "${before_status}" ]]
  [[ -z $(git -C "${repository}" ls-files -u) ]]
  [[ $(git -C "${repository}" stash list --format='%s' | head -n 1) == On\ main:\ jgit\ load* ]]
}

@test "backup load resolves populated submodule conflicts to the newer commit" {
  local child="${BATS_TEST_TMPDIR}/child" repository="${BATS_TEST_TMPDIR}/repository"
  local old_commit new_commit selected
  init_repo "${child}"
  commit_file "${child}" file old Old '2026-09-15 10:00:00 +0000'
  old_commit=$(git -C "${child}" rev-parse HEAD)
  commit_file "${child}" file new New '2026-09-16 10:00:00 +0000'
  new_commit=$(git -C "${child}" rev-parse HEAD)
  init_repo "${repository}"
  git -c protocol.file.allow=always -C "${repository}" submodule add -q "${child}" vendor/child
  git -C "${repository}/vendor/child" checkout -q --detach "${old_commit}"
  git -C "${repository}" add .gitmodules vendor/child
  git -C "${repository}" commit -q -m 'Add child'
  git -C "${repository}" update-index --force-remove vendor/child
  printf '160000 %s 1\tvendor/child\n160000 %s 2\tvendor/child\n160000 %s 3\tvendor/child\n' \
    "${old_commit}" "${old_commit}" "${new_commit}" |
    git -C "${repository}" update-index --index-info

  run bash -c '
    source "$1/lib/backup.sh"
    jsh::log_info() { :; }
    JGIT_BACKUP_ROOT=$2 JGIT_BACKUP_WORK_DIR=$3
    mkdir -p "$3"
    _jgit_backup_resolve_gitlink_conflicts "$2"
  ' test "${JSH_ROOT}" "${repository}" "${BATS_TEST_TMPDIR}/work"

  [[ ${status} -eq 0 ]]
  [[ -z $(git -C "${repository}" ls-files -u) ]]
  selected=$(git -C "${repository}" ls-files -s vendor/child | awk '{print $2}')
  [[ ${selected} == "${new_commit}" ]]
  [[ $(git -C "${repository}/vendor/child" rev-parse HEAD) == "${new_commit}" ]]

  git -C "${repository}/vendor/child" checkout -q --detach "${old_commit}"
  git -C "${repository}" update-index --add --cacheinfo 160000 "${new_commit}" vendor/child
  run bash -c '
    source "$1/lib/backup.sh"
    jsh::log_info() { :; }
    JGIT_BACKUP_ROOT=$2 JGIT_BACKUP_WORK_DIR=$3
    _jgit_backup_reconcile_gitlink vendor/child "$4"
  ' test "${JSH_ROOT}" "${repository}" "${BATS_TEST_TMPDIR}/work" "${new_commit}"

  [[ ${status} -eq 0 ]] || {
    printf 'status=%s\n%s\n' "${status}" "${output}" >&2
    false
  }
  [[ $(git -C "${repository}/vendor/child" rev-parse HEAD) == "${new_commit}" ]]
}
