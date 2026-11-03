"""Settings loaded from environment variables / .env file."""
from __future__ import annotations

import os
from dataclasses import dataclass

try:
    from dotenv import load_dotenv

    load_dotenv()
except ImportError:  # dotenv is optional
    pass


def _bool(name: str, default: bool) -> bool:
    return os.getenv(name, str(default)).strip().lower() in {"1", "true", "yes", "y", "on"}


def _float(name: str, default: float) -> float:
    raw = os.getenv(name, "").split("#")[0].strip()
    return float(raw) if raw else default


def _int(name: str, default: int) -> int:
    raw = os.getenv(name, "").split("#")[0].strip()
    return int(raw) if raw else default


def _str(name: str, default: str = "") -> str:
    return os.getenv(name, default).split("#")[0].strip() or default


@dataclass(frozen=True)
class Settings:
    symbol: str = _str("SYMBOL", "XAUUSD")
    timeframe: str = _str("TIMEFRAME", "M15").upper()
    risk_percent: float = _float("RISK_PERCENT", 1.0)
    min_rr: float = _float("MIN_RR", 1.5)
    min_sl_dollars: float = _float("MIN_SL_DOLLARS", 2.0)
    max_sl_dollars: float = _float("MAX_SL_DOLLARS", 25.0)
    max_spread_dollars: float = _float("MAX_SPREAD_DOLLARS", 0.60)
    min_confidence: float = _float("MIN_CONFIDENCE", 0.65)
    max_open_positions: int = _int("MAX_OPEN_POSITIONS", 1)
    max_daily_loss_percent: float = _float("MAX_DAILY_LOSS_PERCENT", 3.0)
    check_every_seconds: int = _int("CHECK_EVERY_SECONDS", 60)
    magic_number: int = _int("MAGIC_NUMBER", 880808)

    allow_live_account: bool = _bool("ALLOW_LIVE_ACCOUNT", False)
    auto_confirm: bool = _bool("AUTO_CONFIRM", False)
    dry_run: bool = _bool("DRY_RUN", False)

    claude_model: str = _str("CLAUDE_MODEL", "claude-opus-5-5")
    claude_effort: str = _str("CLAUDE_EFFORT", "medium")

    mt5_login: str = _str("MT5_LOGIN")
    mt5_password: str = _str("MT5_PASSWORD")
    mt5_server: str = _str("MT5_SERVER")
    mt5_terminal_path: str = _str("MT5_TERMINAL_PATH")


SETTINGS = Settings()
