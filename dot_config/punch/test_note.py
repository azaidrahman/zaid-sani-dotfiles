from datetime import datetime
from note import build_note, adv_uri

START = datetime(2026, 8, 7, 14, 30)
END = datetime(2026, 8, 7, 15, 30)

def test_the_path_holds_the_date_the_time_and_the_topic():
    path, _ = build_note("Kubernetes", START, END, "completed", 3)
    assert path == "5-Workbook/worklog/2026-08-07 1430 Kubernetes.md"

def test_the_note_holds_the_real_hours():
    _, body = build_note("Go", START, datetime(2026, 8, 7, 14, 42),
                         "cancelled", None)
    assert "hours: 0.2" in body
    assert "status: cancelled" in body

def test_a_cancelled_note_has_an_empty_distraction():
    _, body = build_note("Go", START, END, "cancelled", None)
    assert "distraction:\n" in body

def test_the_note_holds_the_tag_and_the_times():
    _, body = build_note("Go", START, END, "completed", 7)
    assert "  - work/session" in body
    assert 'start: "14:30"' in body
    assert 'end: "15:30"' in body
    assert "distraction: 7" in body

def test_the_url_encodes_the_path_and_the_data():
    url = adv_uri("5-Workbook/worklog/a b.md", "x y")
    assert "vault=Polaris" in url
    assert "5-Workbook%2Fworklog%2Fa%20b.md" in url
    assert "mode=new" in url


def test_a_note_carries_its_source():
    _, body = build_note("Kubernetes", datetime(2026, 8, 20, 9, 30),
                         datetime(2026, 8, 20, 11, 0), "completed", 3,
                         source="retro")
    assert "source: retro\n" in body

def test_the_source_defaults_to_live():
    _, body = build_note("Kubernetes", datetime(2026, 8, 20, 9, 30),
                         datetime(2026, 8, 20, 11, 0), "completed", 3)
    assert "source: live\n" in body

def test_a_note_carries_its_focus_as_a_quoted_value():
    _, body = build_note("Kubernetes", START, END, "completed", 3,
                         focus="Fix: the parser #2")
    assert 'focus: "Fix: the parser #2"\n' in body

def test_a_note_without_a_focus_has_no_focus_field():
    _, body = build_note("Kubernetes", START, END, "completed", 3)
    assert "focus:" not in body


if __name__ == "__main__":
    import traceback
    tests = [
        test_the_path_holds_the_date_the_time_and_the_topic,
        test_the_note_holds_the_real_hours,
        test_a_cancelled_note_has_an_empty_distraction,
        test_the_note_holds_the_tag_and_the_times,
        test_the_url_encodes_the_path_and_the_data,
        test_a_note_carries_its_source,
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
