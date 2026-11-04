# xauusd-pro-calculator-
it calculate the tp and sl you just enter entry price only it calculate tp and sl based risk 

## XAUUSD M1 Scalper Pro Max (MT5 EA)

An MT5 Expert Advisor for XAUUSD M1 scalping, with a **weekly profit target (default $250)**:

* 3 ATR-adaptive strategies: trend pullback, London/New York opening-range breakout, VWAP mean reversion
* Weekly target engine: closes trades and stops for the week when the target is hit, with daily pace goals
* Lot sizing that grows with equity and with profit made this week, and shrinks after losses
  (no martingale or grid), with a hard per-trade risk cap
* Daily and weekly loss limits, equity guard, spread/ATR/news filters, DST-aware sessions, Friday flat
* On-chart dashboard and a weekly "target hit" report in the Strategy Tester

Source: [`MQL5/Experts/XAUUSD_M1_ScalperProMax.mq5`](MQL5/Experts/XAUUSD_M1_ScalperProMax.mq5)
Guide (install, strategies, sizing, back-testing): [`docs/XAUUSD_M1_ScalperProMax.md`](docs/XAUUSD_M1_ScalperProMax.md)

> No EA can guarantee a weekly profit. Back-test on real ticks and run on demo first.
