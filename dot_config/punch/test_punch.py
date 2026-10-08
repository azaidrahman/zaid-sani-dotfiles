from punch import (parse_distraction, parse_score,
                    parse_pick, advance, step_label,
                    AWAY_DISTRACTION, BACK, STEPS)

OPTIONS = ["Kubernetes", "Terraform", "Go"]


def test_the_picked_item_is_read_by_its_index():
    assert parse_pick("0\n", OPTIONS) == "Kubernetes"
    assert parse_pick("2\n", OPTIONS) == "Go"

def test_a_cancelled_pick_gives_nothing():
    assert parse_pick("skip\n", OPTIONS) is None

def test_a_pick_that_timed_out_gives_nothing():
    # Nobody is at the desk, so no session must start.
    assert parse_pick("timeout\n", OPTIONS) is None

def test_an_index_past_the_list_gives_nothing():
    assert parse_pick("9\n", OPTIONS) is None

def test_a_negative_index_gives_nothing():
    assert parse_pick("-1\n", OPTIONS) is None

def test_an_empty_pick_gives_nothing():
    assert parse_pick("", OPTIONS) is None

def test_the_p_key_asks_for_the_step_before():
    assert parse_pick("back\n", OPTIONS) is BACK


def test_a_step_forward_takes_the_next_number():
    assert advance(1, "Kubernetes") == 2
    assert advance(2, "50") == 3

def test_a_step_back_takes_the_number_before():
    assert advance(3, BACK) == 2
    assert advance(2, BACK) == 1

def test_the_first_step_has_no_step_before_it():
    assert advance(1, BACK) == 1


def test_the_label_names_the_step():
    assert step_label(1, []) == f"Step 1 of {STEPS}"

def test_the_label_shows_what_the_user_picked():
    assert step_label(3, ["Kubernetes", "50 min"]) == (
        f"Step 3 of {STEPS} · Kubernetes · 50 min")

def test_the_label_leaves_out_an_empty_answer():
    assert step_label(2, ["Kubernetes", ""]) == f"Step 2 of {STEPS} · Kubernetes"


def test_the_hud_score_is_read():
    assert parse_score("5\n") == 5

def test_the_hud_key_zero_means_ten():
    # The HUD maps the 0 key to ten, so it prints 10 and not 0.
    assert parse_score("10\n") == 10

def test_a_hud_that_timed_out_takes_the_default_score():
    assert parse_score("timeout\n") == AWAY_DISTRACTION

def test_a_skipped_hud_gives_no_score():
    assert parse_score("skip\n") is None

def test_an_empty_hud_answer_gives_no_score():
    assert parse_score("") is None

def test_a_hud_score_out_of_range_gives_no_score():
    assert parse_score("11\n") is None


def test_a_score_is_read_from_the_dialog():
    assert parse_distraction("button returned:OK, text returned:4") == 4

def test_a_score_is_read_when_the_dialog_reports_no_timeout():
    out = "button returned:OK, text returned:4, gave up:false"
    assert parse_distraction(out) == 4

def test_a_dialog_that_timed_out_takes_the_default_score():
    out = "button returned:, text returned:, gave up:true"
    assert parse_distraction(out) == AWAY_DISTRACTION

def test_an_empty_answer_gives_no_score():
    assert parse_distraction("button returned:OK, text returned:") is None

def test_a_score_out_of_range_gives_no_score():
    assert parse_distraction("button returned:OK, text returned:11") is None

def test_a_word_gives_no_score():
    assert parse_distraction("button returned:OK, text returned:lots") is None


if __name__ == "__main__":
    import traceback
    tests = [
        test_the_picked_item_is_read_by_its_index,
        test_a_cancelled_pick_gives_nothing,
        test_a_pick_that_timed_out_gives_nothing,
        test_an_index_past_the_list_gives_nothing,
        test_a_negative_index_gives_nothing,
        test_an_empty_pick_gives_nothing,
        test_the_p_key_asks_for_the_step_before,
        test_a_step_forward_takes_the_next_number,
        test_a_step_back_takes_the_number_before,
        test_the_first_step_has_no_step_before_it,
        test_the_label_names_the_step,
        test_the_label_shows_what_the_user_picked,
        test_the_label_leaves_out_an_empty_answer,
        test_the_hud_score_is_read,
        test_the_hud_key_zero_means_ten,
        test_a_hud_that_timed_out_takes_the_default_score,
        test_a_skipped_hud_gives_no_score,
        test_an_empty_hud_answer_gives_no_score,
        test_a_hud_score_out_of_range_gives_no_score,
        test_a_score_is_read_from_the_dialog,
        test_a_score_is_read_when_the_dialog_reports_no_timeout,
        test_a_dialog_that_timed_out_takes_the_default_score,
        test_an_empty_answer_gives_no_score,
        test_a_score_out_of_range_gives_no_score,
        test_a_word_gives_no_score,
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


# --- the resync key of step 1 ---

def _topic_flow(monkeypatch, picks, started=True):
    """Drive ask_topic with canned picks. Return the answer and the starts."""
    import punch
    picks, starts = list(picks), []
    monkeypatch.setattr(punch, "read_topics", lambda: list(OPTIONS))
    monkeypatch.setattr(punch, "last_topic", lambda: None)
    monkeypatch.setattr(punch, "choose", lambda *a, **k: picks.pop(0))
    monkeypatch.setattr(punch, "start_resync",
                        lambda: (starts.append(True), started)[1])
    return punch.ask_topic(), starts


def test_the_resync_token_reads_as_the_resync_answer():
    from punch import RESYNC
    assert parse_pick("resync\n", OPTIONS) is RESYNC


def test_the_resync_row_is_gone_from_the_list(monkeypatch):
    import punch
    seen = []
    monkeypatch.setattr(punch, "read_topics", lambda: list(OPTIONS))
    monkeypatch.setattr(punch, "last_topic", lambda: None)

    def spy(prompt, options, *a, **k):
        seen.append(list(options))
        return options[0]

    monkeypatch.setattr(punch, "choose", spy)
    punch.ask_topic()
    assert seen[0] == OPTIONS + [punch.OTHER]


def test_the_resync_key_ends_the_flow_when_it_starts(monkeypatch):
    from punch import RESYNC
    answer, starts = _topic_flow(monkeypatch, [RESYNC], started=True)
    assert starts == [True]
    assert answer is None


def test_a_refused_resync_brings_back_the_list_of_topics(monkeypatch):
    # A resync that the user refuses must not end the punch.
    from punch import RESYNC
    answer, starts = _topic_flow(monkeypatch, [RESYNC, "Go"], started=False)
    assert starts == [True]
    assert answer == "Go"


def test_a_topic_never_starts_a_resync(monkeypatch):
    answer, starts = _topic_flow(monkeypatch, ["Terraform"])
    assert starts == []
    assert answer == "Terraform"


def test_a_resync_that_cannot_start_does_not_end_the_flow(monkeypatch):
    import punch
    monkeypatch.setattr(punch, "choose", lambda *a, **k: "yes")
    monkeypatch.setattr(punch, "notify", lambda text: None)

    def boom(*a, **k):
        raise OSError("no interpreter")

    monkeypatch.setattr(punch.subprocess, "Popen", boom)
    assert punch.start_resync() is False


def _moodist_flow(monkeypatch, choice, fail=False):
    import punch
    opened = []
    monkeypatch.setattr(punch, "choose", lambda *a, **k: choice)

    def fake_run(args, **k):
        if fail:
            raise OSError("no open")
        opened.append(args)

    monkeypatch.setattr(punch.subprocess, "run", fake_run)
    punch.offer_moodist()
    return opened


def test_the_return_key_opens_moodist(monkeypatch):
    import punch
    assert _moodist_flow(monkeypatch, punch.MOODIST_OPEN) == [
        ["open", punch.MOODIST_URL]]

def test_a_skipped_prompt_does_not_open_moodist(monkeypatch):
    assert _moodist_flow(monkeypatch, "Skip") == []

def test_a_closed_prompt_does_not_open_moodist(monkeypatch):
    # Escape and a timeout give no choice.
    assert _moodist_flow(monkeypatch, None) == []

def test_a_failed_open_does_not_stop_the_session(monkeypatch):
    import punch
    assert _moodist_flow(monkeypatch, punch.MOODIST_OPEN, fail=True) == []

def test_the_moodist_prompt_comes_before_the_timer(monkeypatch):
    # The start waits for the Clock.app plist. A prompt after it comes
    # when the user has already moved on.
    import punch
    from datetime import datetime
    calls = []
    answers = iter(["Go", "25", datetime.now()])
    monkeypatch.setattr(punch, "open_state", lambda: None)
    monkeypatch.setattr(punch, "ask_topic", lambda *a: next(answers))
    monkeypatch.setattr(punch, "ask_focus", lambda *a: "")
    monkeypatch.setattr(punch, "ask_minutes", lambda *a: next(answers))
    monkeypatch.setattr(punch, "ask_start", lambda *a: next(answers))
    monkeypatch.setattr(punch, "offer_moodist", lambda: calls.append("moodist"))
    monkeypatch.setattr(punch, "start_live", lambda *a: calls.append("timer"))
    punch.start_interactive()
    assert calls == ["moodist", "timer"]


def test_the_focus_reaches_the_live_start(monkeypatch):
    import punch
    from datetime import datetime
    seen = []
    answers = iter(["Go", "Fix the parser", "25", datetime.now()])
    monkeypatch.setattr(punch, "open_state", lambda: None)
    monkeypatch.setattr(punch, "ask_topic", lambda *a: next(answers))
    monkeypatch.setattr(punch, "ask_focus", lambda *a: next(answers))
    monkeypatch.setattr(punch, "ask_minutes", lambda *a: next(answers))
    monkeypatch.setattr(punch, "ask_start", lambda *a: next(answers))
    monkeypatch.setattr(punch, "offer_moodist", lambda: None)
    monkeypatch.setattr(punch, "start_live",
                        lambda topic, m, start_at, focus: seen.append(focus))
    punch.start_interactive()
    assert seen == ["Fix the parser"]


def test_the_focus_step_has_its_own_number():
    assert step_label(2, ["Go"]) == f"Step 2 of {STEPS} · Go"


def test_the_pill_toggle_is_the_option_for_the_open_session(monkeypatch, tmp_path):
    import punch
    shown = []

    def fake_choose(prompt, options, *a, **k):
        shown.append(options)
        return punch.PILL_HIDE

    monkeypatch.setattr(punch, "PILL_FLAG", tmp_path / "punch-pill.hidden")
    monkeypatch.setattr(punch, "choose", fake_choose)
    s = {"topic": "Go", "start": "2026-08-07T14:30:00", "minutes": 25}
    assert punch.ask_open_session(s) == "pill"
    assert shown[0][-1] == punch.PILL_HIDE


def test_a_pending_session_cannot_be_ended_from_the_prompt(monkeypatch, tmp_path):
    # A second punch press during the start must not offer End & log,
    # because the start writes the final state a moment later.
    import punch
    shown = []

    def fake_choose(prompt, options, *a, **k):
        shown.append(options)
        return options[0]

    monkeypatch.setattr(punch, "PILL_FLAG", tmp_path / "punch-pill.hidden")
    monkeypatch.setattr(punch, "choose", fake_choose)
    s = {"topic": "Go", "start": "2026-08-07T14:30:00", "minutes": 25,
         "pending": True}
    assert punch.ask_open_session(s) == "keep"
    assert "End & log" not in shown[0] and "Discard" not in shown[0]
    assert punch.PILL_HIDE in shown[0]


def test_a_pending_session_is_left_alone_by_check(monkeypatch, tmp_path):
    # The start writes a pending state before the timer shows up in the
    # plist. A check() run in that window has no timer, and it must not
    # cancel the session.
    import json
    import punch
    state = tmp_path / "punch.json"
    claim = tmp_path / "punch.ending.json"
    state.write_text(json.dumps({"topic": "Go", "pending": True,
                                 "planned_end": "2026-08-07T15:00:00"}))
    monkeypatch.setattr(punch, "STATE", state)
    monkeypatch.setattr(punch, "CLAIM", claim)
    monkeypatch.setattr(punch, "finish",
                        lambda *a: (_ for _ in ()).throw(AssertionError("finished")))
    punch.check()
    assert state.exists() and not claim.exists()
    assert json.loads(state.read_text())["pending"] is True


def test_the_pill_toggle_keeps_the_session_open(monkeypatch):
    import punch
    toggled = []
    monkeypatch.setattr(punch, "open_state",
                        lambda: (punch.STATE, {"topic": "Go", "start": "2026-08-07T14:30:00",
                                               "minutes": 25}))
    monkeypatch.setattr(punch, "ask_open_session", lambda s: "pill")
    monkeypatch.setattr(punch, "toggle_pill", lambda: toggled.append(True))
    assert punch.reset() == "keep"
    assert toggled == [True]


# --- a stale timer of the same length ---

def _timer(id, minutes, state=3):
    return {"id": id, "state": state, "duration": minutes * 60.0,
            "title": "", "fired_date": None}


def _names(calls):
    """Return start or stop for each timer call, in order."""
    return ["stop" if c.endswith("stop_timer.applescript")
            else c.split("?name=")[1].split("&")[0] if "?name=" in c
            else "other" for c in calls]


START = "Start%20Study%20Timer"


def test_a_running_timer_of_the_same_length_is_stale():
    import punch
    found = [_timer("A", 25), _timer("B", 50)]
    assert punch.stale_timer(25, found)["id"] == "A"

def test_a_timer_of_another_length_is_not_stale():
    import punch
    assert punch.stale_timer(25, [_timer("B", 50)]) is None

def test_a_fired_timer_of_the_same_length_is_not_stale():
    import punch
    assert punch.stale_timer(25, [_timer("A", 25, state=1)]) is None


def _timer_world(monkeypatch, loads):
    """Fake Clock.app and Shortcuts. Return the shortcut calls in order.

    `loads` is the list of timer lists that timers.load returns, one per
    call. The last one repeats.
    """
    import punch
    calls, loads = [], list(loads)
    monkeypatch.setattr(punch.time, "sleep", lambda s: None)
    monkeypatch.setattr(punch.timers, "load",
                        lambda: loads.pop(0) if len(loads) > 1 else loads[0])
    from types import SimpleNamespace

    def fake_run(args, **k):
        calls.append(args[1])
        return SimpleNamespace(returncode=0, stdout="stopped\n", stderr="")

    monkeypatch.setattr(punch.subprocess, "run", fake_run)
    monkeypatch.setattr(punch, "START_TRIES", 2)
    monkeypatch.setattr(punch, "STOP_TRIES", 2)
    return calls


def test_the_restart_stops_the_stale_timer_before_the_start(monkeypatch):
    import punch
    # Clock.app can give the restarted timer the same id, so the stopped
    # timer must leave the snapshot before the start.
    calls = _timer_world(monkeypatch, [
        [_timer("A", 25)],            # stop: still running
        [_timer("A", 25, state=1)],   # stop: gone
        [_timer("A", 25, state=1)],   # snapshot
        [_timer("A", 25)],            # start: back with the same id
    ])
    assert punch.restart_timer(25) == "A"
    assert _names(calls) == ["stop", START]


def test_a_restart_that_cannot_stop_the_timer_gives_no_id(monkeypatch):
    import punch
    calls = _timer_world(monkeypatch, [[_timer("A", 25)]])
    assert punch.restart_timer(25) == ""
    # It still tries the start, because the stop may be slow to show.
    assert len(calls) == 2


def _live_start(monkeypatch, tmp_path, loads, reset_choice=None):
    """Run start_live with a fake Clock.app. Return the shortcut calls."""
    import punch
    from datetime import datetime
    calls = _timer_world(monkeypatch, loads)
    monkeypatch.setattr(punch, "STATE", tmp_path / "punch.json")
    monkeypatch.setattr(punch, "PILL_FLAG", tmp_path / "pill")
    monkeypatch.setattr(punch, "start_pill", lambda: None)
    monkeypatch.setattr(punch, "notify", lambda text: None)
    monkeypatch.setattr(punch, "choose", lambda *a, **k: reset_choice)
    monkeypatch.setattr(punch.cal, "create_event", lambda *a: "UID")
    punch.start_live("Go", 25, datetime.now())
    return calls


def test_the_start_clears_a_stale_timer_first(monkeypatch, tmp_path):
    import json
    import punch
    calls = _live_start(monkeypatch, tmp_path, [
        [_timer("A", 25)],            # stale
        [_timer("A", 25, state=1)],   # stopped
        [_timer("A", 25, state=1)],   # snapshot
        [_timer("A", 25)],            # started
    ])
    assert _names(calls) == ["stop", START]
    assert json.loads(punch.STATE.read_text())["timer_id"] == "A"


def test_a_start_with_no_stale_timer_only_starts(monkeypatch, tmp_path):
    calls = _live_start(monkeypatch, tmp_path, [[], [], [_timer("A", 25)]])
    assert _names(calls) == [START]


def test_a_missing_timer_offers_a_reset_that_retries(monkeypatch, tmp_path):
    import json
    import punch
    calls = _live_start(monkeypatch, tmp_path, [
        [],                           # no stale timer
        [],                           # snapshot
        [], [],                       # start: nothing shows up
        [_timer("A", 25)],            # reset: the stop sees it
        [_timer("A", 25, state=1)],   # stopped
        [_timer("A", 25, state=1)],   # snapshot
        [_timer("A", 25)],            # started
    ], reset_choice=punch.TIMER_RESET)
    assert _names(calls) == [START, "stop",
                             START]
    assert json.loads(punch.STATE.read_text())["timer_id"] == "A"


def test_a_refused_reset_fails_loudly_and_leaves_no_session(monkeypatch, tmp_path):
    import punch
    import pytest
    with pytest.raises(RuntimeError, match="same length"):
        _live_start(monkeypatch, tmp_path, [[]], reset_choice=None)
    assert not punch.STATE.exists()


# --- the close stops the timer it owns ---

def test_a_discard_stops_a_running_timer(monkeypatch, tmp_path):
    import punch
    state = tmp_path / "punch.json"
    state.write_text("{}")
    calls = _timer_world(monkeypatch, [[_timer("A", 25)]])
    monkeypatch.setattr(punch, "notify", lambda text: None)
    s = {"topic": "Go", "timer_id": "A", "start": "2026-08-07T14:30:00",
         "minutes": 25, "planned_end": "2026-08-07T14:55:00"}
    monkeypatch.setattr(punch, "open_state", lambda: (state, s))
    monkeypatch.setattr(punch, "ask_open_session", lambda s: "discard")
    assert punch.reset() == "discard"
    assert _names(calls) == ["stop"]


def test_a_fired_timer_is_left_alone(monkeypatch):
    import punch
    calls = _timer_world(monkeypatch, [[_timer("A", 25, state=1)]])
    punch.stop_session_timer({"timer_id": "A"})
    assert calls == []


def test_a_cancel_stops_the_timer_before_the_note(monkeypatch):
    import punch
    from datetime import datetime
    calls = _timer_world(monkeypatch, [[_timer("A", 25)]])
    monkeypatch.setattr(punch, "notify", lambda text: None)
    monkeypatch.setattr(punch.cal, "mark_cancelled", lambda *a: "ok")
    monkeypatch.setattr(punch.note, "build_note",
                        lambda *a: ("/tmp/x.md", "body"))
    monkeypatch.setattr(punch.note, "adv_uri", lambda p, b: "obsidian://x")
    s = {"topic": "Go", "timer_id": "A", "event_uid": "U",
         "start": "2026-08-07T14:30:00"}
    punch.finish(s, "cancelled", datetime(2026, 8, 7, 14, 40), None)
    assert _names(calls)[0] == "stop"
