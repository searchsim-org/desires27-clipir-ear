"""Intents, context and prompts for the Mac tier — the same rule table and templates as the phone
(Sources/EarCore/Assets), HANDOVER §8, with Mac-tier budgets (6,000 tokens, ≤ 140 words)."""

import json
import re

from . import config

_TABLE = json.loads((config.ASSETS / "intents.en.json").read_text())
_RULES = [(r["intent"], [re.compile(p, re.I) for p in r["patterns"]]) for r in _TABLE["rules"]]
WINDOWS = {"explainLast": 60, "expand": 180, "summarizeWindow": 120, "whoSaid": 300}
TEMPLATE_FOR = {
    "explainLast": "explainLast",
    "expand": "expand",
    "summarizeWindow": "summarizeWindow",
    "whoSaid": "whoSaid",
}


def detect(question: str) -> str:
    for intent, pats in _RULES:
        if any(p.search(question) for p in pats):
            return intent
    return "freeform"


ACTION_INTENTS = {"noteThis", "remindMe", "searchWeb"}
_ACTION_PHRASES = re.compile(
    r"\b(calendar|schedule|book a meeting)\b|\bpin (this|that|the last \w+ minutes?)", re.I
)


def is_action(question: str, intent: str) -> bool:
    """Actions are approved and executed on the phone (ADR-018); the Mac only flags them with answer.action."""
    return intent in ACTION_INTENTS or bool(_ACTION_PHRASES.search(question))


def minutes(question: str) -> int | None:
    m = re.search(r"(\d+|[a-z]+) minutes?", question.lower())
    if not m:
        return None
    w = m.group(1)
    return int(w) if w.isdigit() else _TABLE["numbers"].get(w)


def tokens(s: str) -> int:
    return (len(s) + 3) // 4


def assemble(
    question: str,
    intent: str,
    segments: list[dict],
    search_hits: list[dict],
    at: float | None,
    budget: int = 6000,
):
    """Window from `segments` (phone-sent, else Mac store), retrieval from FTS hits outside it, trimmed to budget."""
    w = WINDOWS.get(intent, 60)
    n = minutes(question) if intent == "summarizeWindow" else None
    if n:
        w = n * 60
    end = at if at is not None else max((s["t1"] for s in segments), default=0)
    window = [s for s in segments if s["t1"] > end - w and s["t0"] <= end]
    while len(window) > 1 and tokens("\n".join(s["text"] for s in window)) > 1200:
        window.pop(0)
    in_window = {(round(s["t0"], 2), s["text"]) for s in window}
    retrieved = [] if intent == "explainLast" else [
        h for h in search_hits if (round(h["t0"], 2), h["text"]) not in in_window and h["t0"] <= end
    ][:5]  # fmt: skip
    while 300 + tokens("\n".join(s["text"] for s in window + retrieved)) > budget and retrieved:
        retrieved.pop(0)
    return {"window": window, "retrieved": retrieved, "window_seconds": w, "minutes": n}


def _template(name: str) -> str:
    return (config.ASSETS / "Prompts" / f"{name}.txt").read_text()


def prompts(question: str, intent: str, ctx: dict, notes: list[str]) -> tuple[str, str]:
    system = (
        _template("system")
        .replace("{locale_language}", "English")
        .replace("{max_words}", "140")
        .strip()
    )

    def lines(segs):
        return (
            "\n".join(f"[{s.get('speaker', 'unknown')}] {s['text']}" for s in segs) or "(nothing)"
        )

    user = (
        _template(TEMPLATE_FOR.get(intent, "freeform"))
        .replace("{W}", str(int(ctx["window_seconds"])))
        .replace("{N}", str(ctx["minutes"] or int(ctx["window_seconds"] // 60)))
        .replace("{window}", lines(ctx["window"]))
        .replace("{retrieved}", lines(ctx["retrieved"]))
        .replace("{notes}", "\n".join(notes) or "(none)")
        .replace("{question}", question)
        .strip()
    )
    return system, user


def parse_source(text: str) -> tuple[str, str]:
    m = re.search(r"SOURCE:\s*([a-z]+)", text, re.I)
    if not m:
        return text.strip(), "none"
    tier = m.group(1).lower()
    return text[: m.start()].strip(), tier if tier in {
        "transcript",
        "notes",
        "general",
        "none",
    } else "none"


class SentenceSplitter:
    """Port of EarCore's SentenceSplitter: . ? ! : + space/newline, ≥ 6 words, no abbreviations, no SOURCE lines."""

    ABBREV = {"e.g.", "i.e.", "dr.", "mr.", "mrs.", "ms.", "prof.", "etc.", "vs.", "no.", "st."}

    def __init__(self, min_words: int = 6, first_clause: bool = False):
        # first_clause: the first chunk may also end at a comma (≥ min_words) so speech starts sooner (Mac tier)
        self.buf, self.min_words, self.first_clause, self.emitted = "", min_words, first_clause, 0

    def push(self, tok: str) -> list[str]:
        self.buf += tok
        out = []
        while True:
            ends = (
                r"[.?!:,](?=[ \n])"
                if self.first_clause and self.emitted == 0
                else r"[.?!:](?=[ \n])"
            )
            m = next((m for m in re.finditer(ends, self.buf)
                      if self.buf[: m.end()].split()[-1].lower() not in self.ABBREV
                      and len(self.buf[: m.end()].split()) >= self.min_words), None)  # fmt: skip
            if not m:
                return out
            s, self.buf = self._clean(self.buf[: m.end()]), self.buf[m.end() + 1 :]
            if s:
                out.append(s)
                self.emitted += 1

    def flush(self) -> str | None:
        s, self.buf = self._clean(self.buf), ""
        return s or None

    @staticmethod
    def _clean(s: str) -> str:
        i = s.upper().find("SOURCE:")
        return (s[:i] if i >= 0 else s).strip()
