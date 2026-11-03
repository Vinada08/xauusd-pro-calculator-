"""XAUUSD Claude trading bot.

Loop: wait for a new closed candle -> build market snapshot -> ask Claude ->
apply hard risk rules -> (optionally) ask you to confirm -> send order with SL/TP.

Run:  python main.py            (normal loop)
      python main.py --once     (analyse once and exit)
"""
from __future__ import annotations

import argparse
import logging
import sys
import time

import anthropic

from analyst import Analyst
from config import SETTINGS as S
from indicators import atr, ema, rsi
from mt5_client import MT5Client, MT5Error
from risk import lot_size, validate_levels

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-7s %(message)s",
    handlers=[logging.StreamHandler(sys.stdout), logging.FileHandler("bot.log", encoding="utf-8")],
)
log = logging.getLogger("bot")


def build_snapshot(mt: MT5Client) -> dict:
    bars = mt.candles(120)
    higher = mt.candles(60, "H1") if S.timeframe != "H1" else mt.candles(60, "H4")
    closes = [b["close"] for b in bars]
    highs = [b["high"] for b in bars]
    lows = [b["low"] for b in bars]
    tick = mt.tick()
    r2 = lambda x: None if x is None else round(x, 2)  # noqa: E731
    return {
        "symbol": S.symbol,
        "timeframe": S.timeframe,
        "bid": tick.bid,
        "ask": tick.ask,
        "spread": round(tick.ask - tick.bid, 2),
        "min_reward_risk": S.min_rr,
        "sl_distance_limits": [S.min_sl_dollars, S.max_sl_dollars],
        "indicators": {
            "ema20": r2(ema(closes, 20)[-1]),
            "ema50": r2(ema(closes, 50)[-1]),
            "ema200": r2(ema(closes, 200)[-1]) if len(closes) >= 200 else None,
            "rsi14": r2(rsi(closes)),
            "atr14": r2(atr(highs, lows, closes)),
        },
        "recent_candles": bars[-60:],
        "higher_timeframe_candles": higher[-30:],
    }


def confirm(prompt: str) -> bool:
    if S.auto_confirm:
        return True
    try:
        return input(prompt + "  Place this order? [y/N]: ").strip().lower() in {"y", "yes"}
    except EOFError:
        return False


def run_cycle(mt: MT5Client, analyst: Analyst) -> None:
    acct = mt.account()

    # ---- pre-trade guards (no API call wasted if we can't trade) ----
    if len(mt.open_positions()) >= S.max_open_positions:
        log.info("Max open positions reached - skipping.")
        return
    day_pl = mt.todays_closed_profit()
    if day_pl <= -acct.balance * S.max_daily_loss_percent / 100:
        log.warning("Daily loss limit hit (%.2f). No new trades today.", day_pl)
        return
    tick = mt.tick()
    spread = tick.ask - tick.bid
    if spread > S.max_spread_dollars:
        log.info("Spread %.2f > %.2f - skipping.", spread, S.max_spread_dollars)
        return

    # ---- ask Claude ----
    snapshot = build_snapshot(mt)
    try:
        d = analyst.decide(snapshot)
    except anthropic.AuthenticationError:
        log.error("Invalid ANTHROPIC_API_KEY - check your .env")
        raise
    except (anthropic.RateLimitError, anthropic.APIConnectionError, anthropic.InternalServerError) as e:
        log.warning("Claude API temporarily unavailable: %s", e)
        return
    log.info("Claude: %s  conf=%.2f  SL=%s TP=%s | %s",
             d.action.upper(), d.confidence, d.stop_loss, d.take_profit, d.reason)

    if d.action == "wait":
        return
    if d.confidence < S.min_confidence:
        log.info("Confidence %.2f below %.2f - not trading.", d.confidence, S.min_confidence)
        return

    # ---- validate levels against the live price ----
    tick = mt.tick()
    entry = tick.ask if d.action == "buy" else tick.bid
    spec = mt.spec()
    sl, tp = round(d.stop_loss, spec.digits), round(d.take_profit, spec.digits)
    check = validate_levels(d.action, entry, sl, tp, S.min_sl_dollars, S.max_sl_dollars, S.min_rr)
    if not check.ok:
        log.info("Rejected Claude's levels: %s", check.reason)
        return

    # ---- size the position (code decides lots, never the model) ----
    lots = lot_size(acct.balance, S.risk_percent, check.sl_distance, spec)
    if lots <= 0:
        log.info("Lot size below broker minimum for %.1f%% risk - skipping.", S.risk_percent)
        return
    risk_money = lots * check.sl_distance * spec.tick_value / spec.tick_size

    summary = (f"{d.action.upper()} {lots} {S.symbol} @ ~{entry}  SL {sl}  TP {tp}  "
               f"R:R {check.rr:.2f}  risk ≈ {risk_money:.2f} {acct.currency}")
    log.info("Proposal: %s", summary)

    if S.dry_run:
        log.info("DRY_RUN - order not sent.")
        return
    if not confirm(summary):
        log.info("You declined - order not sent.")
        return

    try:
        result = mt.market_order(d.action, lots, sl, tp)
        log.info("ORDER FILLED  ticket=%s price=%s volume=%s", result.order, result.price, result.volume)
    except MT5Error as e:
        log.error("Order failed: %s", e)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--once", action="store_true", help="analyse one time and exit")
    args = ap.parse_args()

    mt = MT5Client(S)
    mt.connect()
    acct = mt.account()
    demo = mt.is_demo()
    log.info("Connected: #%s %s  balance %.2f %s  (%s)", acct.login, acct.server,
             acct.balance, acct.currency, "DEMO" if demo else "REAL")
    if not demo and not S.allow_live_account:
        log.error("This is a REAL account. Set ALLOW_LIVE_ACCOUNT=true in .env if you really mean it.")
        mt.shutdown()
        sys.exit(1)

    analyst = Analyst(S.claude_model, S.claude_effort)
    last_bar = None
    try:
        while True:
            try:
                bar_time = mt.candles(1)[-1]["time"]
                if bar_time != last_bar:
                    last_bar = bar_time
                    run_cycle(mt, analyst)
            except MT5Error as e:
                log.error("MT5 error: %s", e)
            if args.once:
                break
            time.sleep(S.check_every_seconds)
    except KeyboardInterrupt:
        log.info("Stopped by user.")
    finally:
        mt.shutdown()


if __name__ == "__main__":
    main()
