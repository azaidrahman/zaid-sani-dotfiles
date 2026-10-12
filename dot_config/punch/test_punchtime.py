from datetime import datetime

from punchtime import (classify, find_overlap,
                       round_down_quarter, to_12h)

NOW = datetime(2026, 8, 20, 14, 0)


def test_a_quarter_hour_rounds_to_itself():
    assert round_down_quarter(datetime(2026, 8, 20, 9, 30)) \
        == datetime(2026, 8, 20, 9, 30)

def test_the_round_goes_down_never_up():
    assert round_down_quarter(datetime(2026, 8, 20, 9, 44, 59)) \
        == datetime(2026, 8, 20, 9, 30)

def test_the_round_clears_the_seconds():
    assert round_down_quarter(datetime(2026, 8, 20, 9, 15, 42)) \
        == datetime(2026, 8, 20, 9, 15)


def test_a_morning_time_reads_as_am():
    assert to_12h(datetime(2026, 8, 20, 9, 30)) == (9, 30, "am")

def test_an_afternoon_time_reads_as_pm():
    assert to_12h(datetime(2026, 8, 20, 14, 5)) == (2, 5, "pm")

def test_noon_is_twelve_pm():
    assert to_12h(datetime(2026, 8, 20, 12, 0)) == (12, 0, "pm")

def test_midnight_is_twelve_am():
    assert to_12h(datetime(2026, 8, 20, 0, 15)) == (12, 15, "am")


def test_a_block_with_time_left_is_live():
    # Started 13:20 for 60 min at 14:00 — 20 minutes remain.
    kind, remaining = classify(datetime(2026, 8, 20, 13, 20), 60, NOW)
    assert kind == "live"
    assert remaining == 20

def test_a_finished_block_is_retro():
    kind, end = classify(datetime(2026, 8, 20, 9, 30), 90, NOW)
    assert kind == "retro"
    assert end == datetime(2026, 8, 20, 11, 0)

def test_less_than_a_minute_left_counts_as_retro():
    # The spec: a remainder under one minute is a retro session.
    kind, end = classify(datetime(2026, 8, 20, 13, 0, 30), 60, NOW)
    assert kind == "retro"

def test_the_remaining_minutes_round_to_the_nearest_minute():
    kind, remaining = classify(datetime(2026, 8, 20, 13, 30, 20), 60, NOW)
    assert kind == "live"
    assert remaining == 30

def test_exactly_one_minute_left_counts_as_retro():
    # The boundary: remaining must be MORE than 60 seconds to stay live.
    kind, _ = classify(datetime(2026, 8, 20, 13, 1), 60, NOW)
    assert kind == "retro"


NOTES =[("Work", datetime(2026, 8, 20, 10, 0), datetime(2026, 8, 20, 10, 50))]

def test_a_covering_block_overlaps():
    hit = find_overlap(datetime(2026, 8, 20, 9, 30),
                       datetime(2026, 8, 20, 11, 0), NOTES)
    assert hit == "10:00 Work"

def test_a_block_that_touches_the_edge_does_not_overlap():
    # Back-to-back blocks share one instant. That is not an overlap.
    hit = find_overlap(datetime(2026, 8, 20, 10, 50),
                       datetime(2026, 8, 20, 11, 30), NOTES)
    assert hit is None

def test_a_separate_block_does_not_overlap():
    hit = find_overlap(datetime(2026, 8, 20, 8, 0),
                       datetime(2026, 8, 20, 9, 0), NOTES)
    assert hit is None


if __name__ == "__main__":
    import traceback
    tests = [
        test_a_quarter_hour_rounds_to_itself,
        test_the_round_goes_down_never_up,
        test_the_round_clears_the_seconds,
        test_a_morning_time_reads_as_am,
        test_an_afternoon_time_reads_as_pm,
        test_noon_is_twelve_pm,
        test_midnight_is_twelve_am,
        test_a_block_with_time_left_is_live,
        test_a_finished_block_is_retro,
        test_less_than_a_minute_left_counts_as_retro,
        test_the_remaining_minutes_round_to_the_nearest_minute,
        test_exactly_one_minute_left_counts_as_retro,
        test_a_covering_block_overlaps,
        test_a_block_that_touches_the_edge_does_not_overlap,
        test_a_separate_block_does_not_overlap,
    ]
    passed = 0
    failed = 0
    for test in tests:
        try:
            test()
            print(f"✓ {test.__name__}")
            passed += 1
        except Exception as e:
            print(f"✗ {test.__name__}: {e}")
            traceback.print_exc()
            failed += 1
    print(f"\n{passed} passed, {failed} failed")
    exit(0 if failed == 0 else 1)
