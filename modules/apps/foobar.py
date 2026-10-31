"""Install the macOS DSD decoder for foobar2000."""

import io
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

from jsh import apps, system, web

VERSION = "2.0.24"
URL = (
    "https://downloads.sourceforge.net/project/sacddecoder/macOS%20%2BWindows/"
    f"foo_input_udsd/foo_input_udsd-{VERSION}.zip"
)
SHA256 = "6dca1ebc7148cbdded9bfc10f8a1c31ebb13b8942be4884a9af539dbf617b7bf"
PREFIX = "mac/foo_input_udsd.component/"


def configure(ctx):
    components = Path.home() / "Library/foobar2000-v2/user-components"
    target = components / "foo_input_udsd.component"
    if target.exists() or (components / "foo_input_udsd").exists():
        ctx.current()
        return
    if ctx.dry_run:
        with apps.closed_for_changes(
            ctx, "foobar2000", ("foobar2000",), ["open", "-a", "foobar2000"]
        ) as ready:
            if ready:
                ctx.added("foobar2000 DSD decoder")
        return
    ctx.progress("downloading foobar2000 DSD decoder")
    (system.ROOT / "tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="foobar.", dir=system.ROOT / "tmp") as scratch:
        archive = Path(scratch) / "decoder.zip"
        web.download(URL, archive, SHA256)
        with zipfile.ZipFile(archive) as outer:
            package = outer.read("foo_input_udsd.fb2k-component")
        with zipfile.ZipFile(io.BytesIO(package)) as bundle:
            entries = [
                entry
                for entry in bundle.infolist()
                if entry.filename.startswith(PREFIX) and not entry.is_dir()
            ]
            names = {entry.filename[len(PREFIX) :] for entry in entries}
            if not {"Contents/Info.plist", "Contents/MacOS/foo_input_udsd"} <= names:
                raise ValueError("DSD decoder package is missing its macOS component")
            for entry in entries:
                relative = PurePosixPath(entry.filename[len(PREFIX) :])
                if relative.is_absolute() or ".." in relative.parts:
                    raise ValueError("invalid path in DSD decoder package")
                path = Path(scratch) / "component" / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(bundle.read(entry))
                path.chmod(0o755 if str(relative) == "Contents/MacOS/foo_input_udsd" else 0o644)
        with apps.closed_for_changes(
            ctx, "foobar2000", ("foobar2000",), ["open", "-a", "foobar2000"]
        ) as ready:
            if ready:
                components.mkdir(parents=True, exist_ok=True)
                (Path(scratch) / "component").rename(target)
                ctx.added("foobar2000 DSD decoder")
