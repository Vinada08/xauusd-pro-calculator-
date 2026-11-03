# xauusd-pro-calculator-
it calculate the tp and sl you just enter entry price only it calculate tp and sl based risk

---

# XAUUSD Liquidity Swing EA (MetaTrader 5)

File: [`MQL5/Experts/XAUUSD_Liquidity_Swing_EA.mq5`](MQL5/Experts/XAUUSD_Liquidity_Swing_EA.mq5)

A swing-trading Expert Advisor for **XAUUSD (Gold)** that follows this rule set:

| Step | Timeframe | What the EA does |
|------|-----------|------------------|
| 1 | **D1** | Reads the liquidity of **Friday** (previous week), **Monday** and **Tuesday**. The highest high of the 3 days becomes the **SELL zone**, the lowest low the **BUY zone**. |
| 2 | **D1** | Maps the **Tuesday candle in YELLOW** and draws its **50% (centre) line** – this is the **partial take profit (TP1)**. |
| 3 | **H4** | Finds **order blocks** inside the zones: bearish OB (last up candle before a bearish displacement) in the SELL zone, bullish OB (last down candle before a bullish displacement) in the BUY zone. Entries are taken at the **order blocks and directly at the D1 zones**. |
| 4 | **M5** | Maps the H4 order block on the M5 chart and waits for a **rejection / wick candle** (pin bar or engulfing) **plus an M5 ChoCH** (structure break) after the OB tap. |
| 5 | Filters | **High-impact news** pause, **London / New York session** only, **HTF trend** (D1/W1) must agree with the trade direction. |
| 6 | Entry | Every setup opens **2 trades** with the same stop loss: **Trade 1 → TP1 = Tuesday 50%** (partial), **Trade 2 → ATR trailing stop after TP1** (or the fixed 1:2 target). Up to **5 setups per week**, and trading stops for the week once the **$250 weekly profit target** is reached. |
| 7 | Days | New entries **only on Wednesday, Thursday and Friday**. |
| 8 | Exit | Trades are **never closed early** – they run until TP / SL / trailing stop, or until the **weekly close on Saturday 04:30**. |
| 9 | Reports | **Telegram bot**: zones, order blocks, entries, news pauses, TP1 / trailing / SL, weekly close, daily + weekly reports, `/commands`. |

## Version 2.10 – weekly limits and D1 zone entries

* **Up to 5 setups per week** (`Max setups per week`, default 5). Each setup is still 2 trades (TP1 partial + TP2 / trailing), and only one setup is open at a time.
* **Weekly profit target $250** (`Weekly profit target`, account currency, 0 = off). The week's result is the closed profit plus the floating P/L of the open trades (`Count open trades' floating P/L`). When it reaches the target the EA **closes the open trades** (`Close open trades when the target is reached`) and takes **no new trades until next Monday**. The state survives an EA / MT5 restart. Telegram: "WEEKLY PROFIT TARGET REACHED"; the panel, `/status`, daily and weekly reports show the progress (e.g. `+120.00 / 250.00 USD`).
* **Entries at the H4 order block AND at the D1 zone** (`Where to take entries`: order blocks + D1 zones (default) / order blocks only / D1 zones only). A D1 zone entry needs the same M5 confirmation (rejection candle + ChoCH) and the same filters (trend, session, news), but no H4 order block. Its stop loss goes beyond the M5 tap high / low (`D1 zone entries: SL`), the TP1 / TP2 rules are unchanged, and at most 2 zone entries per side are taken per week (`max per zone side per week`). When an M5 candle closes beyond a zone (including its sweep allowance) the zone is marked **BROKEN** (grey) and no more zone entries are taken on that side that week. Order blocks are checked first, so a signal at an OB inside the zone is taken as an OB trade.

## Version 2.00 – new filters and trade management

### 1. High-impact news filter
* Reads the **MT5 economic calendar** (built into every MT5 terminal) for the currencies in `News currencies` (default `USD` – NFP, CPI, FOMC, PCE, GDP, Fed speakers …).
* **No new entries 30 minutes before and 30 minutes after** each high-impact event (`Pause minutes BEFORE / AFTER`). Optionally include medium-impact events or only events whose name contains your keywords (e.g. `Nonfarm,CPI,FOMC,Interest Rate`).
* Open trades are not touched – they keep their SL / TP.
* **Strategy Tester**: MetaTrader does not provide the calendar in the tester, so the EA uses an **NFP rule** (first Friday, 08:30 New York, DST-aware) plus your own list in `Extra news` (`2026.11.06 15:30;2026.11.12 15:30`, server time).
* Telegram: a **NEWS PAUSE** alert when a pause starts on a trading day, upcoming news in the zones message and daily report, and the `/news` command.

### 2. Market session filter
* Entries only during the **London** (08:00–17:00 London time) and **New York** (08:00–17:00 New York time) sessions. The Asian session (Tokyo) is off by default.
* Hours are in **local exchange time** with automatic UK / US summer-time handling, so the filter stays correct all year whatever your broker's clock is.

### 3. HTF trend filter
* `Trend filter mode`: **Moving average** (default: D1 EMA 50 – price above a rising EMA = UP, below a falling EMA = DOWN), **Market structure** (higher highs + higher lows = UP, lower highs + lower lows = DOWN, a close through the last swing = break of structure), or **both must agree**.
* SELL setups only when the trend is DOWN, BUY setups only when it is UP. A neutral / mixed trend blocks entries (`No trades when the trend is neutral`).
* Timeframe selectable: **D1 or W1**.

### 4. ATR trailing stop (TP2 trade)
* `TP2 trade exit`:
  * **ATR trailing stop after TP1** (default) – trade 2 has no fixed target. When TP1 (Tuesday 50%) is hit, trade 2 goes to breakeven and then the stop follows price at **2 x H1 ATR(14)**. The stop only ever moves in your favour, in steps of at least $1.
  * **1:RR target + ATR trailing** – keeps the 1:2 target but also trails after TP1.
  * **Fixed 1:RR** – the original behaviour.
* Optional far safety target for the trailing trade (`optional far TP in R`, 0 = none). The weekly close still applies.

### 5. M5 ChoCH / structure-break confirmation
* After price taps the H4 order block, the EA finds the **last M5 swing low (for sells) / swing high (for buys) formed before the tap** and waits for an M5 candle to **close through it** – the Change of Character.
* `Entry confirmation`: **Rejection candle + ChoCH** (default, strictest), **ChoCH only**, or **Rejection candle only** (v1 behaviour).
* Only the first break after the tap counts, it must happen within `max M5 bars from OB touch to the break` (default 48 bars = 4 hours), and the stop loss goes beyond the order block (or beyond the tap high / low in the tighter SL mode).

### How it looks on the chart

* Dark red box: **SELL zone** (Fri/Mon/Tue liquidity high), dark green box: **BUY zone** (liquidity low)
* Dotted lines: Friday / Monday / Tuesday highs and lows, solid lines: the liquidity high / low
* **Yellow box: the Tuesday D1 candle**, **yellow line: Tuesday 50% = TP1 partial**
* Orange box: H4 bearish OB, blue box: H4 bullish OB (grey = mitigated or already traded)
* Arrow: the M5 rejection candle that triggered the entry
* Info panel (top-left): zones, Tuesday 50%, active OBs, setups this week, P/L, weekly close time, status

---

## Installation

1. In MetaTrader 5 open **File → Open Data Folder**, go to `MQL5/Experts/` and copy `XAUUSD_Liquidity_Swing_EA.mq5` there.
2. Open it in **MetaEditor** and press **F7 (Compile)**.
3. Open an **XAUUSD M5** chart (M5 is recommended so you see the mapped H4 order blocks; the EA works on any chart timeframe).
4. Drag the EA onto the chart, tick **Allow Algo Trading**, and turn on the **Algo Trading** button in the toolbar.
5. A **hedging** account is recommended (2 separate trades per setup). On a **netting** account the EA opens one position and closes the TP1 part itself at the Tuesday 50% line.

## Telegram report bot setup

1. In Telegram talk to **@BotFather** → `/newbot` → copy the **bot token**.
2. Send any message to your new bot, then get your **chat id** (for example from **@userinfobot**, or open `https://api.telegram.org/bot<TOKEN>/getUpdates` in a browser and read `"chat":{"id":...}`). Group / channel ids start with `-100...` (add the bot to the group / as channel admin).
3. In MT5: **Tools → Options → Expert Advisors → Allow WebRequest for listed URL** and add `https://api.telegram.org`.
4. EA inputs: `Enable Telegram reports = true`, paste the **token** and **chat id**.

What the bot sends:

* EA start message
* **Wednesday**: the weekly D1 liquidity map (Fri/Mon/Tue H/L, sell + buy zones, Tuesday 50% TP1, H4 OBs) with a chart screenshot
* New H4 order block mapped in a zone
* **Setup opened**: direction, M5 signal, H4 OB, entry, SL, TP1 (Tuesday 50%), TP2 (1:2), lots, risk in money and %, plus a screenshot
* **News pause** started (event name and time)
* TP1 hit, runner moved to breakeven, **trailing stop active**, trailing stop hit, TP2 hit, SL hit, weekly close – each with the result and the balance
* `/status` also shows the session, news and HTF-trend filter state
* **Daily report** (Mon–Fri, at the time you set) and **weekly report** after the weekly close

Commands (only answered in the configured chat):

| Command | Reply |
|---------|-------|
| `/status` | EA status, open trades, floating P/L, balance / equity, weekly close time |
| `/zones` | D1 zones, Tuesday 50% TP1, list of H4 order blocks |
| `/report` | Today + this week results |
| `/news` | Upcoming high-impact news (next 48h) and whether entries are paused |
| `/chart` | Chart screenshot |
| `/help` | Command list |

> Use one bot token per running EA if you enable commands on several charts (Telegram delivers each update only once).

---

## Weekly close – "Saturday 04:30"

Gold stops trading on Friday night, so on most brokers **Saturday 04:30 is already after the market close** and a close order would be rejected. The EA therefore closes at whichever comes first:

* **Saturday 04:30** (in broker server time, or in *your local time* if you choose `My local time` and set your GMT offset – e.g. `5.5` for Sri Lanka / India), or
* **N minutes before the Friday market close** (`If Saturday close is after market close: close N min before Friday close`, default 15 min – read from the broker's trading sessions).

So a trade opened on Wednesday is held through Thursday and Friday until TP / SL or this final weekly close – it is never carried over the weekend. Any trade that is somehow still open in a new week is closed immediately (`Close trades left over from a previous week`).

## Partial TP (TP1) rules

* TP1 = **Tuesday D1 50%** when it lies **between the entry and TP2** and at least `Tuesday 50% must be at least this R away` (default 0.5R) from the entry.
* Otherwise (for example price already passed the Tuesday 50%, or it is further than 1:2) TP1 falls back to `TP1 at this R` (default **1R**) – the setup still has a partial and a full target.
* After TP1 is hit the TP2 trade can be moved to **breakeven** (`Move the TP2 trade to breakeven when TP1 is hit`, default ON – set it to `false` if you want the original stop loss to stay). In ATR-trailing mode the trailing stop then takes over.

## Main inputs

| Group | Input | Default | Meaning |
|-------|-------|---------|---------|
| General | Magic number | 260611 | TP1 trade uses magic, TP2 trade uses magic+1 |
| Days | Allow Wed / Thu / Fri | true | New entries only on these days (Mon / Tue are always off) |
| Days | Friday: no new entries from this hour | 18 | Avoid entering just before the weekend close |
| Weekly close | Time zone / hour / minute | Server, 04:30 Saturday | See above |
| D1 zones | Zone depth % | 25 | Sell zone = top 25% of the Fri-Mon-Tue range, buy zone = bottom 25% |
| D1 zones | Sweep allowance | 0.35 x D1 ATR | Zone extends above the high / below the low for liquidity sweeps |
| D1 zones | Require sweep | false | Only trade after the Fri/Mon/Tue high (sell) or low (buy) was taken |
| H4 OB | Lookback / impulse bars / min displacement | 60 / 3 / 1.0 x ATR | Order block detection |
| M5 entry | Entry confirmation | Rejection + ChoCH | Or ChoCH only / rejection only |
| M5 entry | ChoCH swing strength / window / lookback | 2 / 48 / 30 bars | M5 swing detection and the max time from the OB tap to the break |
| M5 entry | Pin bar / engulfing | true / true | Rejection candle types (wick >= 50% of range, body <= 40%) |
| M5 entry | Confirmation candle | false | Rejection-only mode: wait for the next M5 candle to break the rejection candle |
| Sessions | Session filter / London / New York / Asia | on / 8-17 / 8-17 / off | Local exchange hours, DST-aware |
| News | News filter / currencies / before / after | on / USD / 30 / 30 min | High-impact pause around news |
| News | Medium impact / keywords / NFP rule / extra news | off / all / on / – | See the news section above |
| Trend | Mode / timeframe / MA | MA / D1 / EMA 50, slope 5 bars | HTF trend filter |
| Trend | Structure swing / lookback / block neutral | 3 / 150 / true | Market-structure mode settings |
| Exit | TP2 trade exit | ATR trail | ATR trail / 1:RR + trail / fixed 1:RR |
| Exit | Trailing ATR timeframe / period / multiplier / step | H1 / 14 / 2.0 / $1.00 | Trailing stop distance and minimum move |
| Risk | Lot mode / risk % | Risk 1% | Total risk of the setup, split 50 / 50 between the 2 trades |
| Risk | Max risk % cap | 3% | Skips the setup if min-lot rounding would risk more |
| Risk | Reward:risk | 2.0 | TP2 |
| Risk | SL placement | Beyond H4 OB | Or beyond the M5 rejection candle |
| Risk | SL buffer / min / max | 0.50 / 3 / 40 ($) | Price distances in dollars |
| Risk | Max spread | 0.80 ($) | No entry when the spread is wider |
| Risk | Max setups per week | 5 | Each setup = 2 trades (partial + full) |
| Weekly target | Profit target / count floating / close trades | 250 / true / true | Stop for the week at +250 (account currency) |
| Entries | Where to take entries | OB + D1 zones | Or order blocks only / D1 zones only |
| Entries | Zone SL / max zone entries per side | Beyond M5 tap / 2 | D1 zone entry settings |

## Backtesting

* Strategy Tester → XAUUSD, **M5**, model **Every tick based on real ticks** (or Every tick), at least a few months.
* In the tester the broker GMT offset can't be detected – set `Tester: broker GMT offset in winter` (usually 2) and keep `Tester: broker adds +1h during US summer time` on for the common GMT+2 / GMT+3 brokers. This keeps the session filter, the NFP rule and the local-time weekly close correct in the tester.
* The MT5 economic calendar is **not available in the tester**: the news filter uses the NFP rule plus the `Extra news` list there. Live trading uses the full calendar.
* Telegram is not available in the tester (MetaTrader blocks WebRequest there); the messages are printed in the journal instead when Telegram is enabled.
* Use **visual mode** to see the zones, the yellow Tuesday candle / 50% line and the order blocks being drawn.

## Disclaimer

Trading gold with leverage carries a high level of risk. This EA is provided as-is with no guarantee of profit. Always test on a demo account and in the Strategy Tester before using real money.
