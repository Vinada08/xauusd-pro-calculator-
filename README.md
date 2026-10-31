# xauusd-pro-calculator-
it calculate the tp and sl you just enter entry price only it calculate tp and sl based risk 

---

## XAUUSD H4 Trend / M30 Order Block EA (MetaTrader 5)

File: `MQL5/Experts/XAUUSD_H4Trend_M30_OrderBlock_EA.mq5`

### Strategy
1. **H4 decides the direction** (closed H4 candle):
   - Bullish → the EA looks for **BUY only**; bearish → **SELL only**; neutral → no trade.
   - Mode `InpTrendMode`: EMA 50/200 + close filter, H4 market structure (last break of structure), or **both must agree** (default).
2. **M30 entry only at the last confirmed order block**
   - Bearish OB = the last bullish M30 candle before an impulsive drop that **broke the previous M30 swing low (BOS)**, with displacement ≥ `InpMinImpulseATR` × ATR. Bullish OB is the mirror.
   - The newest such OB that is still valid (no M30 close beyond its wick) is used. With `InpFreshOBOnly` only the first retest is traded.
   - Entry on the M30 close that retests the OB and confirms (`InpConfirm`: touch / rejection past mid of OB / close back outside OB).
   - SL beyond the OB wick + buffer, TP = `InpRewardRisk` × SL distance. Optional breakeven and ATR trailing.
3. **One-day session window**
   - `InpSessionStart` (e.g. `13:00` or `02:00`) → `InpSessionClose` (`04:30`). The window can wrap past midnight.
   - New trades are only opened inside the window (and not in the last `InpNoEntryMinutesBeforeClose` minutes).
   - **Every EA trade is closed at the session close time (04:30)** — also checked by a timer, so it works with no ticks.
   - Friday protection: no new trades after `InpFridayNoEntryTime`, close all at `InpFridayCloseTime` (server time), since 04:30 Saturday does not exist.

### Times
All times use the broker **server time** (the time shown in MT5 Market Watch). If you want to enter your own local times, set `InpTimeOffsetHours` = your time − server time (e.g. server GMT+2, you GMT+7 → `5`).

### Install
1. MT5 → File → Open Data Folder → copy the `.mq5` into `MQL5/Experts/`.
2. Open it in MetaEditor and press **Compile** (F7).
3. Attach it to an **XAUUSD** chart (any timeframe – it reads H4 and M30 itself), enable Algo Trading.
4. Backtest first in the Strategy Tester ("Every tick based on real ticks") and demo trade before going live.

Point values: on most brokers XAUUSD has 2 digits, so 100 points = $1.00 price move. Adjust `InpSLBufferPoints`, `InpMinSLPoints`, `InpMaxSLPoints` and `InpMaxSpreadPoints` if your broker uses 3 digits.

> No EA guarantees profit. Use proper risk management.
