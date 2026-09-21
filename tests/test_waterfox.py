import importlib.machinery
import importlib.util
import io
import json
import sqlite3
import threading
import sys
import tempfile
import unittest
from contextlib import closing, redirect_stdout
from pathlib import Path
from unittest.mock import call, patch

ROOT = Path(__file__).resolve().parents[1]
LOADER = importlib.machinery.SourceFileLoader("waterfox", str(ROOT / "bin/waterfix"))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
assert SPEC is not None
WATERFOX = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = WATERFOX
LOADER.exec_module(WATERFOX)


def customization_preference(state):
    serialized = json.dumps(state, separators=(",", ":"))
    return f'user_pref("browser.uiCustomization.state", {json.dumps(serialized)});\n'


def read_customization_state(path):
    line = path.read_text(encoding="utf-8").strip()
    encoded = line.removeprefix('user_pref("browser.uiCustomization.state", ').removesuffix(");")
    return json.loads(json.loads(encoded))


class WaterfoxUiTests(unittest.TestCase):
    def test_presentation_falls_back_when_shared_ui_is_unavailable(self):
        output = io.StringIO()
        with (
            patch.object(WATERFOX.subprocess, "run", side_effect=OSError),
            redirect_stdout(output),
        ):
            WATERFOX.ui_status("note", "No databases changed.")

        self.assertEqual(output.getvalue(), "No databases changed.\n")

    def test_presentation_uses_shared_ui_primitives(self):
        with patch.object(WATERFOX, "ui_present", return_value=True) as present:
            WATERFOX.ui_title("Waterfix")
            WATERFOX.ui_section("Bookmark changes")
            WATERFOX.ui_status("success", "Organized bookmarks")

        self.assertEqual(
            present.call_args_list,
            [
                call("title", "--", "Waterfix"),
                call("section", "--", "Bookmark changes"),
                call("status", "success", "--", "Organized bookmarks"),
            ],
        )

    def test_confirmation_maps_shared_ui_status(self):
        with patch.object(WATERFOX.subprocess, "run") as run:
            run.return_value.returncode = 0
            self.assertTrue(WATERFOX.ui_confirm("Continue?", "yes"))
            run.assert_called_once_with(
                [str(WATERFOX.JSH_UI), "confirm", "--default", "yes", "--", "Continue?"],
                check=False,
            )

            run.reset_mock()
            run.return_value.returncode = 1
            self.assertFalse(WATERFOX.ui_confirm("Continue?"))

            run.return_value.returncode = 2
            with self.assertRaisesRegex(RuntimeError, "status 2"):
                WATERFOX.ui_confirm("Continue?")

    def test_multi_selection_maps_shared_ui_output(self):
        choices = [("one@example.test", "One"), ("two@example.test", "Two")]
        with patch.object(WATERFOX.subprocess, "run") as run:
            run.return_value.returncode = 0
            run.return_value.stdout = "two@example.test\none@example.test\n"
            self.assertEqual(
                WATERFOX.ui_choose_many("Add-ons", choices),
                ["two@example.test", "one@example.test"],
            )
            run.assert_called_once_with(
                [
                    str(WATERFOX.JSH_UI),
                    "choose-many",
                    "Add-ons",
                    "one@example.test",
                    "One",
                    "two@example.test",
                    "Two",
                ],
                capture_output=True,
                text=True,
                check=False,
            )

            run.return_value.returncode = 130
            self.assertEqual(WATERFOX.ui_choose_many("Add-ons", choices), [])

            run.return_value.returncode = 2
            with self.assertRaisesRegex(RuntimeError, "status 2"):
                WATERFOX.ui_choose_many("Add-ons", choices)


class WaterfoxPreferenceTests(unittest.TestCase):
    def test_removes_import_button_from_profile_preferences(self):
        state = {
            "placements": {"PersonalToolbar": ["import-button", "personal-bookmarks"]},
            "seen": ["import-button"],
            "dirtyAreaCache": [],
        }
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory)
            preference = customization_preference(state)
            (profile / "prefs.js").write_text(preference, encoding="utf-8")
            (profile / "user.js").write_bytes(preference.replace("\n", "\r\n").encode())

            updates = WATERFOX.plan_import_button_removal(profile)
            backups = WATERFOX.apply_preference_updates(updates)

            self.assertEqual(set(updates), {profile / "prefs.js", profile / "user.js"})
            self.assertEqual(len(backups), 2)
            for name in ("prefs.js", "user.js"):
                updated = read_customization_state(profile / name)
                self.assertEqual(updated["placements"]["PersonalToolbar"], ["personal-bookmarks"])
                self.assertNotIn("import-button", updated["seen"])
                self.assertIn("PersonalToolbar", updated["dirtyAreaCache"])
            self.assertTrue((profile / "user.js").read_bytes().endswith(b"\r\n"))
            self.assertEqual(WATERFOX.plan_import_button_removal(profile), {})


class WaterfoxShutdownTests(unittest.TestCase):

    def test_warns_closes_waterfox_and_continues(self):
        with (
            patch.object(WATERFOX.sys, "platform", "linux"),
            patch.object(WATERFOX.sys.stdin, "isatty", return_value=True),
            patch.object(WATERFOX, "waterfox_is_running", side_effect=[True, False, False]),
            patch.object(WATERFOX, "ui_confirm", return_value=True) as prompt,
            patch.object(WATERFOX, "ui_status") as status,
            patch.object(WATERFOX.subprocess, "run") as run,
        ):
            WATERFOX.ensure_waterfox_closed()

        status.assert_called_once_with(
            "warn",
            "Waterfox is open and its profile database is locked; waterfix cannot make changes.",
        )
        prompt.assert_called_once_with("Close Waterfox and try again?", "yes")
        self.assertEqual(
            run.call_args_list,
            [
                call(
                    ["pkill", "-TERM", "-x", "waterfox"],
                    stdout=WATERFOX.subprocess.DEVNULL,
                    stderr=WATERFOX.subprocess.DEVNULL,
                    check=False,
                ),
                call(
                    ["pkill", "-TERM", "-x", "waterfox-bin"],
                    stdout=WATERFOX.subprocess.DEVNULL,
                    stderr=WATERFOX.subprocess.DEVNULL,
                    check=False,
                ),
            ],
        )

    def test_yes_closes_waterfox_without_prompt_or_tty(self):
        with (
            patch.object(WATERFOX.sys, "platform", "linux"),
            patch.object(WATERFOX.sys.stdin, "isatty", return_value=False),
            patch.object(WATERFOX, "waterfox_is_running", side_effect=[True, False, False]),
            patch.object(WATERFOX, "ui_confirm") as prompt,
            patch.object(WATERFOX, "ui_status"),
            patch.object(WATERFOX.subprocess, "run") as run,
        ):
            WATERFOX.ensure_waterfox_closed(assume_yes=True)

        prompt.assert_not_called()
        self.assertEqual(run.call_count, 2)

    def test_leaves_waterfox_open_when_close_is_declined(self):
        with (
            patch.object(WATERFOX.sys.stdin, "isatty", return_value=True),
            patch.object(WATERFOX, "waterfox_is_running", return_value=True),
            patch.object(WATERFOX, "ui_confirm", return_value=False),
            patch.object(WATERFOX, "ui_status"),
            patch.object(WATERFOX.subprocess, "run") as run,
            self.assertRaisesRegex(RuntimeError, "Cancelled; Waterfox remains open"),
        ):
            WATERFOX.ensure_waterfox_closed()

        run.assert_not_called()


class WaterfoxLifecycleTests(unittest.TestCase):

    def test_dispatches_open_stop_and_restart(self):
        events = []
        with (
            patch.object(
                WATERFOX,
                "open_waterfox",
                side_effect=lambda args=(): events.append(("open", list(args))),
            ),
            patch.object(
                WATERFOX, "stop_waterfox", side_effect=lambda: events.append(("stop", []))
            ),
        ):
            self.assertEqual(WATERFOX.main(["open", "--", "https://example.test"]), 0)
            self.assertEqual(WATERFOX.main(["stop"]), 0)
            self.assertEqual(WATERFOX.main(["restart"]), 0)

        self.assertEqual(
            events,
            [
                ("open", ["https://example.test"]),
                ("stop", []),
                ("stop", []),
                ("open", []),
            ],
        )

    def test_native_launch_preserves_managed_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "waterfox-bin"
            binary.touch(mode=0o755)
            (root / "profiles.ini").write_text(
                "[Profile0]\nName=managed\nPath=Profiles/default\n",
                encoding="utf-8",
            )
            (root / "installs.ini").write_text(
                "[Install]\nDefault=Profiles/default\n",
                encoding="utf-8",
            )
            with (
                patch.object(WATERFOX.sys, "platform", "linux"),
                patch.object(WATERFOX, "waterfox_root", return_value=root),
                patch.dict(WATERFOX.os.environ, {"JSH_WATERFOX_BIN": str(binary)}),
            ):
                command = WATERFOX.waterfox_launch_command(["https://example.test"])

        self.assertEqual(command, [str(binary), "-P", "managed", "https://example.test"])


class WaterfoxConfigurationTests(unittest.TestCase):

    def test_runs_waterfox_configuration_with_yes(self):
        with patch.object(WATERFOX.subprocess, "run") as run:
            run.return_value.returncode = 0
            WATERFOX.run_waterfox_configuration(assume_yes=True)

        command = run.call_args.args[0]
        environment = run.call_args.kwargs["env"]
        self.assertEqual(command, [str(WATERFOX.WATERFOX_CONFIGURATOR), "apply"])
        self.assertEqual(environment["JSH_INTERRUPT_REPORT"], "0")
        self.assertEqual(environment["JSH_ASSUME_YES"], "1")
        self.assertEqual(environment["JSH_CONFIGURE_ASSUME_YES"], "1")
        self.assertFalse(run.call_args.kwargs["check"])

    def test_reports_waterfox_configuration_failure(self):
        with (
            patch.object(WATERFOX.subprocess, "run") as run,
            self.assertRaisesRegex(RuntimeError, "failed with status 10"),
        ):
            run.return_value.returncode = 10
            WATERFOX.run_waterfox_configuration(assume_yes=False)

    def test_translates_configuration_interrupt(self):
        with patch.object(WATERFOX.subprocess, "run") as run, self.assertRaises(KeyboardInterrupt):
            run.return_value.returncode = 130
            WATERFOX.run_waterfox_configuration(assume_yes=False)

    def test_main_configures_before_resolving_default_profile(self):
        with (
            patch.object(WATERFOX, "run_waterfox_configuration") as configure,
            patch.object(WATERFOX, "resolve_profile", side_effect=RuntimeError("stop")) as resolve,
            patch.object(WATERFOX, "ui_present", return_value=True),
        ):
            self.assertEqual(WATERFOX.main([]), 2)

        configure.assert_called_once_with(False)
        resolve.assert_called_once_with(None)

    def test_main_skips_configuration_for_dry_run_and_explicit_profile(self):
        invocations = (["--dry-run"], ["--profile", "/tmp/profile"])
        for arguments in invocations:
            with self.subTest(arguments=arguments):
                with (
                    patch.object(WATERFOX, "run_waterfox_configuration") as configure,
                    patch.object(WATERFOX, "resolve_profile", side_effect=RuntimeError("stop")),
                    patch.object(WATERFOX, "ui_present", return_value=True),
                ):
                    self.assertEqual(WATERFOX.main(arguments), 2)
                    configure.assert_not_called()


class WaterfoxAddonRemovalTests(unittest.TestCase):

    def create_addon_fixture(self, directory):
        root = Path(directory)
        profile = root / "profile"
        extensions = profile / "extensions"
        extensions.mkdir(parents=True)
        vimium_id = "{d7742d87-e61d-4b78-b8a1-b469842139fa}"
        other_id = "other@example.test"
        config = root / "waterfox.json"
        config.write_text(
            json.dumps(
                {
                    "addons": [
                        {"id": vimium_id, "name": "Vimium"},
                        {"id": other_id, "name": "Other Add-on"},
                    ]
                }
            ),
            encoding="utf-8",
        )
        (profile / "extensions.json").write_text(
            json.dumps(
                {
                    "addons": [
                        {
                            "id": vimium_id,
                            "type": "extension",
                            "location": "app-profile",
                            "defaultLocale": {"name": "Vimium"},
                        },
                        {
                            "id": other_id,
                            "type": "extension",
                            "location": "app-profile",
                            "defaultLocale": {"name": "Other Add-on"},
                        },
                    ]
                }
            ),
            encoding="utf-8",
        )
        (profile / "extension-preferences.json").write_text(
            json.dumps({vimium_id: {"permissions": []}, other_id: {"permissions": []}}),
            encoding="utf-8",
        )
        (extensions / f"{vimium_id}.xpi").write_bytes(b"vimium")
        (extensions / f"{other_id}.xpi").write_bytes(b"other")
        return profile, config, vimium_id, other_id

    def test_remove_updates_profile_repository_and_policy(self):
        with tempfile.TemporaryDirectory() as directory:
            profile, config, vimium_id, other_id = self.create_addon_fixture(directory)
            with (
                patch.object(WATERFOX, "WATERFOX_CONFIG", config),
                patch.object(WATERFOX, "resolve_profile", return_value=profile),
                patch.object(WATERFOX, "ensure_waterfox_closed") as ensure_closed,
                patch.object(WATERFOX, "run_waterfox_configuration") as configure,
                patch.object(WATERFOX, "ui_present", return_value=True),
                redirect_stdout(io.StringIO()),
            ):
                self.assertEqual(WATERFOX.main(["--yes", "remove", "Vimium"]), 0)

            ensure_closed.assert_called_once_with(True)
            configure.assert_called_once_with(True, (vimium_id,))
            managed = json.loads(config.read_text(encoding="utf-8"))
            active = json.loads((profile / "extensions.json").read_text(encoding="utf-8"))
            preferences = json.loads(
                (profile / "extension-preferences.json").read_text(encoding="utf-8")
            )
            self.assertEqual([addon["id"] for addon in managed["addons"]], [other_id])
            self.assertEqual([addon["id"] for addon in active["addons"]], [other_id])
            self.assertEqual(list(preferences), [other_id])
            self.assertFalse((profile / "extensions" / f"{vimium_id}.xpi").exists())
            self.assertTrue((profile / "extensions" / f"{other_id}.xpi").is_file())

    def test_no_match_prompts_for_addon_and_confirmation(self):
        with tempfile.TemporaryDirectory() as directory:
            profile, config, vimium_id, other_id = self.create_addon_fixture(directory)
            output = io.StringIO()
            with (
                patch.object(WATERFOX, "WATERFOX_CONFIG", config),
                patch.object(WATERFOX, "resolve_profile", return_value=profile),
                patch.object(WATERFOX.sys.stdin, "isatty", return_value=True),
                patch.object(WATERFOX, "ui_choose_many", return_value=[other_id]) as select,
                patch.object(WATERFOX, "ui_confirm", return_value=True),
                patch.object(WATERFOX, "ensure_waterfox_closed"),
                patch.object(WATERFOX, "run_waterfox_configuration") as configure,
                patch.object(WATERFOX, "ui_present", return_value=True),
                redirect_stdout(output),
            ):
                self.assertEqual(WATERFOX.main(["remove", "missing"]), 0)

            select.assert_called_once()
            self.assertEqual(select.call_args.args[0], "No add-on matched 'missing'. Select one:")
            self.assertIn(
                (other_id, f"Other Add-on ({other_id}) [profile, repository]"),
                select.call_args.args[1],
            )
            configure.assert_called_once_with(True, (other_id,))
            active = json.loads((profile / "extensions.json").read_text(encoding="utf-8"))
            self.assertEqual([addon["id"] for addon in active["addons"]], [vimium_id])


class WaterfoxConfigFormattingTests(unittest.TestCase):

    def test_repository_removal_preserves_surrounding_formatting(self):
        source = """{
    "addons": [
        {
            "id": "keep@example.test",
            "name": "Keep",
            "permissions": ["tabs", "storage"]
        },
        {
            "id": "remove@example.test",
            "name": "Remove"
        }
    ],
    "version": 1
}
"""
        expected = """{
    "addons": [
        {
            "id": "keep@example.test",
            "name": "Keep",
            "permissions": ["tabs", "storage"]
        }
    ],
    "version": 1
}
"""
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "waterfox.json"
            config.write_text(source, encoding="utf-8")

            WATERFOX.remove_addons_from_config(config, {"remove@example.test"})

            self.assertEqual(config.read_text(encoding="utf-8"), expected)


class WaterfoxBookmarkTests(unittest.TestCase):
    def make_profile(self, directory):
        profile = Path(directory)
        with closing(sqlite3.connect(profile / "places.sqlite")) as db:
            db.executescript("""
                CREATE TABLE moz_origins (
                    id INTEGER PRIMARY KEY, prefix TEXT, host TEXT, frecency INTEGER DEFAULT 0,
                    UNIQUE(prefix, host)
                );
                CREATE TABLE moz_places (
                    id INTEGER PRIMARY KEY, url TEXT, url_hash INTEGER,
                    rev_host TEXT, guid TEXT, origin_id INTEGER,
                    foreign_count INTEGER DEFAULT 0, visit_count INTEGER DEFAULT 0,
                    recalc_frecency INTEGER DEFAULT 0
                );
                CREATE TABLE moz_bookmarks (
                    id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER,
                    position INTEGER, title TEXT, dateAdded INTEGER DEFAULT 0,
                    lastModified INTEGER DEFAULT 0, syncStatus INTEGER DEFAULT 2,
                    syncChangeCounter INTEGER DEFAULT 0, guid TEXT
                );
                CREATE TABLE moz_bookmarks_deleted (guid TEXT PRIMARY KEY, dateRemoved INTEGER);
                CREATE TABLE moz_items_annos (item_id INTEGER);
                INSERT INTO moz_bookmarks (id,type,parent,position,title,guid) VALUES
                    (1,2,0,0,'root','root________'),
                    (2,2,1,0,'toolbar','toolbar_____'),
                    (3,2,1,1,'unfiled','unfiled_____'),
                    (4,2,1,2,'tags','tags________');
                INSERT INTO moz_places (id, url, url_hash) VALUES
                    (1,'https://cached.test/page',101),
                    (2,'https://root.test/page',102),
                    (3,'https://missing.test/page',103);
                UPDATE moz_places SET foreign_count = 1;
                INSERT INTO moz_bookmarks (id,type,fk,parent,position,title,guid) VALUES
                    (5,1,1,2,0,NULL,'cached______'),
                    (6,1,2,2,1,NULL,'rootpage____'),
                    (7,1,3,3,0,'Missing','missing_____');
            """)
        with closing(sqlite3.connect(profile / "favicons.sqlite")) as db:
            db.executescript("""
                CREATE TABLE moz_icons (
                    id INTEGER PRIMARY KEY, icon_url TEXT, fixed_icon_url_hash INTEGER,
                    width INTEGER, root INTEGER, expire_ms INTEGER, data BLOB
                );
                CREATE TABLE moz_pages_w_icons (
                    id INTEGER PRIMARY KEY, page_url TEXT, page_url_hash INTEGER
                );
                CREATE TABLE moz_icons_to_pages (
                    page_id INTEGER, icon_id INTEGER, expire_ms INTEGER,
                    PRIMARY KEY (page_id,icon_id)
                );
                INSERT INTO moz_icons VALUES
                    (1,'https://cached.test/icon.png',0,32,0,0,X'89504E470D0A1A0A'),
                    (2,'https://root.test/favicon.ico',0,32,1,0,X'89504E470D0A1A0A'),
                    (3,'https://missing.test/favicon.ico',0,32,1,0,X'');
                INSERT INTO moz_pages_w_icons VALUES (1,'https://cached.test/page',101);
                INSERT INTO moz_icons_to_pages VALUES (1,1,0);
            """)
        return profile

    def test_locked_profile_closes_waterfox_before_reading_bookmarks_or_icons(self):
        for database in ("places.sqlite", "favicons.sqlite"):
            with self.subTest(database=database), tempfile.TemporaryDirectory() as directory:
                profile = self.make_profile(directory)
                with closing(sqlite3.connect(profile / "favicons.sqlite")) as db:
                    db.execute("UPDATE moz_icons SET data = X'89504E470D0A1A0A' WHERE id = 3")
                    db.commit()
                with closing(sqlite3.connect(profile / database)) as locked:
                    locked.execute("BEGIN EXCLUSIVE")
                    with (
                        patch.object(WATERFOX, "run_waterfox_configuration"),
                        patch.object(WATERFOX, "resolve_profile", return_value=profile),
                        patch.object(WATERFOX, "waterfox_is_running", return_value=True),
                        patch.object(WATERFOX, "stop_waterfox", side_effect=lambda **kwargs:
                                     locked.rollback()) as stop,
                        patch.object(WATERFOX.sys.stdin, "isatty", return_value=True),
                        patch.object(WATERFOX, "ui_confirm", return_value=True) as confirm,
                        patch.object(WATERFOX, "ui_present", return_value=True),
                        patch.object(WATERFOX, "fetch_icons") as fetch,
                        redirect_stdout(io.StringIO()),
                    ):
                        self.assertEqual(WATERFOX.main(["--skip-health-check"]), 0)
                        confirm.assert_called_once_with("Close Waterfox and try again?", "yes")
                        stop.assert_called_once_with(check_running=False)
                        fetch.assert_not_called()

    def test_profile_lock_recovery_is_bounded_if_another_process_keeps_the_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = self.make_profile(directory)
            with closing(sqlite3.connect(profile / "places.sqlite")) as locked:
                locked.execute("BEGIN EXCLUSIVE")
                with (
                    patch.object(WATERFOX, "ensure_waterfox_closed") as close,
                    self.assertRaisesRegex(RuntimeError, "places.sqlite is still locked"),
                ):
                    WATERFOX.ensure_profile_readable(profile, True)
                close.assert_called_once_with(True)

    def test_second_run_uses_saved_and_root_icons_without_writes_or_shutdown(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = self.make_profile(directory)
            cached = WATERFOX.read_cached_page_urls(profile)
            self.assertEqual(cached, {"https://cached.test/page", "https://root.test/page"})
            with (
                patch.object(
                    WATERFOX,
                    "fetch_icons",
                    return_value=(
                        {"missing.test": ("https://missing.test/icon.png", b"\x89PNG\r\n\x1a\n")},
                        [],
                    ),
                ) as fetch,
                patch.object(WATERFOX, "ensure_waterfox_closed") as close,
                patch.object(WATERFOX, "ui_present", return_value=True),
            ):
                args = ["--profile", str(profile), "--skip-health-check", "--yes"]
                self.assertEqual(WATERFOX.main(args), 0)
                self.assertEqual(list(fetch.call_args.args[0]), ["missing.test"])
                before = {p.name: p.read_bytes() for p in profile.iterdir()}
                fetch.reset_mock()
                close.reset_mock()
                self.assertEqual(WATERFOX.main(args), 0)
                fetch.assert_not_called()
                close.assert_not_called()
                self.assertEqual(before, {p.name: p.read_bytes() for p in profile.iterdir()})
                self.assertEqual(WATERFOX.main([*args, "--refresh"]), 0)
                self.assertEqual(
                    set(fetch.call_args.args[0]), {"cached.test", "root.test", "missing.test"}
                )

    def test_completed_health_and_failed_icon_checks_survive_repeated_runs(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = self.make_profile(directory)
            def response(url, timeout):
                if "root.test" in url:
                    return None, url, "timed out"
                return 200, url, None

            with (
                patch.object(WATERFOX, "check_page", side_effect=response) as check,
                patch.object(WATERFOX, "download_icon", side_effect=ValueError("not an image")) as icon,
                patch.object(WATERFOX, "download_document", side_effect=OSError("offline")) as document,
                patch.object(WATERFOX, "ensure_waterfox_closed") as close,
                patch.object(WATERFOX, "ui_present", return_value=True),
                redirect_stdout(io.StringIO()),
            ):
                args = ["--profile", str(profile), "--yes", "--delay", "0"]
                self.assertEqual(WATERFOX.main(args), 1)
                self.assertEqual(WATERFOX.read_processing_cache(profile), {
                    "health": {
                        "https://cached.test/page": "alive",
                        "https://root.test/page": "inconclusive",
                        "https://missing.test/page": "alive",
                    },
                    "favicon": {"https://missing.test/page": "missing"},
                    "reason": {
                        "https://cached.test/page": "", "https://missing.test/page": "",
                        "https://root.test/page": "timed out; preserved after retry",
                    },
                    "redirect": {
                        "https://cached.test/page": "", "https://missing.test/page": "",
                        "https://root.test/page": "",
                    },
                })
                before = {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in profile.iterdir()}
                for network in (check, icon, document):
                    network.reset_mock()
                close.reset_mock()
                self.assertEqual(WATERFOX.main(args), 0)
                for network in (check, icon, document):
                    network.assert_not_called()
                close.assert_not_called()
                self.assertEqual(before, {
                    p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in profile.iterdir()
                })

                # A changed URL is new work, even on an already processed hostname.
                with closing(sqlite3.connect(profile / "places.sqlite")) as db:
                    db.execute("UPDATE moz_places SET url = 'https://missing.test/new' WHERE id = 3")
                    db.commit()
                self.assertEqual(WATERFOX.main(args), 1)
                check.assert_called_once_with("https://missing.test/new", 5.0)
                self.assertGreater(icon.call_count, 0)
                for network in (check, icon, document):
                    network.reset_mock()
                self.assertEqual(WATERFOX.main([*args, "--refresh"]), 1)
                self.assertEqual({call.args[0] for call in check.call_args_list}, {
                    "https://cached.test/page", "https://root.test/page",
                    "http://root.test/", "https://missing.test/new",
                })
                self.assertGreater(icon.call_count, 0)

    def test_dry_run_does_not_save_network_results(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = self.make_profile(directory)
            before = {p.name: p.read_bytes() for p in profile.iterdir()}
            with (
                patch.object(WATERFOX, "check_page", return_value=(200, "", None)),
                patch.object(WATERFOX, "download_icon", side_effect=ValueError("not an image")),
                patch.object(WATERFOX, "download_document", side_effect=OSError("offline")),
                patch.object(WATERFOX, "ui_present", return_value=True),
                redirect_stdout(io.StringIO()),
            ):
                self.assertEqual(WATERFOX.main([
                    "--profile", str(profile), "--dry-run", "--delay", "0",
                ]), 0)
            self.assertEqual(before, {p.name: p.read_bytes() for p in profile.iterdir()})

    def test_interruption_keeps_completed_health_results(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = self.make_profile(directory)
            with (
                patch.object(WATERFOX, "assess_page", side_effect=[
                    (200, "https://cached.test/page", None), KeyboardInterrupt,
                ]),
                # Deliver the completed result before the simulated interruption.
                patch.object(WATERFOX, "as_completed", side_effect=iter),
                patch.object(WATERFOX, "ui_present", return_value=True),
                redirect_stdout(io.StringIO()),
            ):
                self.assertEqual(WATERFOX.main([
                    "--profile", str(profile), "--yes", "--workers", "1",
                ]), 130)
            self.assertEqual(WATERFOX.read_processing_cache(profile)["health"], {
                "https://cached.test/page": "alive",
            })

    def test_trash_is_excluded_from_checks_and_duplicate_moves_on_repeated_runs(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = self.make_profile(directory)
            with closing(sqlite3.connect(profile / "places.sqlite")) as db:
                db.execute("""INSERT INTO moz_bookmarks (id,type,fk,parent,position,title,guid)
                    VALUES (8,1,3,3,1,'Missing copy','missingcopy_')""")
                db.commit()
            icons = WATERFOX.read_cached_page_urls(profile)
            plan = WATERFOX.plan_organization(profile, {"https://missing.test/page"}, icons)
            self.assertEqual(plan.dead_ids, {7, 8})
            WATERFOX.apply_organization(profile, plan)
            self.assertNotIn("https://missing.test/page", dict(WATERFOX.read_bookmarks(profile)))
            repeated = WATERFOX.plan_organization(profile, set(), icons)
            self.assertFalse(repeated.dead_ids | repeated.duplicate_ids | repeated.delete_ids)
            self.assertFalse(repeated.sortable_folders)

    def test_redirects_require_a_healthy_specific_destination_or_https_upgrade(self):
        cases = [
            ("http://example.test/", "https://example.test/", 200, True, "HTTPS upgrade"),
            ("http://example.test/a?q=1", "https://example.test/a?q=1", 200, True, "HTTPS upgrade"),
            ("https://old.test/a", "https://new.test/b", 200, True, "healthy page"),
            ("https://old.test/a", "https://new.test/", 200, False, "homepage"),
            ("https://old.test/a", "https://new.test/index.html", 200, False, "homepage"),
            ("https://old.test/a", "https://new.test/login?next=/a", 200, False, "login or error"),
            ("https://old.test/a", "https://new.test/404.html", 200, False, "login or error"),
            ("https://old.test/a", "http://old.test/a", 200, False, "downgrades"),
            ("https://old.test/a", "https://new.test/b", 404, False, "HTTP 404"),
            ("https://old.test/a", "https://new.test/b", 403, False, "HTTP 403"),
        ]
        for source, target, status, fixable, reason in cases:
            with self.subTest(source=source, target=target, status=status):
                result = WATERFOX.assess_redirect(source, (status, target, f"HTTP {status}"))
                self.assertEqual(result[0] is not None and 200 <= result[0] < 300, fixable)
                self.assertIn(reason, result[2])

    def test_redirect_fix_and_review_move_are_idempotent_and_preserve_history(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = self.make_profile(directory)
            with closing(sqlite3.connect(profile / "places.sqlite")) as db:
                db.execute("UPDATE moz_places SET visit_count = 7 WHERE id = 1")
                db.commit()
            destinations = {
                "https://cached.test/page": "https://cached.test/new-page",
                "https://root.test/page": "https://root.test/",
                "https://missing.test/page": "https://missing.test/page",
            }
            with (
                patch.object(WATERFOX, "check_page", side_effect=lambda url, timeout:
                             (200, destinations[url], None)) as check,
                patch.object(WATERFOX, "download_icon", side_effect=lambda url, timeout:
                             (url, b"\x89PNG\r\n\x1a\n")) as icon,
                patch.object(WATERFOX, "ensure_waterfox_closed") as close,
                patch.object(WATERFOX, "ui_present", return_value=True),
                redirect_stdout(io.StringIO()) as output,
            ):
                args = ["--profile", str(profile), "--yes", "--delay", "0"]
                self.assertEqual(WATERFOX.main(args), 0)
                self.assertIn("Fixed: https://cached.test/new-page", output.getvalue())
                self.assertIn("homepage", output.getvalue())
                with closing(sqlite3.connect(profile / "places.sqlite")) as db:
                    self.assertEqual(db.execute(
                        "SELECT url, visit_count, foreign_count FROM moz_places WHERE id = 1"
                    ).fetchone(), ("https://cached.test/page", 7, 0))
                    bookmark = db.execute("""
                        SELECT p.url, p.foreign_count, b.guid, b.syncChangeCounter,
                               p.recalc_frecency, p.rev_host, o.host
                        FROM moz_bookmarks b JOIN moz_places p ON p.id = b.fk
                        JOIN moz_origins o ON o.id = p.origin_id WHERE b.id = 5
                        """).fetchone()
                    self.assertEqual(bookmark[:3], ("https://cached.test/new-page", 1, "cached______"))
                    self.assertGreaterEqual(bookmark[3], 1)
                    self.assertEqual(bookmark[4:], (1, "tset.dehcac.", "cached.test"))
                    self.assertEqual(db.execute("""
                        SELECT parent.title FROM moz_bookmarks b
                        JOIN moz_bookmarks parent ON parent.id = b.parent WHERE b.id = 6
                        """).fetchone()[0], "_review")
                before = {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in profile.iterdir()}
                for operation in (check, icon, close):
                    operation.reset_mock()
                self.assertEqual(WATERFOX.main(args), 0)
                for operation in (check, icon, close):
                    operation.assert_not_called()
                self.assertEqual(before, {
                    p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in profile.iterdir()
                })

    def test_redirect_to_existing_place_reuses_it_without_rewriting_history(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = self.make_profile(directory)
            plan = WATERFOX.plan_organization(
                profile, set(), None, redirects={"https://cached.test/page": "https://missing.test/page"},
            )
            WATERFOX.apply_organization(profile, plan)
            with closing(sqlite3.connect(profile / "places.sqlite")) as db:
                self.assertEqual(db.execute("SELECT COUNT(*) FROM moz_places").fetchone()[0], 3)
                self.assertEqual(db.execute("SELECT fk, guid FROM moz_bookmarks WHERE id = 5").fetchone(),
                                 (3, "cached______"))
                self.assertEqual(db.execute("SELECT foreign_count FROM moz_places WHERE id = 3").fetchone()[0], 2)
                self.assertEqual(db.execute("SELECT url FROM moz_places WHERE id = 1").fetchone()[0],
                                 "https://cached.test/page")

    def test_dry_run_redirects_are_planned_without_fixed_verdict_or_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = self.make_profile(directory)
            before = {p.name: p.read_bytes() for p in profile.iterdir()}
            with (
                patch.object(WATERFOX, "check_page", side_effect=lambda url, timeout:
                             (200, url.replace("/page", "/new"), None)),
                patch.object(WATERFOX, "download_icon", side_effect=lambda url, timeout:
                             (url, b"\x89PNG\r\n\x1a\n")),
                patch.object(WATERFOX, "ensure_waterfox_closed") as close,
                patch.object(WATERFOX, "ui_present", return_value=True),
                redirect_stdout(io.StringIO()) as output,
            ):
                self.assertEqual(WATERFOX.main([
                    "--profile", str(profile), "--dry-run", "--delay", "0",
                ]), 0)
                self.assertIn("Would fix: https://cached.test/new", output.getvalue())
                self.assertNotIn("Fixed:", output.getvalue())
                close.assert_not_called()
            self.assertEqual(before, {p.name: p.read_bytes() for p in profile.iterdir()})

    def test_health_retries_and_preserves_uncertain_failures(self):
        url = "https://example.test/page"
        cases = [
            ([404, 404], {url}, 0),
            ([410, 410], {url}, 0),
            ([404, 200], set(), 0),
            ([None, 404], set(), 1),
            ([None, None, 200], set(), 1),
            ([503, 503], set(), 1),
            ([403], set(), 1),
        ]
        for statuses, expected_dead, expected_unknown in cases:
            with (
                self.subTest(statuses=statuses),
                patch.object(
                    WATERFOX,
                    "check_page",
                    side_effect=[
                        (status, url, "timeout" if status is None else f"HTTP {status}")
                        for status in statuses
                    ],
                ) as check,
                redirect_stdout(io.StringIO()) as output,
            ):
                dead, unknown = WATERFOX.check_pages([(url, 0)], 1, 1)
                self.assertEqual(dead, expected_dead)
                self.assertEqual(len(unknown), expected_unknown)
                self.assertEqual(check.call_count, len(statuses))
                self.assertNotIn("GET", output.getvalue())
                self.assertNotIn("Checking", output.getvalue())
                if expected_dead:
                    self.assertEqual(output.getvalue(), f"Dead: {url} (HTTP {statuses[-1]})\n")
                elif expected_unknown:
                    self.assertEqual(output.getvalue(), f"Inconclusive: {url} ({unknown[0][1]})\n")

    def test_dns_requires_repeated_noname_and_working_control(self):
        url = "https://missing.test/"
        noname = WATERFOX.urllib.error.URLError(
            WATERFOX.socket.gaierror(WATERFOX.socket.EAI_NONAME, "missing")
        )
        for control_error, expected_status in [(None, -1), (OSError("offline"), None)]:
            with (
                self.subTest(control_error=control_error),
                patch.object(WATERFOX.urllib.request, "urlopen", side_effect=noname),
                patch.object(
                    WATERFOX.socket,
                    "getaddrinfo",
                    side_effect=[
                        WATERFOX.socket.gaierror(WATERFOX.socket.EAI_NONAME, "missing"),
                        control_error or [(0, 0, 0, "", ())],
                    ],
                ),
            ):
                result = WATERFOX.assess_page(url, 1, threading.Event(), lambda _: None)
                self.assertEqual(result[0], expected_status)

    def test_redirect_dns_failure_does_not_trash_a_resolving_host(self):
        url = "https://example.test/"
        with (
            patch.object(WATERFOX, "check_page", return_value=(None, url, "DNS name not found")),
            patch.object(WATERFOX.socket, "getaddrinfo", return_value=[(0, 0, 0, "", ())]),
        ):
            status, _, reason = WATERFOX.assess_page(url, 1, threading.Event(), lambda _: None)
        self.assertIsNone(status)
        self.assertIn("Host resolves", reason)

    def test_icon_attempts_report_endpoints_but_only_log_final_verdict(self):
        attempts = []
        with (
            patch.object(WATERFOX, "download_icon", side_effect=ValueError("not an image")),
            patch.object(WATERFOX, "download_document", side_effect=OSError("offline")),
        ):
            with self.assertRaises(WATERFOX.FaviconFetchError):
                WATERFOX.fetch_icon(
                    "example.test", [("https://example.test/", 0)], 1, report=attempts.append
                )
            output = io.StringIO()
            with redirect_stdout(output):
                WATERFOX.log_failure("example.test")
        self.assertTrue(any("https://" in attempt for attempt in attempts))
        self.assertNotIn("https://", output.getvalue())
        self.assertEqual(output.getvalue(), "No favicon: example.test\n")


if __name__ == "__main__":
    unittest.main()
