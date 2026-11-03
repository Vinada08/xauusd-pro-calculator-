"""Thin wrapper around the official MetaTrader5 Python package (Windows only)."""
from __future__ import annotations

from datetime import datetime, timezone

import MetaTrader5 as mt5

from risk import SymbolSpec

TIMEFRAMES = {
    "M1": mt5.TIMEFRAME_M1, "M5": mt5.TIMEFRAME_M5, "M15": mt5.TIMEFRAME_M15,
    "M30": mt5.TIMEFRAME_M30, "H1": mt5.TIMEFRAME_H1, "H4": mt5.TIMEFRAME_H4,
    "D1": mt5.TIMEFRAME_D1,
}


class MT5Error(RuntimeError):
    pass


class MT5Client:
    def __init__(self, settings):
        self.s = settings

    # ---------- connection ----------
    def connect(self) -> None:
        kwargs = {}
        if self.s.mt5_terminal_path:
            kwargs["path"] = self.s.mt5_terminal_path
        if self.s.mt5_login:
            kwargs.update(login=int(self.s.mt5_login), password=self.s.mt5_password,
                          server=self.s.mt5_server)
        if not mt5.initialize(**kwargs):
            raise MT5Error(f"MT5 initialize failed: {mt5.last_error()}")
        if not mt5.symbol_select(self.s.symbol, True):
            raise MT5Error(f"Symbol {self.s.symbol} not available: {mt5.last_error()}")

    def shutdown(self) -> None:
        mt5.shutdown()

    # ---------- account ----------
    def account(self):
        info = mt5.account_info()
        if info is None:
            raise MT5Error(f"account_info failed: {mt5.last_error()}")
        return info

    def is_demo(self) -> bool:
        return self.account().trade_mode == mt5.ACCOUNT_TRADE_MODE_DEMO

    # ---------- market ----------
    def spec(self) -> SymbolSpec:
        i = mt5.symbol_info(self.s.symbol)
        if i is None:
            raise MT5Error(f"symbol_info failed: {mt5.last_error()}")
        return SymbolSpec(i.trade_tick_size, i.trade_tick_value, i.volume_min,
                          i.volume_max, i.volume_step, i.digits)

    def tick(self):
        t = mt5.symbol_info_tick(self.s.symbol)
        if t is None:
            raise MT5Error(f"no tick: {mt5.last_error()}")
        return t

    def candles(self, count: int = 120, timeframe: str | None = None):
        """Closed candles only (skips the bar still forming), oldest first."""
        tf = TIMEFRAMES[timeframe or self.s.timeframe]
        rates = mt5.copy_rates_from_pos(self.s.symbol, tf, 1, count)
        if rates is None or len(rates) == 0:
            raise MT5Error(f"copy_rates failed: {mt5.last_error()}")
        return [{
            "time": datetime.fromtimestamp(int(r["time"]), tz=timezone.utc).strftime("%Y-%m-%d %H:%M"),
            "open": float(r["open"]), "high": float(r["high"]),
            "low": float(r["low"]), "close": float(r["close"]),
            "volume": int(r["tick_volume"]),
        } for r in rates]

    # ---------- positions / history ----------
    def open_positions(self):
        return [p for p in (mt5.positions_get(symbol=self.s.symbol) or ())
                if p.magic == self.s.magic_number]

    def todays_closed_profit(self) -> float:
        now = datetime.now(timezone.utc)
        start = now.replace(hour=0, minute=0, second=0, microsecond=0)
        deals = mt5.history_deals_get(start, now) or ()
        return sum(d.profit + d.swap + d.commission for d in deals
                   if d.magic == self.s.magic_number)

    # ---------- orders ----------
    def market_order(self, direction: str, lots: float, sl: float, tp: float, comment: str = "claude-bot"):
        tick = self.tick()
        is_buy = direction == "buy"
        request = {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": self.s.symbol,
            "volume": lots,
            "type": mt5.ORDER_TYPE_BUY if is_buy else mt5.ORDER_TYPE_SELL,
            "price": tick.ask if is_buy else tick.bid,
            "sl": sl,
            "tp": tp,
            "deviation": 30,  # max slippage in points
            "magic": self.s.magic_number,
            "comment": comment[:31],
            "type_time": mt5.ORDER_TIME_GTC,
        }
        # Brokers differ in which filling mode they accept - try the common ones.
        last = None
        for filling in (mt5.ORDER_FILLING_IOC, mt5.ORDER_FILLING_FOK, mt5.ORDER_FILLING_RETURN):
            request["type_filling"] = filling
            last = mt5.order_send(request)
            if last is not None and last.retcode == mt5.TRADE_RETCODE_DONE:
                return last
            if last is not None and last.retcode != mt5.TRADE_RETCODE_INVALID_FILL:
                break
        raise MT5Error(f"order_send failed: {last.retcode if last else mt5.last_error()} "
                       f"{getattr(last, 'comment', '')}")
