#!/usr/bin/env bats
# Tests for gitx profile management and commit enforcement
# shellcheck disable=SC2034,SC2154

load test_helper

# =============================================================================
# Setup / Teardown
# =============================================================================

setup() {
    mkdir -p "${JSH_TEST_TEMP}"
    export JSH_DIR="${BATS_TEST_DIRNAME}/.."
    export PATH="${JSH_DIR}/bin:${PATH}"

    # Create test profiles.json
    export JSH_PROFILES="${JSH_TEST_TEMP}/profiles.json"
    cat > "${JSH_PROFILES}" << 'EOF'
{
  "profiles": {
    "personal": {
      "name": "Jay Ovalle",
      "email": "jay@example.com",
      "user": "jovalle",
      "ssh_key": "WILL_BE_SET_IN_TEST"
    },
    "work": {
      "name": "Jay Work",
      "email": "jay@corp.com",
      "user": "jovalle",
      "ssh_key": "WILL_BE_SET_IN_TEST",
      "signingkey": "WILL_BE_SET_IN_TEST",
      "gpgsign": true,
      "signingformat": "ssh"
    },
    "incomplete": {
      "name": "Missing Fields",
      "email": "missing@example.com"
    },
    "nosshkey": {
      "name": "No SSH",
      "email": "nossh@example.com",
      "user": "nosshuser",
      "ssh_key": "/nonexistent/path/id_ed25519"
    }
  }
}
EOF

    # Create fake SSH keys for testing
    mkdir -p "${JSH_TEST_TEMP}/.ssh"
    ssh-keygen -t ed25519 -f "${JSH_TEST_TEMP}/.ssh/id_personal" -N "" -q
    ssh-keygen -t ed25519 -f "${JSH_TEST_TEMP}/.ssh/id_work" -N "" -q

    # Update profiles to point to real test keys
    local personal_key="${JSH_TEST_TEMP}/.ssh/id_personal"
    local work_key="${JSH_TEST_TEMP}/.ssh/id_work"

    cat > "${JSH_PROFILES}" << EOF
{
  "profiles": {
    "personal": {
      "name": "Jay Ovalle",
      "email": "jay@example.com",
      "user": "jovalle",
      "ssh_key": "${personal_key}"
    },
    "work": {
      "name": "Jay Work",
      "email": "jay@corp.com",
      "user": "jovalle",
      "ssh_key": "${work_key}",
      "signingkey": "${work_key}",
      "gpgsign": true,
      "signingformat": "ssh"
    },
    "incomplete": {
      "name": "Missing Fields",
      "email": "missing@example.com"
    },
    "nosshkey": {
      "name": "No SSH",
      "email": "nossh@example.com",
      "user": "nosshuser",
      "ssh_key": "/nonexistent/path/id_ed25519"
    },
    "nosigning": {
      "name": "No Signing",
      "email": "nosign@example.com",
      "user": "nosignuser",
      "ssh_key": "${personal_key}"
    }
  }
}
EOF

    # Isolate from global git config (prevent gpg signing interference)
    export HOME="${JSH_TEST_TEMP}"
    export GIT_CONFIG_NOSYSTEM=1
    unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
    unset GIT_SSH_COMMAND

    # Create a test git repo
    TEST_REPO="${JSH_TEST_TEMP}/test_repo"
    mkdir -p "${TEST_REPO}"
    cd "${TEST_REPO}" || return 1
    git init -q
    git config user.email "initial@example.com"
    git config user.name "Initial User"
    echo "test" > README.md
    git add README.md
    git commit -q -m "Initial commit"
}

teardown() {
    rm -rf "${JSH_TEST_TEMP}" 2>/dev/null || true
}

# =============================================================================
# Profile Validation Tests
# =============================================================================

@test "profile apply: sets jsh.profile in local git config" {
    cd "${TEST_REPO}"
    run gitx profile personal
    [ "$status" -eq 0 ]

    local stored_profile
    stored_profile=$(git config --local jsh.profile)
    assert_equals "personal" "$stored_profile"
}

@test "profile apply: sets core.sshCommand with correct key" {
    cd "${TEST_REPO}"
    run gitx profile personal
    [ "$status" -eq 0 ]

    local ssh_cmd
    ssh_cmd=$(git config --local core.sshCommand)
    assert_contains "$ssh_cmd" "id_personal"
    assert_contains "$ssh_cmd" "IdentitiesOnly=yes"
}

@test "profile apply: sets signing config when signingkey present" {
    cd "${TEST_REPO}"
    run gitx profile work
    [ "$status" -eq 0 ]

    local signingkey gpgsign format
    signingkey=$(git config --local user.signingkey)
    gpgsign=$(git config --local commit.gpgsign)
    format=$(git config --local gpg.format)

    assert_contains "$signingkey" "id_work"
    assert_equals "true" "$gpgsign"
    assert_equals "ssh" "$format"
}

@test "profile apply: disables signing when signingkey absent" {
    cd "${TEST_REPO}"
    run gitx profile nosigning
    [ "$status" -eq 0 ]

    local gpgsign
    gpgsign=$(git config --local commit.gpgsign)
    assert_equals "false" "$gpgsign"
}

@test "profile apply: errors on missing required fields (user)" {
    cd "${TEST_REPO}"
    run gitx profile incomplete
    [ "$status" -ne 0 ]
    assert_contains "$output" "missing required field"
}

@test "profile apply: errors on nonexistent SSH key file" {
    cd "${TEST_REPO}"
    run gitx profile nosshkey
    [ "$status" -ne 0 ]
    assert_contains "$output" "SSH key not found"
}

@test "profile apply: errors on nonexistent profile" {
    cd "${TEST_REPO}"
    run gitx profile doesnotexist
    [ "$status" -ne 0 ]
}

@test "profile apply: migrates old ssh_host remote URL to standard host" {
    cd "${TEST_REPO}"
    git remote add origin "git@github-jovalle:jovalle/testrepo.git"

    run gitx profile personal
    [ "$status" -eq 0 ]

    local origin_url
    origin_url=$(git remote get-url origin)
    assert_contains "$origin_url" "github.com"
    assert_not_contains "$origin_url" "github-jovalle"
}

@test "profile apply: adds origin remote when missing" {
    cd "${TEST_REPO}"

  local profile_name
  profile_name=$(jq -r '.profiles | keys[0]' "${JSH_PROFILES}")

  run gitx profile "${profile_name}"
    [ "$status" -eq 0 ]

    local origin_url
    origin_url=$(git remote get-url origin)
  assert_matches "$origin_url" '^git@[^:]+:[^/]+/test_repo\.git$'
}

# =============================================================================
# Commit Enforcement Tests
# =============================================================================

@test "commit: errors when no profile assigned" {
    cd "${TEST_REPO}"
    # No jsh.profile set
    echo "change" >> README.md
    git add README.md

    run gitx commit -m "test commit"
    [ "$status" -ne 0 ]
    assert_contains "$output" "No profile assigned"
}

@test "commit: uses profile identity for author/committer" {
    cd "${TEST_REPO}"
    gitx profile personal

    echo "change" >> README.md
    git add README.md

    run gitx commit -m "test commit"
    [ "$status" -eq 0 ]

    local author_name author_email
    author_name=$(git log -1 --format='%an')
    author_email=$(git log -1 --format='%ae')

    assert_equals "Jay Ovalle" "$author_name"
    assert_equals "jay@example.com" "$author_email"
}

@test "commit: uses profile identity for committer" {
    cd "${TEST_REPO}"
    gitx profile personal

    echo "change" >> README.md
    git add README.md

    run gitx commit -m "test commit"
    [ "$status" -eq 0 ]

    local committer_name committer_email
    committer_name=$(git log -1 --format='%cn')
    committer_email=$(git log -1 --format='%ce')

    assert_equals "Jay Ovalle" "$committer_name"
    assert_equals "jay@example.com" "$committer_email"
}

@test "commit: overrides GIT_AUTHOR_NAME env var with profile" {
    cd "${TEST_REPO}"
    gitx profile personal

    echo "change" >> README.md
    git add README.md

    # Set conflicting env vars that should be overridden
    export GIT_AUTHOR_NAME="LEAKED_NAME"
    export GIT_AUTHOR_EMAIL="leaked@evil.com"

    run gitx commit -m "test commit"
    [ "$status" -eq 0 ]

    local author_name author_email
    author_name=$(git log -1 --format='%an')
    author_email=$(git log -1 --format='%ae')

    assert_equals "Jay Ovalle" "$author_name"
    assert_equals "jay@example.com" "$author_email"

    unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL
}

@test "commit: overrides GIT_COMMITTER_NAME env var with profile" {
    cd "${TEST_REPO}"
    gitx profile personal

    echo "change" >> README.md
    git add README.md

    export GIT_COMMITTER_NAME="LEAKED_COMMITTER"
    export GIT_COMMITTER_EMAIL="leaked_committer@evil.com"

    run gitx commit -m "test commit"
    [ "$status" -eq 0 ]

    local committer_name committer_email
    committer_name=$(git log -1 --format='%cn')
    committer_email=$(git log -1 --format='%ce')

    assert_equals "Jay Ovalle" "$committer_name"
    assert_equals "jay@example.com" "$committer_email"

    unset GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
}

@test "commit: disables signing when profile has no signingkey" {
    cd "${TEST_REPO}"
    # Set a global signing key that should NOT be used
    git config --global user.signingkey "/some/global/key"
    git config --global commit.gpgsign true

    gitx profile nosigning

    echo "change" >> README.md
    git add README.md

    # Should succeed without signing (--no-gpg-sign)
    run gitx commit -m "test commit"
    [ "$status" -eq 0 ]

    git config --global --unset user.signingkey 2>/dev/null || true
    git config --global --unset commit.gpgsign 2>/dev/null || true
}

@test "commit: passes through all git commit args" {
    cd "${TEST_REPO}"
    gitx profile personal

    echo "change" >> README.md
    git add README.md

    run gitx commit -m "custom message" --no-verify
    [ "$status" -eq 0 ]

    local msg
    msg=$(git log -1 --format='%s')
    assert_equals "custom message" "$msg"
}

@test "commit: errors when profile has missing required fields" {
    cd "${TEST_REPO}"
    # Manually set an incomplete profile
    git config --local jsh.profile "incomplete"

    echo "change" >> README.md
    git add README.md

    run gitx commit -m "test"
    [ "$status" -ne 0 ]
    assert_contains "$output" "missing required field"
}

@test "commit: errors when ssh_key file does not exist" {
    cd "${TEST_REPO}"
    git config --local jsh.profile "nosshkey"

    echo "change" >> README.md
    git add README.md

    run gitx commit -m "test"
    [ "$status" -ne 0 ]
    assert_contains "$output" "SSH key not found"
}

@test "commit: sets GIT_SSH_COMMAND with profile ssh_key" {
    cd "${TEST_REPO}"
    gitx profile personal

    echo "change" >> README.md
    git add README.md

    run gitx commit -m "test commit"
    [ "$status" -eq 0 ]

    # Verify core.sshCommand is set in local config
    local ssh_cmd
    ssh_cmd=$(git config --local core.sshCommand)
    assert_contains "$ssh_cmd" "id_personal"
    assert_contains "$ssh_cmd" "IdentitiesOnly=yes"
}

# =============================================================================
# Profile Status Tests
# =============================================================================

@test "profile status: shows assigned profile name" {
    cd "${TEST_REPO}"
    gitx profile personal

    run gitx profile
    [ "$status" -eq 0 ]
    assert_contains "$output" "personal"
}

@test "profile status: warns about conflicting env vars" {
    cd "${TEST_REPO}"
    gitx profile personal

    export GIT_AUTHOR_NAME="LEAKED"
    run gitx profile
    [ "$status" -eq 0 ]
    assert_contains "$output" "OVERRIDES"
    unset GIT_AUTHOR_NAME
}

@test "profile status: shows ssh key status" {
    cd "${TEST_REPO}"
    gitx profile personal

    run gitx profile
    [ "$status" -eq 0 ]
    assert_contains "$output" "id_personal"
    assert_contains "$output" "SHA256:"
}

# =============================================================================
# Profile List Tests
# =============================================================================

@test "profile list: shows ssh_key and signing columns" {
    run gitx profile list
    [ "$status" -eq 0 ]
    assert_contains "$output" "SSH KEY"
    assert_contains "$output" "SIGNING"
}

# =============================================================================
# Profile Migrate Tests
# =============================================================================

@test "profile migrate: converts ssh_host to ssh_key using ssh config" {
    # Create a mock ssh config
    local ssh_config="${JSH_TEST_TEMP}/.ssh/config"
    mkdir -p "${JSH_TEST_TEMP}/.ssh"
    cat > "${ssh_config}" << EOF
Host github-testuser
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_testuser
EOF

    # Create profiles with old ssh_host field
    cat > "${JSH_PROFILES}" << 'EOF'
{
  "profiles": {
    "oldstyle": {
      "name": "Old User",
      "email": "old@example.com",
      "user": "testuser",
      "ssh_host": "github-testuser"
    }
  }
}
EOF

    export HOME="${JSH_TEST_TEMP}"
    run gitx profile migrate
    [ "$status" -eq 0 ]
    assert_contains "$output" "ssh_key"
}
