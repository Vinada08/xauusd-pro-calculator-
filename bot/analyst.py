"""Asks Claude for a structured XAUUSD trade decision."""
from __future__ import annotations

import json
from dataclasses import dataclass

import anthropic

SYSTEM_PROMPT = """You are a disciplined XAUUSD (gold vs US dollar) intraday analyst.
You receive recent candles, indicators, the current bid/ask and spread.
Decide whether there is a clear, high-probability setup RIGHT NOW.

Rules:
- Default to "wait". Only propose buy/sell when trend, momentum and structure agree.
- Entry is a market order at the current ask (buy) or bid (sell).
- Place stop_loss beyond a logical swing high/low or ~1-2x ATR, never inside the spread.
- take_profit must give at least the stated minimum reward:risk.
- confidence is your honest probability (0-1) that the trade reaches TP before SL.
- Keep "reason" to 1-3 short sentences.
For "wait", set stop_loss and take_profit to 0."""

DECISION_SCHEMA = {
    "type": "object",
    "properties": {
        "action": {"type": "string", "enum": ["buy", "sell", "wait"]},
        "stop_loss": {"type": "number"},
        "take_profit": {"type": "number"},
        "confidence": {"type": "number"},
        "reason": {"type": "string"},
    },
    "required": ["action", "stop_loss", "take_profit", "confidence", "reason"],
    "additionalProperties": False,
}


@dataclass(frozen=True)
class Decision:
    action: str
    stop_loss: float
    take_profit: float
    confidence: float
    reason: str


class Analyst:
    def __init__(self, model: str, effort: str = "medium"):
        self.client = anthropic.Anthropic()  # reads ANTHROPIC_API_KEY
        self.model = model
        self.effort = effort

    def decide(self, market: dict) -> Decision:
        response = self.client.beta.messages.create(
            model=self.model,
            max_tokens=16000,
            system=SYSTEM_PROMPT,
            messages=[{
                "role": "user",
                "content": "Market snapshot (JSON):\n" + json.dumps(market, separators=(",", ":")),
            }],
            output_config={
                "effort": self.effort,
                "format": {"type": "json_schema", "schema": DECISION_SCHEMA},
            },
            # If a safety classifier declines, retry on Anthropic's recommended fallback model.
            betas=["server-side-fallback-2026-07-01"],
            fallbacks="default",
        )

        if response.stop_reason == "refusal":
            return Decision("wait", 0, 0, 0, "Claude declined this request.")
        if response.stop_reason == "max_tokens":
            return Decision("wait", 0, 0, 0, "Response was cut off (max_tokens).")

        text = next((b.text for b in response.content if b.type == "text"), "")
        data = json.loads(text)
        return Decision(
            action=data["action"],
            stop_loss=float(data["stop_loss"]),
            take_profit=float(data["take_profit"]),
            confidence=max(0.0, min(1.0, float(data["confidence"]))),
            reason=str(data["reason"]),
        )
