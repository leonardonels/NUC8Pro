# NUC8 Pro — Performance Scripts

A `jetson_clocks`-style performance lock for the **Intel NUC 8 Pro (NUC8v7PNH)** running Ubuntu 22.04 / 24.04.

It pins the CPU and iGPU to their maximum frequency and disables deep CPU idle states, trading idle power for **low, deterministic latency** — useful when running real-time workloads (e.g. a ROS 2 stack).

| | |
|---|---|
| **Hardware** | Intel NUC 8 Pro — Core i7-8665U (4C/8T, 1.9 / 4.8 GHz, 15 W TDP), Intel UHD 620 |
| **OS** | Ubuntu 22.04 LTS, Ubuntu 24.04 LTS |
| **Requires** | `intel_pstate`, `intel_idle`, `i915` (Ubuntu defaults) |

> The script only writes standard kernel sysfs knobs and skips any that are missing, so it is safe on other Intel machines too (it also handles `amdgpu` GPUs if present).

---

## Contents

| File | Purpose |
|---|---|
| `nuc_clocks.sh` | Applies / stores / restores / shows the performance settings |
| `nuc-clocks.service` | systemd unit: applies the lock at boot, restores defaults on stop |

## What it changes

| Setting | Default (power-saving) | Locked |
|---|---|---|
| CPU governor / EPP | `powersave` / `balance_performance` | `performance` / `performance` |
| CPU min frequency | ~400 MHz | `cpuinfo_max_freq` (no down-ramp) |
| Turbo | enabled | enabled |
| CPU idle states | all enabled (up to C10) | only states with exit latency ≤ `MAX_LAT_US` (default: POLL + C1) |
| iGPU (i915) min frequency | 300 MHz | RP0 (max) |
| PCIe ASPM | `default` | `performance` |

**Why:** a task's response time is roughly

$$T = L_{\text{exit}} + T_{\text{ramp}} + \frac{N}{f}$$

- $L_{\text{exit}}$ is the wake-up time from a deep C-state: up to hundreds of µs.
- $T_{\text{ramp}}$ is the time for the frequency to rise.
- $N/f$ is the compute time: $N$ cycles at frequency $f$.

The lock drives $L_{\text{exit}}$ and $T_{\text{ramp}}$ to ≈ 0. It also runs the work at max $f$, which removes most of the **jitter** as well as lowering the mean.

---

## Installation

From the repository folder:

```bash
sudo install -m 755 nuc_clocks.sh      /usr/local/sbin/
sudo install -m 644 nuc-clocks.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now nuc-clocks.service
```

Recommended on Ubuntu 24.04: also set the power profile to performance. It persists across reboots.

```bash
powerprofilesctl set performance
```

### Verify

```bash
systemctl status nuc-clocks
sudo nuc_clocks.sh --show
```

In the `--show` output, expect:
- `scaling_governor` = `performance` on every CPU
- `scaling_min_freq` = `cpuinfo_max_freq`
- `disable` = `1` on the deep C-states (C1E, C3, C6, …)
- `gt_min_freq_mhz` = `gt_max_freq_mhz`

---

## Usage

| Goal | Command |
|---|---|
| Low latency (full lock) | `sudo systemctl start nuc-clocks` |
| Low idle power (back to PPD profile only) | `sudo systemctl stop nuc-clocks` |
| Lock at every boot | `sudo systemctl enable nuc-clocks` |
| Don't lock at boot | `sudo systemctl disable nuc-clocks` |

Manual use, without the service:

```bash
sudo nuc_clocks.sh            # apply (stores the original state on first run)
sudo nuc_clocks.sh --restore  # restore stored state
sudo nuc_clocks.sh --store    # snapshot current state
sudo nuc_clocks.sh --show     # print current settings
```

### Tuning: keep shallower C-states

`MAX_LAT_US` (in µs) sets the deepest idle state that stays enabled. A higher value means lower idle power and slightly more jitter.

| `MAX_LAT_US` | Idle states kept | Use case |
|---|---|---|
| `2` (default) | POLL, C1 | Hard latency targets |
| `20` | POLL, C1, C1E | Good compromise |

To set it permanently for the service:

```bash
sudo systemctl edit nuc-clocks
```

```ini
[Service]
Environment=MAX_LAT_US=20
```

```bash
sudo systemctl restart nuc-clocks
```

To check each state's exit latency on your machine:

```bash
grep . /sys/devices/system/cpu/cpu0/cpuidle/state*/{name,latency}
```

---

## Monitoring

### Power limits (PL1 / PL2)

On a 15 W part, sustained clocks are set by **PL1**, not by the frequency lock.

```bash
paste /sys/class/powercap/intel-rapl:0/constraint_*_name \
      <(awk '{printf "%.1f W\n", $1/1e6}' /sys/class/powercap/intel-rapl:0/constraint_*_power_limit_uw)
```

`long_term` is PL1 and `short_term` is PL2. On NUCs, both can be raised in the BIOS (Performance → Processor).

### Live frequency, power and temperature

```bash
sudo apt install linux-tools-common linux-tools-$(uname -r)   # provides turbostat
sudo turbostat --quiet --show Busy%,Bzy_MHz,PkgWatt,PkgTmp -i 1
```

Compare `PkgWatt` at idle with the service started and stopped. The difference is the idle cost of the lock.

---

## Notes

- **The lock is a request, not a guarantee.** Under sustained all-core load, the CPU still drops clocks when it hits PL1 or its thermal limit (`PkgTmp` near 100 °C). This is intended behaviour; keep `thermald` running.
- **The fan is controlled by the BIOS**, not by the OS. For sustained load, choose a cooler fan profile in the BIOS (Cooling → Fan Control Mode).
- **Stored state.** The first `apply` saves the current settings to `/var/lib/nuc_clocks/state`, and `--restore` returns to that snapshot. Never run `--store` while the lock is active, or the snapshot will hold the locked values. To re-snapshot, stop the service first, then run `sudo nuc_clocks.sh --store`.
- **power-profiles-daemon** is compatible: in `performance` it sets the same EPP value the script does. Only `tuned` conflicts with it; don't run both daemons.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `scaling_governor` stays `powersave` | `intel_pstate` is in passive mode, or another tool is overriding it. Check `cat /sys/devices/system/cpu/intel_pstate/status` and `systemctl status tuned`. |
| C-states still reached | Check whether BIOS C-state control is disabled or overridden. Alternative: kernel parameter `intel_idle.max_cstate=1` (needs a reboot to change). |
| `pcie_aspm` policy not changing | The BIOS owns ASPM on this platform. This is harmless; the script skips it. |
| Frequencies drop under load | PL1 or thermal limit reached. Check with `turbostat`. |

## Uninstall

```bash
sudo systemctl disable --now nuc-clocks.service   # also restores defaults
sudo rm /etc/systemd/system/nuc-clocks.service /usr/local/sbin/nuc_clocks.sh
sudo rm -rf /var/lib/nuc_clocks /etc/systemd/system/nuc-clocks.service.d
sudo systemctl daemon-reload
```
