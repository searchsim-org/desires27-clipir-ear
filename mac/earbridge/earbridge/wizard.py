"""Wizard-of-Oz console (user studies).

With `earbridge serve --wizard`, a person answers instead of the LLM: the phone's question and the last minute of
transcript appear on http://127.0.0.1:<port>/wizard (localhost only); the wizard clicks a prepared answer or types one;
earbridge speaks it in the same voice, never earlier than `delay` seconds after the question ended.
"""

import asyncio
import json
import time
from html import escape


class Desk:
    def __init__(self, delay: float = 0.0, bank: list[str] | None = None):
        self.delay, self.bank = delay, bank or []
        self.pending: dict[str, dict] = {}

    def open(self, qid: str, question: str, context: str) -> asyncio.Future:
        fut = asyncio.get_running_loop().create_future()
        self.pending[qid] = {
            "question": question,
            "context": context,
            "since": time.time(),
            "future": fut,
        }
        return fut

    def answer(self, qid: str, text: str) -> bool:
        p = self.pending.pop(qid, None)
        if not p or p["future"].done() or not text.strip():
            return False
        p["future"].set_result(text.strip())  # the HTTP hook runs on the server's event loop
        return True

    def state(self) -> dict:
        return {"delay": self.delay, "bank": self.bank,
                "pending": [{"query_id": q, "question": p["question"], "context": p["context"],
                             "waiting": round(time.time() - p["since"], 1)} for q, p in self.pending.items()]}  # fmt: skip


async def stream(desk: Desk, qid: str, question: str, context: str, started: float, cancel):
    """Yields the wizard's answer once (like a one-token LLM stream), after the enforced delay."""
    fut = desk.open(qid, question, context)
    while not fut.done():
        if cancel.is_set():
            desk.pending.pop(qid, None)
            return
        await asyncio.sleep(0.05)
    if (wait := started + desk.delay - time.monotonic()) > 0:
        await asyncio.sleep(wait)
    yield fut.result() + "\nSOURCE: transcript"


def load_bank(path: str | None) -> list[str]:
    """A JSON list of prepared answers (from Study A), or none."""
    return json.loads(open(path).read()) if path else []


PAGE = """<!doctype html><meta charset=utf-8><title>Wizard</title>
<style>body{font:16px system-ui;margin:24px;max-width:900px}textarea{width:100%;height:5em}.q{border:1px solid #888;
padding:12px;margin:12px 0;border-radius:8px}.ctx{color:#555;font-size:14px;white-space:pre-wrap}button{margin:4px}</style>
<h1>Wizard console</h1><p>Delay enforced: <b id=d></b> s. Answers are spoken in the assistant's voice.</p><div id=qs></div>
<script>
let bank=[];
async function tick(){const s=await (await fetch('/wizard/state')).json();document.getElementById('d').textContent=s.delay;
bank=s.bank;const box=document.getElementById('qs');const ids=s.pending.map(p=>p.query_id).join();
if(box.dataset.ids===ids)return;box.dataset.ids=ids;box.innerHTML='';
for(const p of s.pending){const div=document.createElement('div');div.className='q';
div.innerHTML=`<b>${esc(p.question)}</b><div class=ctx>${esc(p.context)}</div><textarea></textarea><br>`;
const ta=div.querySelector('textarea');for(const b of bank){const k=document.createElement('button');k.textContent=b.slice(0,60);
k.onclick=()=>ta.value=b;div.append(k)}const send=document.createElement('button');send.textContent='Speak answer';
send.onclick=async()=>{await fetch('/wizard/answer?qid='+encodeURIComponent(p.query_id)+'&text='+encodeURIComponent(ta.value));tick()};
div.append(document.createElement('br'),send);box.append(div);ta.focus()}}
function esc(t){const e=document.createElement('span');e.textContent=t;return e.innerHTML}
setInterval(tick,300);tick();
</script>"""


def page() -> str:
    return PAGE


__all__ = ["Desk", "stream", "load_bank", "page", "escape"]
