#!/usr/bin/env bash
set -euo pipefail

JSH_ROOT="${HOME}/.jsh"
pid_file="${XDG_RUNTIME_DIR:-/tmp}/cafe.${USER:-$(id -un)}.pid"
is_active=0

if [[ -r "${pid_file}" ]]; then
  pid=$(< "${pid_file}")
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    is_active=1
  fi
fi

if (( is_active )); then
  rm -f "${pid_file}"
  if [[ -x "${JSH_ROOT}/bin/cafe" ]]; then
    "${JSH_ROOT}/bin/cafe" --stop >/dev/null 2>&1 || true
  elif command -v cafe >/dev/null 2>&1; then
    cafe --stop >/dev/null 2>&1 || true
  fi

  xfconf-query -c xfce4-screensaver -p /saver/enabled -s true 2>/dev/null || true
  xfconf-query -c xfce4-screensaver -p /lock/enabled -s true 2>/dev/null || true
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled -s true 2>/dev/null || true
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/presentation-mode -s false 2>/dev/null || true
  DISPLAY="${DISPLAY:-:0}" xset +dpms 2>/dev/null || true
  DISPLAY="${DISPLAY:-:0}" xset s on 2>/dev/null || true
else
  if [[ -x "${JSH_ROOT}/bin/cafe" ]]; then
    "${JSH_ROOT}/bin/cafe" -b -d -s -i >/dev/null 2>&1 || true
  elif command -v cafe >/dev/null 2>&1; then
    cafe -b -d -s -i >/dev/null 2>&1 || true
  fi

  xfconf-query -c xfce4-screensaver -p /saver/enabled -s false 2>/dev/null || true
  xfconf-query -c xfce4-screensaver -p /lock/enabled -s false 2>/dev/null || true
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled -s false 2>/dev/null || true
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/presentation-mode -n -t bool -s true 2>/dev/null || true
  DISPLAY="${DISPLAY:-:0}" xset -dpms 2>/dev/null || true
  DISPLAY="${DISPLAY:-:0}" xset s off 2>/dev/null || true
  DISPLAY="${DISPLAY:-:0}" xfce4-screensaver-command -d 2>/dev/null || true
fi

for plugin_file in "${HOME}/.config/xfce4/panel"/genmon-*.rc; do
  [[ -r "${plugin_file}" ]] || continue
  if grep -q 'cafe-status.sh' "${plugin_file}" 2>/dev/null; then
    id=$(basename "${plugin_file}" .rc | sed 's/genmon-//')
    DISPLAY="${DISPLAY:-:0}" xfce4-panel --plugin-event="genmon-${id}:refresh:bool:true" 2>/dev/null || true
  fi
done
