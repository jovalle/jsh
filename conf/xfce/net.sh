#!/usr/bin/env bash
set -euo pipefail

state_dir=/dev/shm/jsh-net
mkdir -p "${state_dir}"

iface=
if [[ -r ${state_dir}/iface ]]; then
  read -r iface <"${state_dir}/iface" 2>/dev/null || true
fi
if [[ -z ${iface} || ! -d /sys/class/net/${iface} ]]; then
  iface=$(ip route show default 2>/dev/null |
    awk '{for (index=1; index<=NF; index++) if ($index=="dev") print $(index+1); exit}')
  [[ -n ${iface} ]] || iface=$(find /sys/class/net -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null |
    grep -v -E '^(lo|docker|veth|br-)' | head -n 1)
  printf '%s\n' "${iface}" >"${state_dir}/iface"
fi

carrier=0
if [[ -n ${iface} && -r /sys/class/net/${iface}/carrier ]]; then
  read -r carrier <"/sys/class/net/${iface}/carrier" 2>/dev/null || carrier=0
elif [[ -n ${iface} && -r /sys/class/net/${iface}/operstate ]]; then
  read -r operstate <"/sys/class/net/${iface}/operstate" 2>/dev/null || operstate=down
  [[ ${operstate} == up ]] && carrier=1
fi

tick=0
[[ ! -r ${state_dir}/tick ]] || read -r tick <"${state_dir}/tick" 2>/dev/null || tick=0
tick=$(((tick + 1) % 10))
printf '%d\n' "${tick}" >"${state_dir}/tick"

now=$(date +%s)
last_check=0
[[ ! -r ${state_dir}/last_ping ]] ||
  read -r last_check <"${state_dir}/last_ping" 2>/dev/null || last_check=0
if ((now - last_check >= 3)); then
  printf '%d\n' "${now}" >"${state_dir}/last_ping"
  (
    if ping -c 1 -W 1 -n 1.1.1.1 >/dev/null 2>&1 ||
      ping -c 1 -W 1 -n 8.8.8.8 >/dev/null 2>&1; then
      printf '1\n' >"${state_dir}/online.tmp"
    else
      printf '0\n' >"${state_dir}/online.tmp"
    fi
    mv -f "${state_dir}/online.tmp" "${state_dir}/online"
  ) >/dev/null 2>&1 &
fi

online=1
[[ ! -r ${state_dir}/online ]] || read -r online <"${state_dir}/online" 2>/dev/null || online=1
rx=0 tx=0 rx_packets=0 tx_packets=0
if [[ -n ${iface} && -r /sys/class/net/${iface}/statistics/rx_bytes ]]; then
  read -r rx <"/sys/class/net/${iface}/statistics/rx_bytes" 2>/dev/null || rx=0
  read -r tx <"/sys/class/net/${iface}/statistics/tx_bytes" 2>/dev/null || tx=0
  read -r rx_packets <"/sys/class/net/${iface}/statistics/rx_packets" 2>/dev/null || rx_packets=0
  read -r tx_packets <"/sys/class/net/${iface}/statistics/tx_packets" 2>/dev/null || tx_packets=0
fi

prev_rx=0 prev_tx=0 prev_rx_packets=0 prev_tx_packets=0
state_file=${state_dir}/stats
if [[ -r ${state_file} ]]; then
  read -r prev_rx prev_tx prev_rx_packets prev_tx_packets <"${state_file}" 2>/dev/null || true
fi
printf '%s %s %s %s\n' "${rx}" "${tx}" "${rx_packets}" "${tx_packets}" >"${state_file}"
rx_delta=$((rx >= prev_rx ? rx - prev_rx : 0))
tx_delta=$((tx >= prev_tx ? tx - prev_tx : 0))
rx_activity=$((rx_packets >= prev_rx_packets ? rx_packets - prev_rx_packets : 0))
tx_activity=$((tx_packets >= prev_tx_packets ? tx_packets - prev_tx_packets : 0))
rate=$(((rx_delta + tx_delta) * 10))
if ((rate >= 1048576)); then
  rate_str=$(printf '%d.%d MB/s' "$((rate / 1048576))" "$(((rate % 1048576) * 10 / 1048576))")
elif ((rate >= 1024)); then
  rate_str=$(printf '%d.%d KB/s' "$((rate / 1024))" "$(((rate % 1024) * 10 / 1024))")
else
  rate_str="${rate} B/s"
fi

if [[ ${carrier} != 1 ]]; then
  led="<span color='#888888'>●</span>" status_str='Disconnected (no link)'
elif [[ ${online} == 0 ]]; then
  if ((tick < 5)); then led="<span color='#FFCC00' font_weight='bold'>●</span>"
  else led="<span color='#554400'>●</span>"; fi
  status_str='No Internet Access'
elif ((rx_activity > 0 || tx_activity > 0)); then
  led="<span color='#00FF66' font_weight='bold'>●</span>" status_str="Online (${rate_str})"
else
  led="<span color='#1A5226'>●</span>" status_str="Online (${rate_str})"
fi
printf '<txt>net %s&#160;</txt><tool>%s: %s (Rx: %d B, Tx: %d B)</tool><txtclick>xfce4-taskmanager</txtclick><click>xfce4-taskmanager</click>\n' \
  "${led}" "${iface:-none}" "${status_str}" "${rx_delta}" "${tx_delta}"
