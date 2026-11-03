# XAUUSD Claude Trading Bot (MT5)

Reads XAUUSD from your MetaTrader 5 terminal, asks Claude for a trade idea,
checks it against hard risk rules, sizes the lot from your risk %, and (after you type `y`)
sends a market order with SL and TP.

> ⚠️ Trading gold with leverage can lose more than you expect. Claude can be wrong.
> Run on a **DEMO** account first for at least a few weeks. Nothing here is financial advice.

## Requirements
- **Windows** PC or Windows VPS with **MetaTrader 5** installed and logged in
- MT5: *Tools → Options → Expert Advisors → Allow algorithmic trading* ✔, and the **Algo Trading** button ON
- Python 3.10+ (64-bit) from python.org
- An Anthropic API key with credit: https://console.anthropic.com → API Keys

## Setup
```bat
cd bot
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
copy .env.example .env
notepad .env        &:: paste your ANTHROPIC_API_KEY, check SYMBOL matches your broker
```

## Run
```bat
python main.py --once     &:: one analysis, good first test
python main.py            &:: keeps running; checks every new candle
```
Stop with `Ctrl+C`. Everything is logged to `bot.log`.

## How it decides
1. On every newly closed candle (default M15) it sends Claude the last 60 candles, 30 higher-timeframe
   candles, EMA20/50/200, RSI14, ATR14, bid/ask and spread.
2. Claude replies in strict JSON: `buy` / `sell` / `wait`, SL, TP, confidence, reason.
3. The bot **rejects** the idea if: confidence < `MIN_CONFIDENCE`, SL on the wrong side,
   SL distance outside `MIN_SL_DOLLARS`–`MAX_SL_DOLLARS`, or R:R < `MIN_RR`.
4. **Lot size is calculated by code**, never by Claude: `balance × RISK_PERCENT ÷ (SL distance × $ per $1 move per lot)`, rounded down.
5. It shows you the order and waits for `y`.

## Safety switches (`.env`)
| Setting | Default | Meaning |
|---|---|---|
| `ALLOW_LIVE_ACCOUNT` | `false` | Bot refuses to run on a real account unless `true` |
| `AUTO_CONFIRM` | `false` | `false` = you approve every order |
| `DRY_RUN` | `false` | `true` = analyse and log only |
| `MAX_OPEN_POSITIONS` | `1` | Won't stack trades |
| `MAX_DAILY_LOSS_PERCENT` | `3` | Stops opening trades after this daily loss |
| `MAX_SPREAD_DOLLARS` | `0.60` | Skips news spikes / wide spreads |

## API cost
Each analysis is one Claude call (~6–8k input tokens). On M15 that's up to ~96 calls/day
if the market is open all day — set a monthly spend limit in the Anthropic Console.
Use `TIMEFRAME=H1` or `CLAUDE_EFFORT=low` to spend less.

## Calculator only
```bat
python calculator.py --entry 2650.50 --side buy --balance 1000 --risk 1 --sl 5 --rr 2
```

## Tests
```bat
pip install pytest
python -m pytest tests
```
