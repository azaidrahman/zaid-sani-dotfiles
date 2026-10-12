from datetime import datetime

from sessions import FIELDS, append, build_row, read

START = datetime(2026, 8, 7, 14, 30)
END = datetime(2026, 8, 7, 15, 30)


def test_the_hours_come_from_the_real_times():
    row = build_row("Go", START, datetime(2026, 8, 7, 14, 42), "cancelled", None)
    assert row["hours"] == 0.2


def test_a_cancelled_session_has_an_empty_distraction():
    row = build_row("Go", START, END, "cancelled", None)
    assert row["distraction"] == ""


def test_the_source_defaults_to_live():
    assert build_row("Go", START, END, "completed", 3)["source"] == "live"


def test_a_missing_file_gives_no_rows(tmp_path):
    assert read(tmp_path / "sessions.csv") == []


def test_appended_rows_keep_their_text_and_follow_one_header(tmp_path):
    path = tmp_path / "sessions.csv"
    first = build_row('Kubernetes, "Pod" v2', START, END, "completed", 3,
                      focus="Fix: the parser #2")
    second = build_row("Go", END, datetime(2026, 8, 7, 16, 0), "completed", 5)
    append(first, path)
    append(second, path)

    assert path.read_text().splitlines()[0] == ",".join(FIELDS)
    assert path.read_text().count(",".join(FIELDS)) == 1
    assert read(path) == [
        {k: str(v) for k, v in first.items()},
        {k: str(v) for k, v in second.items()},
    ]


if __name__ == "__main__":
    import traceback
    tests = [
        test_the_hours_come_from_the_real_times,
        test_a_cancelled_session_has_an_empty_distraction,
        test_the_source_defaults_to_live,
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
