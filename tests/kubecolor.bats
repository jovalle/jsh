#!/usr/bin/env bats

: "${BATS_TEST_DIRNAME:=.}"
: "${BATS_TEST_TMPDIR:=${TMPDIR:-./tmp}}"

setup() {
  export JSH_ROOT
  JSH_ROOT=$(cd -- "${BATS_TEST_DIRNAME}/.." && pwd -P)
}

@test "colors node fields by value in wide output" {
  local kubectl="${BATS_TEST_TMPDIR}/kubectl"
  cat > "${kubectl}" <<'EOF'
#!/bin/sh
printf '%-34s  %-9s %-24s %-7s %-24s %-16s %-12s %-36s %-32s %s\n' \
  NAME STATUS ROLES AGE VERSION INTERNAL-IP EXTERNAL-IP OS-IMAGE KERNEL-VERSION CONTAINER-RUNTIME
printf '%-34s  %-9s %-24s %-7s %-24s %-16s %-12s %-36s %-32s %s\n' \
  node-old Ready gpu,node 10d v1.35.5+vmware.1 169.117.254.98 '<none>' \
  'Red Hat Enterprise Linux 9.8 (Plow)' 5.14.0-687.39.1.el9_8.x86_64 containerd://2.2.3+vmware.2-fips
printf '%-34s  %-9s %-24s %-7s %-24s %-16s %-12s %-36s %-32s %s\n' \
  node-middle Ready gpu,worker 3d v1.35.6+vmware.1 169.117.254.99 '<none>' \
  'Red Hat Enterprise Linux 10.2 (Plow)' 6.1.0-101.el9.x86_64 containerd://2.3.0+vmware.1
printf '%-34s  %-9s %-24s %-7s %-24s %-16s %-12s %-36s %-32s %s\n' \
  node-young NotReady gpu,node 9m9s v1.35.5+vmware.1 169.117.254.100 '<none>' \
  'Red Hat Enterprise Linux 9.8 (Plow)' 5.14.0-687.39.1.el9_8.x86_64 containerd://2.2.3+vmware.2-fips
EOF
  chmod +x "${kubectl}"

  unset NO_COLOR
  run env KUBECOLOR_KUBECTL="${kubectl}" KUBECOLOR_FORCE_COLORS=1 \
    "${JSH_ROOT}/bin/kubecolor" get nodes -o wide

  [[ ${status} -eq 0 ]]
  [[ ${output} == *$'\033[97mnode-old\033[0m'* ]]
  [[ ${output} == *$'\033[92mReady\033[0m'* ]]
  [[ ${output} == *$'\033[91mNotReady\033[0m'* ]]
  [[ ${output} == *$'\033[95mgpu\033[0m,'$'\033[92mnode\033[0m'* ]]
  [[ ${output} == *$'\033[95mgpu\033[0m,'$'\033[94mworker\033[0m'* ]]
  [[ $(printf '%s\n' "${output}" | grep -oF $'\033[95mgpu\033[0m' | wc -l) -eq 3 ]]
  [[ ${output} != *$'\033[38;5;'*'10d\033[0m'* ]]
  [[ ${output} != *$'\033[38;5;'*'3d\033[0m'* ]]
  [[ ${output} != *$'\033[38;5;'*'9m9s\033[0m'* ]]
  [[ ${output} == *$'\033[38;5;255mv1.35.5+vmware.1\033[0m'* ]]
  [[ ${output} == *$'\033[38;5;244mv1.35.6+vmware.1\033[0m'* ]]
  [[ ${output} == *$'\033[38;5;255m9.8\033[0m'* ]]
  [[ ${output} == *$'\033[38;5;244m10.2\033[0m'* ]]
  [[ ${output} == *'RHEL '$'\033[38;5;255m9.8\033[0m'* ]]
  [[ ${output} != *'Red Hat Enterprise Linux'* ]]
  [[ ${output} != *'EXTERNAL-IP'* ]]
  [[ ${output} != *'CONTAINER-RUNTIME'* ]]
  [[ ${output} != *'<none>'* ]]
  [[ ${output} == *$'\033[38;5;255m5.14.0-687.39.1.el9_8.x86_64\033[0m'* ]]
  [[ ${output} == *$'\033[38;5;244m6.1.0-101.el9.x86_64\033[0m'* ]]
  [[ ${output} != *$'\033[36m169.117.254.98'* ]]
  [[ ${output} != *$'\033[36m169.117.254.99'* ]]
  [[ ${output} != *$'\033[36m169.117.254.100'* ]]

  run env KUBECOLOR_KUBECTL="${kubectl}" KUBECOLOR_FORCE_COLORS=1 \
    "${JSH_ROOT}/bin/kubecolor" get nodes --watch -o wide
  [[ ${status} -eq 0 ]]
  [[ ${output} == *'node-old'* ]]
}

@test "abbreviates roles and colors control-plane roles orange" {
  local kubectl="${BATS_TEST_TMPDIR}/kubectl-roles"
  local stripped role_line gateway_line
  cat > "${kubectl}" <<'EOF'
#!/bin/sh
printf '%-12s %-10s %-50s %s\n' NAME STATUS ROLES AGE
printf '%-12s %-10s %-50s %s\n' control Ready 'control-plane,master' 10d
printf '%-12s %-10s %-50s %s\n' gateways Pending 'ingress,egress-gateway,egress-gateway-pci,node' 1h
EOF
  chmod +x "${kubectl}"

  unset NO_COLOR
  run env KUBECOLOR_KUBECTL="${kubectl}" KUBECOLOR_FORCE_COLORS=1 \
    "${JSH_ROOT}/bin/kubecolor" get nodes

  [[ ${status} -eq 0 ]]
  [[ ${output} == *$'\033[38;5;208mcp\033[0m,'$'\033[38;5;208mmaster\033[0m'* ]]
  [[ ${output} == *$'\033[93mPending\033[0m'* ]]
  [[ ${output} == *$'\033[95ming\033[0m,'* ]]
  [[ ${output} == *$'\033[96megw\033[0m,'* ]]
  [[ ${output} == *$'\033[94megwpci\033[0m'* || ${output} == *$'\033[95megwpci\033[0m'* || ${output} == *$'\033[96megwpci\033[0m'* ]]
  [[ ${output} == *$'\033[92mnode\033[0m'* ]]
  [[ ${output} != *'control-plane'* ]]
  [[ ${output} != *'egress-gateway'* ]]

  stripped=$(printf '%s\n' "${output}" | sed "s/$(printf '\033')\\[[0-9;]*m//g")
  role_line=$(printf '%s\n' "${stripped}" | awk '$1 == "control" { print; exit }')
  gateway_line=$(printf '%s\n' "${stripped}" | awk '$1 == "gateways" { print; exit }')
  [[ ${role_line:75:3} == "10d" ]]
  [[ ${gateway_line:75:2} == "1h" ]]
}
