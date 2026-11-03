"""Stand-alone calculator: entry price -> SL, TP and lot size.

Example:
    python calculator.py --entry 2650.50 --side buy --balance 1000 --risk 1 --sl 5 --rr 2
"""
import argparse

from risk import SymbolSpec, lot_size, sl_tp_from_entry

ap = argparse.ArgumentParser(description="XAUUSD SL/TP/lot calculator")
ap.add_argument("--entry", type=float, required=True)
ap.add_argument("--side", choices=["buy", "sell"], required=True)
ap.add_argument("--balance", type=float, required=True)
ap.add_argument("--risk", type=float, default=1.0, help="risk %% of balance")
ap.add_argument("--sl", type=float, default=5.0, help="SL distance in $ (e.g. 5 = 500 points)")
ap.add_argument("--rr", type=float, default=2.0, help="reward:risk")
ap.add_argument("--contract", type=float, default=100, help="oz per lot (usually 100)")
a = ap.parse_args()

spec = SymbolSpec(tick_size=0.01, tick_value=0.01 * a.contract, volume_min=0.01,
                  volume_max=100, volume_step=0.01, digits=2)
sl, tp = sl_tp_from_entry(a.entry, a.side, a.sl, a.rr)
lots = lot_size(a.balance, a.risk, a.sl, spec)
print(f"{a.side.upper()} @ {a.entry}\n  SL  {sl}\n  TP  {tp}\n  Lot {lots}\n"
      f"  Risk  {lots * a.sl * a.contract:.2f}   Reward  {lots * a.sl * a.rr * a.contract:.2f}")
