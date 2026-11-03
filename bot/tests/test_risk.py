import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from indicators import atr, ema, rsi
from risk import SymbolSpec, lot_size, sl_tp_from_entry, validate_levels

GOLD = SymbolSpec(tick_size=0.01, tick_value=1.0, volume_min=0.01, volume_max=100, volume_step=0.01, digits=2)


def test_lot_size_standard_contract():
    # $1000, 1% = $10 risk, $5 SL, $100 per $1 per lot -> 0.02 lots
    assert lot_size(1000, 1, 5, GOLD) == 0.02


def test_lot_size_rounds_down():
    # $10 / ($3 * 100) = 0.0333 -> 0.03
    assert lot_size(1000, 1, 3, GOLD) == 0.03


def test_lot_size_below_minimum_returns_zero():
    assert lot_size(100, 1, 20, GOLD) == 0.0


def test_sl_tp_from_entry():
    assert sl_tp_from_entry(2650.0, "buy", 5, 2) == (2645.0, 2660.0)
    assert sl_tp_from_entry(2650.0, "sell", 5, 2) == (2655.0, 2640.0)


def test_validate_levels():
    assert validate_levels("buy", 2650, 2645, 2660, 2, 25, 1.5).ok
    assert not validate_levels("buy", 2650, 2655, 2660, 2, 25, 1.5).ok      # SL wrong side
    assert not validate_levels("sell", 2650, 2655, 2648, 2, 25, 1.5).ok     # R:R 0.4
    assert not validate_levels("buy", 2650, 2649, 2660, 2, 25, 1.5).ok      # SL too tight
    assert not validate_levels("sell", 2650, 2690, 2500, 2, 25, 1.5).ok     # SL too wide


def test_indicators():
    closes = [float(i) for i in range(1, 40)]
    assert ema(closes, 10)[-1] < closes[-1]
    assert rsi(closes) == 100.0
    assert abs(atr([c + 1 for c in closes], [c - 1 for c in closes], closes) - 2.0) < 1e-9
