#!/usr/bin/env python3
"""
generate_PD_target.py
---------------------
Generates a synthetic PD-neuron (pyloric dilator) target trace for
trajectory-density optimization in NeuroSim.

Burst structure (period = 1000 ms, ~1 Hz):
  Phase A   0   – 680 ms   Silent / I_h ramp         : −76 → −58 mV
  Phase B   680 – 705 ms   I_T onset (sigmoid)        : −58 → −35 mV
  Phase C   705 – 875 ms   Burst : 7 Na APs on Ca plateau (~−35 mV)
  Phase D   875 – 940 ms   I_SK termination           : −33 → −78 mV
  Phase E   940 – 1000 ms  AHP stabilisation          : −78 → −76 mV

Each Na AP during burst (at 0.1 ms resolution):
  • Upstroke 0.3 ms   plateau → +28 mV
  • Peak     0.2 ms   +28 mV
  • Fall     0.7 ms   +28 → −60 mV
  • Fast AHP 0.8 ms   −60 → −62 mV
  • Recovery 2.5 ms   −62 → plateau (Ca re-depolarisation)
  ISI ≈ 24 ms  →  ~7 APs in 170 ms burst

Usage:
  python3 generate_PD_target.py
  → writes  PD_target_trace.csv  next to this script
"""

import math, csv, os

# ── Global timing ─────────────────────────────────────────────────────────────
DT        = 0.1      # ms
T_TOTAL   = 5000.0   # ms  (5 complete cycles)
PERIOD    = 1000.0   # ms

# ── Phase boundaries (ms within one cycle) ────────────────────────────────────
PH_B = 680.0   # end of silent phase / start of I_T onset
PH_C = 705.0   # end of I_T onset    / start of burst
PH_D = 875.0   # end of burst        / start of I_SK termination
PH_E = 940.0   # end of termination  / start of AHP stabilisation

# ── Silent phase ──────────────────────────────────────────────────────────────
V_AHP  = -76.0   # mV  — start of ramp / AHP floor
V_THR  = -58.0   # mV  — I_T activation threshold (end of ramp)
TAU_IH = 300.0   # ms  — time constant of I_h depolarisation

# ── Ca plateau & burst ────────────────────────────────────────────────────────
V_PLAT_INIT = -35.0  # mV  — plateau at burst onset
V_PLAT_END  = -30.0  # mV  — slight depolarisation as Ca accumulates → then SK
N_APS       = 7      # number of Na APs per burst
BURST_DUR   = PH_D - PH_C                    # ms  (= 170 ms)
ISI         = BURST_DUR / N_APS              # ms  (≈ 24.3 ms)

# ── Na AP waveform widths (ms) ────────────────────────────────────────────────
AP_RISE  = 0.3
AP_PEAK  = 0.2
AP_FALL  = 0.7
AP_AHP   = 0.8   # fast after-hyperpolarisation
AP_REC   = 2.5   # recovery back to Ca plateau

AP_WIDTH = AP_RISE + AP_PEAK + AP_FALL + AP_AHP + AP_REC   # ≈ 4.5 ms

AP_V_PEAK  =  28.0   # mV
AP_V_TROUGH = -62.0  # mV

# ── Termination & AHP ────────────────────────────────────────────────────────
V_TERM_FLOOR = -78.0  # mV  — bottom of I_SK-driven AHP


# ── Single Na AP shape ────────────────────────────────────────────────────────
def ap_voltage(ap_t: float, plateau: float) -> float:
    """Voltage during one AP; ap_t = time since AP onset (ms)."""
    if ap_t < 0:
        return plateau
    elif ap_t < AP_RISE:                          # upstroke
        frac = ap_t / AP_RISE
        return plateau + frac * (AP_V_PEAK - plateau)
    elif ap_t < AP_RISE + AP_PEAK:                # flat peak
        return AP_V_PEAK
    elif ap_t < AP_RISE + AP_PEAK + AP_FALL:      # fast repolarisation
        frac = (ap_t - AP_RISE - AP_PEAK) / AP_FALL
        return AP_V_PEAK + frac * (AP_V_TROUGH - AP_V_PEAK)
    elif ap_t < AP_RISE + AP_PEAK + AP_FALL + AP_AHP:   # fast AHP
        frac = (ap_t - AP_RISE - AP_PEAK - AP_FALL) / AP_AHP
        # slight dip below trough then comes back
        v_dip = AP_V_TROUGH - 2.0
        return AP_V_TROUGH + frac * (v_dip - AP_V_TROUGH)   # small overshoot
    elif ap_t < AP_WIDTH:                          # Ca re-depolarisation
        frac = (ap_t - AP_RISE - AP_PEAK - AP_FALL - AP_AHP) / AP_REC
        v_dip = AP_V_TROUGH - 2.0
        # sigmoid re-depolarisation toward plateau
        s = 1.0 / (1.0 + math.exp(-8.0 * (frac - 0.5)))
        return v_dip + s * (plateau - v_dip)
    else:
        return plateau


# ── Full cycle voltage ────────────────────────────────────────────────────────
def voltage_at_phase(tp: float) -> float:
    """V(mV) for time tp ∈ [0, PERIOD) ms within one cycle."""

    # ── A: Silent phase — I_h exponential ramp ────────────────────────────────
    if tp < PH_B:
        return V_AHP + (V_THR - V_AHP) * (1.0 - math.exp(-tp / TAU_IH))

    # ── B: I_T onset — sigmoid depolarisation ─────────────────────────────────
    if tp < PH_C:
        frac = (tp - PH_B) / (PH_C - PH_B)
        sig  = 1.0 / (1.0 + math.exp(-10.0 * (frac - 0.5)))
        return V_THR + (V_PLAT_INIT - V_THR) * sig

    # ── C: Burst — 7 Na APs riding on Ca plateau ──────────────────────────────
    if tp < PH_D:
        tb = tp - PH_C                             # time within burst (0 … 170)
        frac_burst = tb / BURST_DUR

        # Ca plateau: starts at V_PLAT_INIT, slowly rises as [Ca] loads SK
        # then snaps down in the last 15 % as I_SK overwhelms I_T
        if frac_burst < 0.80:
            plateau = V_PLAT_INIT + (V_PLAT_END - V_PLAT_INIT) * (frac_burst / 0.80)
        else:
            collapse = (frac_burst - 0.80) / 0.20
            plateau = V_PLAT_END + (V_PLAT_INIT - 8.0 - V_PLAT_END) * collapse

        # Which AP are we in?
        ap_idx   = int(tb / ISI)
        t_in_ap  = tb - ap_idx * ISI             # time since this AP onset

        return ap_voltage(t_in_ap, plateau)

    # ── D: I_SK termination — exponential drop ────────────────────────────────
    if tp < PH_E:
        frac = (tp - PH_D) / (PH_E - PH_D)
        v_start = V_PLAT_INIT - 8.0              # ≈ −43 mV — where burst ended
        return v_start + (V_TERM_FLOOR - v_start) * (1.0 - math.exp(-5.0 * frac))

    # ── E: AHP stabilisation ──────────────────────────────────────────────────
    frac = (tp - PH_E) / (PERIOD - PH_E)
    return V_TERM_FLOOR + (V_AHP - V_TERM_FLOOR) * (1.0 - math.exp(-4.0 * frac))


# ── Generate & write CSV ──────────────────────────────────────────────────────
def main():
    n  = int(T_TOTAL / DT)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "PD_target_trace.csv")

    print(f"Generating {n:,} points  (dt={DT} ms, T={T_TOTAL} ms)")
    print(f"Period={PERIOD} ms  →  {1000/PERIOD:.1f} Hz  |  {N_APS} APs/burst  |  ISI≈{ISI:.1f} ms")

    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["t_ms", "V_mV"])
        for i in range(n):
            t_ms = round(i * DT, 1)
            tp   = t_ms % PERIOD
            v    = voltage_at_phase(tp)
            w.writerow([f"{t_ms:.1f}", f"{v:.4f}"])

    print(f"\n→ {out}")
    print(f"  V range : {V_TERM_FLOOR:.0f} – {AP_V_PEAK:.0f} mV")
    print(f"  Mean rate: {N_APS * 1000/PERIOD:.0f} Hz   |   Burst rate: {N_APS/BURST_DUR*1000:.0f} Hz in-burst")


if __name__ == "__main__":
    main()
