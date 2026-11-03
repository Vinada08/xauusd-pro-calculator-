"""Position sizing and trade validation - the 'pro calculator' logic.

Everything here is pure Python so it can be unit-tested without MT5.
"""
from __future__ import annotations

import math
from dataclasses import dataclass


@dataclass(frozen=True)
class SymbolSpec:
    """The parts of MT5's symbol_info that sizing needs."""

    tick_size: float      # smallest price step, e.g. 0.01
    tick_value: float     # account-currency value of one tick for 1.0 lot
    volume_min: float     # e.g. 0.01
    volume_max: float     # e.g. 100
    volume_step: float    # e.g. 0.01
    digits: int           # price decimals, e.g. 2


def money_per_dollar_move(spec: SymbolSpec) -> float:
    """Account money gained/lost per 1.00 move in price, for 1.0 lot.

    For a standard 100 oz XAUUSD contract this is 100.
    """
    return spec.tick_value / spec.tick_size


def lot_size(balance: float, risk_percent: float, sl_distance: float, spec: SymbolSpec) -> float:
    """Lots so that hitting SL loses `risk_percent` of `balance` (rounded DOWN)."""
    if balance <= 0 or risk_percent <= 0 or sl_distance <= 0:
        return 0.0
    risk_money = balance * risk_percent / 100.0
    raw = risk_money / (sl_distance * money_per_dollar_move(spec))
    steps = math.floor(raw / spec.volume_step + 1e-9)
    lots = round(steps * spec.volume_step, 8)
    if lots < spec.volume_min:
        return 0.0  # can't trade this small without exceeding risk
    return min(lots, spec.volume_max)


def sl_tp_from_entry(entry: float, direction: str, sl_distance: float, rr: float, digits: int = 2):
    """Classic calculator mode: entry + SL distance + R:R -> (SL, TP)."""
    if direction == "buy":
        return round(entry - sl_distance, digits), round(entry + sl_distance * rr, digits)
    if direction == "sell":
        return round(entry + sl_distance, digits), round(entry - sl_distance * rr, digits)
    raise ValueError("direction must be 'buy' or 'sell'")


@dataclass(frozen=True)
class CheckResult:
    ok: bool
    reason: str = ""
    sl_distance: float = 0.0
    rr: float = 0.0


def validate_levels(direction: str, entry: float, sl: float, tp: float,
                    min_sl: float, max_sl: float, min_rr: float) -> CheckResult:
    """Reject SL/TP that are on the wrong side, too tight/wide, or poor R:R."""
    if direction == "buy":
        if not (sl < entry < tp):
            return CheckResult(False, f"buy needs SL < entry < TP (got {sl} / {entry} / {tp})")
        sl_d, tp_d = entry - sl, tp - entry
    elif direction == "sell":
        if not (tp < entry < sl):
            return CheckResult(False, f"sell needs TP < entry < SL (got {tp} / {entry} / {sl})")
        sl_d, tp_d = sl - entry, entry - tp
    else:
        return CheckResult(False, f"unknown direction {direction!r}")

    rr = tp_d / sl_d
    if sl_d < min_sl:
        return CheckResult(False, f"SL distance {sl_d:.2f} < minimum {min_sl}", sl_d, rr)
    if sl_d > max_sl:
        return CheckResult(False, f"SL distance {sl_d:.2f} > maximum {max_sl}", sl_d, rr)
    if rr + 1e-9 < min_rr:
        return CheckResult(False, f"R:R {rr:.2f} < minimum {min_rr}", sl_d, rr)
    return CheckResult(True, "", sl_d, rr)
