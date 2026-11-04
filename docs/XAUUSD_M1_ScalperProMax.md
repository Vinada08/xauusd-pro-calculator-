# XAUUSD M1 Scalper Pro Max — MT5 Expert Advisor

File: [`MQL5/Experts/XAUUSD_M1_ScalperProMax.mq5`](../MQL5/Experts/XAUUSD_M1_ScalperProMax.mq5)

A multi-strategy XAUUSD scalper for MetaTrader 5 that works on M1. It aims for a **weekly profit target
(default $250)**, sizes trades to keep pace with that target, and **stops for the week once the target is reached**.

---

## 1. Read this first

* **No EA can guarantee $250 every week.** This EA *targets* $250: it stops when it gets there and adjusts
  lot size to keep pace. Some weeks will lose money. The weekly loss limit (default −$250) caps how much.
* Whether $250/week is realistic depends almost entirely on **account size** (see section 6). On a small
  account, $250/week means a very large % return and a high chance of blowing the account.
* **No martingale, no grid, no averaging down.** Lot size only grows from equity growth, from profit already
  banked this week, or from a limited "pace boost" that is allowed only while the week is in profit.
  After losses, lot size goes **down**.
* Back-test with **real ticks**, then run on a **demo account for at least 4 weeks** before going live.

---

## 2. Install

1. In MT5: **File → Open Data Folder → MQL5 → Experts**. Copy `XAUUSD_M1_ScalperProMax.mq5` there.
2. Press **F4** to open MetaEditor, open the file and press **F7** to compile. It should show 0 errors.
3. Open an **XAUUSD** (or `GOLD`, `XAUUSDm`, `XAUUSD.r` …) chart. M1 is recommended. The EA always
   calculates on M1, whatever chart timeframe you use.
4. Drag the EA onto the chart and tick **Allow Algo Trading**. Turn on the **Algo Trading** button in the toolbar.
5. Check the **Experts** tab. The startup line shows the broker GMT offset the EA detected and today's
   London/New York opening-range times in **server time**. Compare them with your broker's clock.

---

## 3. The three strategies

Each strategy only fires in the market regime it suits. On every closed M1 bar they are checked in this order:
breakout → pullback → VWAP. Stops and targets are based on **ATR in price**, so they scale with gold's
volatility instead of using fixed pips. This keeps the EA usable at today's much higher gold prices and
wider $ ranges.

| # | Strategy | When it trades | Entry | Stop | Target |
|---|----------|----------------|-------|------|--------|
| 1 | **Trend Pullback** | M15 EMA50/200 trend + M5 ADX ≥ 20 | Price pulls back to M1 EMA21, RSI(7) resets below 40 (above 60 for sells), then a candle closes back through EMA9 and the prior bar's high/low | Recent swing − 0.2 ATR | 1.5 R |
| 2 | **London / NY Opening-Range Breakout** | First 90 min after a 15-min opening range (London 08:00, NY 09:30 local time) | Strong-bodied M1 candle closes beyond the range + 0.15 ATR (fresh breakout only, never against the M15 trend) | Middle of the range | 1.8 R |
| 3 | **VWAP Mean Reversion** | Ranging market (M5 ADX ≤ 22) | Price ≥ 2 ATR from the daily VWAP, RSI(7) ≤ 25 / ≥ 75, rejection candle at a new swing extreme | Swing extreme − 0.3 ATR | Back to VWAP (min 0.8 R, max 2.5 R) |

Every stop is clamped to **0.8–2.5 × M1 ATR** and must be at least 3 × the spread.

### Trade management
* **Partial take profit:** 50 % closed at +1 R.
* **Break-even:** at +0.8 R the stop moves to entry + 0.1 R.
* **ATR trailing:** from +1.2 R, trails 1 × ATR behind price.
* **Time stop:** a scalp still open after 45 minutes is closed.
* **Friday:** everything is closed at 12:30 New York time, so nothing is held over the weekend.

### Filters
* Sessions: London 08:00–11:30 (London time) and New York 08:00–12:00 (New York time). UK and US
  daylight-saving changes are handled automatically. The Asian session is off by default.
* Spread ≤ $0.40 **and** ≤ 30 % of M1 ATR.
* M1 ATR between $0.50 (dead market) and $10 (news spike).
* High-impact **USD news**: no new entries 15 min before and 15 min after (uses the built-in MT5 economic calendar;
  works on live/demo only, not in the Strategy Tester).
* Max 1 position at a time, 12 trades a day, 3 min between entries, 5 min pause after a loss, stop for the day after 4 losses in a row.

---

## 4. Weekly target engine

* **Week** = Sunday 00:00 to Saturday, in server time. **Day** = server day.
* **Weekly P/L** = this EA's closed profit for the week (profit + swap + commission + fees, filtered by magic number
  and symbol) **plus** floating P/L.
* **Target hit** (≥ $250) → every position is closed and the EA is **locked until next week**. The lock is stored
  in terminal global variables, so it survives a restart.
* **Daily pace goal** = (weekly target − profit before today) ÷ trading days left, including today.
  Example: Monday goal = 250 ÷ 5 = $50. If Monday makes $20, Tuesday's goal = 230 ÷ 4 = $57.50.
  When the daily goal is hit, positions are closed and the EA stops for the day. You can turn this off.
* **Loss limits:** daily −$100 and weekly −$250 (closed + floating). When a limit is hit, positions are closed
  and trading pauses for the rest of the day or week. A separate equity guard closes everything if floating
  drawdown reaches 8 % of the balance.
* To clear a lock by hand, set `InpResetLocksOnStart = true` and re-attach the EA, or delete the
  `PMX_<magic>_<symbol>_WLOCK` / `DLOCK` global variables (press **F3**).

---

## 5. How lot size grows (and shrinks)

```
base risk   = equity × RiskPercent            (default 0.75 %)
multiplier  = 0.5   if 2+ losses in a row     (loss reduce)
            = 1.0 … 1.5 if the week is green but behind pace (pace boost)
risk        = base × multiplier + 10 % of this week's closed profit   (house money)
risk        = min(risk, 2 % of equity, room left before the daily/weekly loss limit)
lots        = risk ÷ (loss per lot at the stop + commission)
```

* **Equity compounding:** as the account grows, the same % risk gives a bigger lot.
* **House money:** part of the profit already made this week is added back, so the EA presses when it is winning.
* **Pace boost:** up to 1.5× when the week is in profit but behind schedule (for example, Wednesday with only $40 made).
  It is **never** applied while the week or the day is red.
* **Right-size near goal:** if one take-profit would already finish the weekly target, the lot is reduced to about what is
  needed. This cuts risk on the last trade of the week.
* **Hard caps:** never more than `InpMaxRiskPctCap` (2 %) of equity per trade, never more than `InpMaxLot`, and never more than the
  room left before a loss limit. Free margin is checked too.

Example with a $10,000 account and a $3.00 stop: risk 0.75 % = $75 → $75 ÷ ($300 per lot + $7 commission) ≈ **0.24 lots**.

---

## 6. Is $250/week realistic for your account?

| Account | $250 = weekly return | Suggested risk/trade | Verdict |
|--------:|--------------------:|---------------------:|---------|
| $1,000 | 25 % | — | Not realistic. Chasing it will very likely blow the account |
| $2,500 | 10 % | 1.0–1.5 % | Very aggressive, expect deep drawdowns |
| $5,000 | 5 % | 0.75–1.0 % | Aggressive, expect several losing weeks |
| $10,000 | 2.5 % | 0.5–0.75 % | Reachable in good weeks |
| $25,000+ | ≤ 1 % | 0.25–0.4 % | Comfortable, most room for bad weeks |

On a smaller account, lower `InpWeeklyTarget` (for example 2–3 % of equity) instead of raising risk.
The startup log warns you when the target is above 5 % or 10 % of equity.

### Presets

| Input | Conservative | Balanced (default) | Aggressive |
|-------|-------------:|-------------------:|-----------:|
| `InpRiskPercent` | 0.4 | 0.75 | 1.25 |
| `InpMaxRiskPctCap` | 1.0 | 2.0 | 3.0 |
| `InpPaceBoostMax` | 1.0 (off) | 1.5 | 1.75 |
| `InpHouseMoneyPct` | 5 | 10 | 20 |
| `InpDailyMaxLoss` | 1 % of equity | $100 | 3 % of equity |
| `InpWeeklyMaxLoss` | 2.5 % of equity | $250 | 6 % of equity |
| `InpMaxTradesPerDay` | 8 | 12 | 18 |
| `InpMaxOpenPositions` | 1 | 1 | 2 |

---

## 7. Back-testing and optimisation

1. **View → Strategy Tester**. Expert: `XAUUSD_M1_ScalperProMax`. Symbol: your broker's gold symbol. Period: **M1**.
2. Modelling: **Every tick based on real ticks**. M1 scalping results from "1 minute OHLC" are not reliable.
3. Dates: at least 12 months, for example 2025.01.01 → today. Use your real deposit size and leverage.
4. **Time zone:** in the tester, `GMT_AUTO` assumes a "New York close" broker (GMT+2 in winter, GMT+3 in US summer).
   Most MT5 gold brokers use this. If yours does not, choose `GMT_MANUAL` and set `InpManualGMTOffset`.
5. The journal prints one line per week in the form `WEEK <date> | P/L <amount> | TARGET HIT or target missed | target hit <n> of <m> weeks`, plus a summary at the end (hit rate, losing weeks, best and worst week).
6. For optimisation, choose **Custom max**. The score is *% of weeks that hit the target × (1 − equity drawdown %)*.
   Good inputs to optimise: `InpTrendRR`, `InpBreakoutRR`, `InpVwapDevATR`, `InpAdxTrendMin`, `InpMinSL_ATR`,
   `InpMaxSL_ATR`, `InpTrailATR`, `InpRiskPercent`.
7. Keep the last 3–6 months out of the optimisation and use them as a **forward test**, to avoid curve-fitting.
8. The news filter is not active in the tester, so back-tests include news spikes. Live, those trades are skipped.

After that, run it on a **demo account for at least 4 weeks** with the same broker you plan to use live.
Spreads, commissions and execution vary a lot between gold brokers.

---

## 8. Dashboard

| Line | Meaning |
|------|---------|
| Status | Scanning / in trade / why it is paused (session, news, cooldown, lock …) |
| Week | Closed + floating P/L against the weekly target, with a progress bar |
| Today | Today's P/L and today's pace goal |
| Floating / Trades | Open P/L, open positions, trades today, this week's wins/losses |
| Risk | Risk for the next trade (money and % of equity), current multiplier, loss streak |
| Market | Spread, M1 ATR, M5 ADX |
| Bias / VWAP | M15 trend direction and daily VWAP |
| Clock | Detected broker GMT offset and the current London / New York time. Check that these are correct |
| News | Next high-impact event |
| Last | Last signal that was taken |

---

## 9. Key inputs

| Group | Input | Default | Notes |
|-------|-------|---------|-------|
| Targets | `InpWeeklyTarget` | 250 | In account currency |
| | `InpStopOnDailyTarget` | true | Daily pace goal lock |
| | `InpDailyMaxLoss` / `InpWeeklyMaxLoss` | 100 / 250 | 0 = off |
| Sizing | `InpLotMode` | Risk % | Fixed lot / risk % / fixed money |
| | `InpRiskPercent` | 0.75 | Per trade |
| | `InpMaxRiskPctCap` | 2.0 | Hard ceiling including all boosts |
| Strategy | `InpUseTrendPullback` / `InpUseBreakout` / `InpUseVwap` | all on | Turn each one on or off |
| Direction | `InpDirection` | Both | Long only / short only |
| Filters | `InpMaxSpreadUSD` | 0.40 | In price ($ per oz), works with 2- or 3-digit quotes |
| Time | `InpGMTMode` | Auto | Auto (live) / Manual / NY-close DST |
| Costs | `InpCommissionPerLot` | 7.0 | Round-turn, used only for sizing. Set 0 if your account has no commission |

---

## Risk warning

Trading leveraged gold CFDs carries a high risk of loss. Back-test and forward-test results do not guarantee
future performance. Only trade money you can afford to lose.
