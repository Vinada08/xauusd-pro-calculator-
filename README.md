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
| 3 | **H4** | Finds **order blocks** inside the zones: bearish OB (last up candle before a bearish displacement) in the SELL zone, bullish OB (last down candle before a bullish displacement) in the BUY zone. |
| 4 | **M5** | Maps the H4 order block on the M5 chart and waits for a **rejection / wick candle** (pin bar or engulfing) at the OB. |
| 5 | Entry | Opens **exactly 2 trades** with the same stop loss: **Trade 1 → TP1 = Tuesday 50%** (partial), **Trade 2 → TP2 = 1:2 risk reward** (full). |
| 6 | Days | New entries **only on Wednesday, Thursday and Friday**. |
| 7 | Exit | Trades are **never closed early** – they run until TP / SL, or until the **weekly close on Saturday 04:30**. |
| 8 | Reports | **Telegram bot**: zones, order blocks, entries, TP1 / TP2 / SL, weekly close, daily + weekly reports, `/commands`. |

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
* TP1 hit, runner moved to breakeven, TP2 hit, SL hit, weekly close – each with the result and the balance
* **Daily report** (Mon–Fri, at the time you set) and **weekly report** after the weekly close

Commands (only answered in the configured chat):

| Command | Reply |
|---------|-------|
| `/status` | EA status, open trades, floating P/L, balance / equity, weekly close time |
| `/zones` | D1 zones, Tuesday 50% TP1, list of H4 order blocks |
| `/report` | Today + this week results |
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
* After TP1 is hit the TP2 trade can be moved to **breakeven** (`Move the TP2 trade to breakeven when TP1 is hit`, default ON – set it to `false` if you want the original stop loss to stay).

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
| M5 entry | Pin bar / engulfing | true / true | Rejection candle types (wick >= 50% of range, body <= 40%) |
| M5 entry | Confirmation candle | false | Wait for the next M5 candle to break the rejection candle |
| Risk | Lot mode / risk % | Risk 1% | Total risk of the setup, split 50 / 50 between the 2 trades |
| Risk | Max risk % cap | 3% | Skips the setup if min-lot rounding would risk more |
| Risk | Reward:risk | 2.0 | TP2 |
| Risk | SL placement | Beyond H4 OB | Or beyond the M5 rejection candle |
| Risk | SL buffer / min / max | 0.50 / 3 / 40 ($) | Price distances in dollars |
| Risk | Max spread | 0.80 ($) | No entry when the spread is wider |
| Risk | Setups per week | 1 | Each setup = 2 trades (partial + full) |

## Backtesting

* Strategy Tester → XAUUSD, **M5**, model **Every tick based on real ticks** (or Every tick), at least a few months.
* In the tester the broker GMT offset can't be detected – set `Broker GMT offset used in Strategy Tester` (usually 2 or 3) if you use the local-time weekly close.
* Telegram is not available in the tester (MetaTrader blocks WebRequest there); the messages are printed in the journal instead when Telegram is enabled.
* Use **visual mode** to see the zones, the yellow Tuesday candle / 50% line and the order blocks being drawn.

## Disclaimer

Trading gold with leverage carries a high level of risk. This EA is provided as-is with no guarantee of profit. Always test on a demo account and in the Strategy Tester before using real money.
