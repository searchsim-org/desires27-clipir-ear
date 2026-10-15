"""Paths and settings shared by earbridge modules."""

import json
import os
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
ASSETS = REPO / "Sources/EarCore/Assets"  # intents + prompts shared with the phone
SUPPORT = Path.home() / "Library/Application Support/ClipIREar"
MODELS = Path(os.environ.get("CLIPIR_EAR_MODELS", SUPPORT / "models"))
DB_PATH = SUPPORT / "ear.db"
CONFIG_PATH = SUPPORT / "earbridge.json"
EARCLI = Path(os.environ.get("EARBRIDGE_EARCLI", REPO / ".build/release/EarCLI"))
OLLAMA = os.environ.get("EARBRIDGE_OLLAMA", "http://127.0.0.1:11434")
LLM_MODEL = os.environ.get(
    "EARBRIDGE_LLM", "clipir-gemma4-e2b"
)  # ADR-017: E2B meets A3 on the M1 Pro, E4B does not
# ADR-015: GGUFs are imported into Ollama under these names (`earbridge doctor --fix`), never pulled from a registry
LLM_GGUFS = {
    "clipir-gemma4-e2b": MODELS / "llm/gemma-4-E2B-it-Q4_0.gguf",
    "clipir-gemma4-e4b": MODELS / "llm/gemma-4-E4B-it-Q4_0.gguf",
}
PORT = 9478
VERSION = "0.1.0"


def load() -> dict:
    return json.loads(CONFIG_PATH.read_text()) if CONFIG_PATH.exists() else {}


def save(cfg: dict) -> None:
    SUPPORT.mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_text(json.dumps(cfg, indent=2) + "\n")
    CONFIG_PATH.chmod(0o600)
