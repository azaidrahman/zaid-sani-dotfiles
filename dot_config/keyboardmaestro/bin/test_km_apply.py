from kmlib import find_duplicate_uids, parse_macro_locations

PUNCH = "9C3A28CA-6CE2-42BD-B325-9D4A6BAFCBF1"
HELLO = "A0000000-0000-4000-8000-CHEZMOI00001"


def test_distinct_uids_report_no_duplicate():
    files = [("punch.kmmacros", {"UID": PUNCH}),
             ("hello-chezmoi.kmmacros", {"UID": HELLO})]
    assert find_duplicate_uids(files) == {}


def test_two_files_that_claim_one_uid_are_reported():
    files = [("punch.kmmacros", {"UID": PUNCH}),
             ("study-session.kmmacros", {"UID": PUNCH})]
    assert find_duplicate_uids(files) == {
        PUNCH: ["punch.kmmacros", "study-session.kmmacros"]
    }


def test_the_report_names_every_file_that_claims_the_uid():
    files = [("c.kmmacros", {"UID": PUNCH}),
             ("a.kmmacros", {"UID": PUNCH}),
             ("b.kmmacros", {"UID": PUNCH})]
    assert find_duplicate_uids(files)[PUNCH] == [
        "a.kmmacros", "b.kmmacros", "c.kmmacros"
    ]


def test_a_clean_file_stays_out_of_the_report():
    files = [("punch.kmmacros", {"UID": PUNCH}),
             ("study-session.kmmacros", {"UID": PUNCH}),
             ("hello-chezmoi.kmmacros", {"UID": HELLO})]
    assert list(find_duplicate_uids(files)) == [PUNCH]


def test_no_macro_file_reports_no_duplicate():
    assert find_duplicate_uids([]) == {}


def test_a_macro_reports_the_group_that_holds_it():
    raw = f"{PUNCH}\tChezmoi-Managed\n{HELLO}\tChezmoi-Managed\n"
    assert parse_macro_locations(raw) == {
        PUNCH: "Chezmoi-Managed", HELLO: "Chezmoi-Managed"
    }


def test_a_macro_in_another_group_reports_that_group():
    raw = f"{PUNCH}\tTodoist\n"
    assert parse_macro_locations(raw) == {PUNCH: "Todoist"}


def test_the_smart_groups_do_not_hide_the_real_group():
    raw = f"{PUNCH}\tAll Macros\n{PUNCH}\tEnabled Macros\n{PUNCH}\tTodoist\n"
    assert parse_macro_locations(raw) == {PUNCH: "Todoist"}


def test_a_line_without_a_tab_is_ignored():
    assert parse_macro_locations("junk\n") == {}


def test_no_macros_report_no_location():
    assert parse_macro_locations("") == {}
