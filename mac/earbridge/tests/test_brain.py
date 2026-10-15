from earbridge import brain


def test_intents_share_the_phone_table():
    for q, want in [("What did the speaker just say?", "explainLast"), ("tell me more", "expand"),
                    ("Summarize the last five minutes", "summarizeWindow"), ("who proposed the budget cut", "whoSaid"),
                    ("Remind me to email Anna", "remindMe"), ("Is the exam open book?", "freeform")]:  # fmt: skip
        assert brain.detect(q) == want, q
    assert brain.minutes("what did I miss in the last two minutes") == 2


def test_sentence_splitter_matches_swift_golden():
    s, out = brain.SentenceSplitter(), []
    for tok in ["The speaker said the deadline", " moves to Friday. ", "Dr. Smith agreed, e.g. ", "on the call today. Yes. ",
                "That was all.\nSOURCE: transcript"]:  # fmt: skip
        out += s.push(tok)
    out.append(s.flush())
    assert out == ["The speaker said the deadline moves to Friday.", "Dr. Smith agreed, e.g. on the call today.",
                   "Yes. That was all."]  # fmt: skip


def test_parse_source_and_context_budget():
    assert brain.parse_source("It is Adam.\nSOURCE: transcript") == ("It is Adam.", "transcript")
    segs = [{"t0": i * 5.0, "t1": i * 5.0 + 4, "text": "word " * 300} for i in range(40)]
    ctx = brain.assemble("what did the speaker just say", "explainLast", segs, [], at=None)
    assert all(s["t1"] > 199 - 60 for s in ctx["window"]) and ctx["retrieved"] == []
    assert brain.tokens("\n".join(s["text"] for s in ctx["window"])) <= 1200
