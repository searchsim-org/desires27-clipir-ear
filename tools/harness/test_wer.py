import wer


def test_identical_and_normalised():
    assert (
        wer.wer("The deadline moves to Friday, the 14th!", "the deadline moves to friday the 14th")
        == 0
    )


def test_numbers_spelled_out_match_digits():
    assert wer.wer("batch size of 12", "batch size of twelve") == 0


def test_one_substitution_one_deletion():
    assert wer.wer("the optimizer is called adam", "the optimiser is adam") == 2 / 5
