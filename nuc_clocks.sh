#!/usr/bin/env bash
# nuc_clocks.sh — jetson_clocks-like performance lock for Intel NUC8 (i7-8705G + Radeon Vega M)
#
# Usage (as root):
#   nuc_clocks.sh            apply max-performance (auto-stores current state on first run)
#   nuc_clocks.sh --store    save current settings
#   nuc_clocks.sh --restore  restore saved settings
#   nuc_clocks.sh --show     print current settings
#
# Env: MAX_LAT_US (default 2) -> idle states with exit latency > this are disabled
#      (2 us keeps POLL and C1 only; set e.g. 20 to also keep C1E)

set -u
STATE=/var/lib/nuc_clocks/state
PST=/sys/devices/system/cpu/intel_pstate
MAX_LAT_US=${MAX_LAT_US:-2}

[[ $EUID -eq 0 ]] || { echo "run as root (sudo)"; exit 1; }

# silent best-effort write (some knobs are absent or locked by BIOS/firmware)
wr() { [[ -w $1 ]] && echo "$2" > "$1" 2>/dev/null; return 0; }

files() {
  shopt -s nullglob
  local f
  for f in "$PST"/no_turbo "$PST"/max_perf_pct "$PST"/min_perf_pct \
           /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor \
           /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_max_freq \
           /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_min_freq \
           /sys/devices/system/cpu/cpu[0-9]*/cpufreq/energy_performance_preference \
           /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state*/disable \
           /sys/class/drm/card[0-9]/device/power_dpm_force_performance_level \
           /sys/class/drm/card[0-9]/gt_max_freq_mhz \
           /sys/class/drm/card[0-9]/gt_min_freq_mhz \
           /sys/module/pcie_aspm/parameters/policy; do
    [[ -r $f ]] && echo "$f"
  done
}

store() {
  mkdir -p "$(dirname "$STATE")"
  : > "$STATE"
  local f
  for f in $(files); do printf '%s %s\n' "$f" "$(cat "$f")" >> "$STATE"; done
  echo "state stored in $STATE"
}

restore() {
  [[ -s $STATE ]] || { echo "no stored state in $STATE"; exit 1; }
  local pass f v
  # two passes: min/max pairs and governor/EPP have write-order constraints
  for pass in 1 2; do
    while read -r f v; do
      [[ $f == *pcie_aspm* ]] && v=$(sed 's/.*\[\(.*\)\].*/\1/' <<<"$v")
      wr "$f" "$v"
    done < "$STATE"
  done
  echo "restored"
}

apply() {
  [[ -s $STATE ]] || store
  shopt -s nullglob
  local c s g d top

  # --- CPU: intel_pstate / HWP ---
  wr "$PST/no_turbo" 0
  wr "$PST/max_perf_pct" 100
  wr "$PST/min_perf_pct" 100
  for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
    wr "$c/scaling_governor" performance
    wr "$c/energy_performance_preference" performance   # EBUSY under 'performance' is fine (EPP already 0)
    top=$(cat "$c/cpuinfo_max_freq")
    wr "$c/scaling_max_freq" "$top"
    wr "$c/scaling_min_freq" "$top"                     # HWP min = max -> no down-ramp
  done

  # --- CPU idle: disable deep C-states ---
  for s in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state*; do
    if (( $(cat "$s/latency") > MAX_LAT_US )); then wr "$s/disable" 1; else wr "$s/disable" 0; fi
  done

  # --- AMD Radeon Vega M (amdgpu) ---
  for d in /sys/class/drm/card[0-9]/device; do
    wr "$d/power_dpm_force_performance_level" high
  done

  # --- Intel HD 630 (i915) ---
  for g in /sys/class/drm/card[0-9]; do
    if [[ -r $g/gt_RP0_freq_mhz ]]; then
      wr "$g/gt_max_freq_mhz" "$(cat "$g/gt_RP0_freq_mhz")"
      wr "$g/gt_min_freq_mhz" "$(cat "$g/gt_RP0_freq_mhz")"
    fi
  done

  # --- PCIe link power management ---
  wr /sys/module/pcie_aspm/parameters/policy performance

  echo "max performance applied (MAX_LAT_US=$MAX_LAT_US)"
}

show() {
  local f
  for f in $(files); do printf '%-80s %s\n' "$f" "$(cat "$f")"; done
  echo
  grep -H . /sys/devices/system/cpu/cpu0/cpuidle/state*/{name,latency} 2>/dev/null
  echo
  grep MHz /proc/cpuinfo
}

case "${1:-}" in
  --store)   store ;;
  --restore) restore ;;
  --show)    show ;;
  "")        apply ;;
  *)         echo "usage: $0 [--store|--restore|--show]"; exit 1 ;;
esac
