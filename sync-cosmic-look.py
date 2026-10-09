#!/usr/bin/env python3
"""Set COSMIC desktop/lock and Noctalia boot greeter to one wallpaper.

Run as your normal desktop user. The boot-greeter step asks sudo for access.
"""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime


GREETER_DIR = Path("/var/lib/noctalia-greeter")
THEME = Path(__file__).with_name("cosmic-lock-theme.ron")


def active_output_files(directory: Path):
    return sorted(path for path in directory.glob("output.*")
                  if not re.search(r"\.backup-\d{8}-\d{6}", path.name))


def atomic_write(path: Path, data: bytes, *, owner=None, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(name, mode)
        if owner is not None:
            os.chown(name, *owner)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def backup_once(path: Path):
    if path.exists():
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        backup = path.with_name(f"{path.name}.backup-{stamp}")
        if not backup.exists():
            shutil.copy2(path, backup)


def validate_image(path: Path):
    try:
        from PIL import Image
    except ImportError as error:
        raise RuntimeError("Pillow is required to verify the wallpaper image") from error
    with Image.open(path) as image:
        if image.format not in {"JPEG", "PNG", "WEBP"}:
            raise RuntimeError(f"Unsupported wallpaper format: {image.format}")
        image.verify()


def current_cosmic_background(config_home: Path) -> Path:
    """Read the image selected in COSMIC's desktop wallpaper settings."""
    directory = config_home / "cosmic/com.system76.CosmicBackground/v1"
    slideshow = directory / "backgrounds"
    if slideshow.exists() and slideshow.read_text().strip() != "[]":
        raise RuntimeError("A wallpaper slideshow is configured; use -file with the image you want")

    same = directory / "same-on-all"
    if not same.exists() or same.read_text().strip() == "true":
        entries = [directory / "all"]
    else:
        entries = active_output_files(directory)
        if not entries:
            raise RuntimeError("No per-display COSMIC wallpaper was found; use -file")

    images = set()
    for entry in entries:
        if not entry.exists():
            raise RuntimeError(f"COSMIC wallpaper setting is missing: {entry}; use -file")
        match = re.search(r'(?m)^\s*source:\s*Path\(("(?:\\.|[^"\\])*")\),',
                          entry.read_text())
        if match is None:
            raise RuntimeError(f"COSMIC wallpaper is not a single image in {entry}; use -file")
        images.add(Path(json.loads(match.group(1))).expanduser())
    if len(images) != 1:
        raise RuntimeError("Displays use different wallpapers; use -file to choose one image")
    return images.pop().resolve(strict=True)


def update_cosmic_background(image: Path, config_home: Path):
    # COSMIC 1.8's locker reads this same user's CosmicBackground state.
    directory = config_home / "cosmic/com.system76.CosmicBackground/v1"
    default = Path("/usr/share/cosmic/com.system76.CosmicBackground/v1/all")
    files = [directory / "all", *active_output_files(directory)]
    for path in files:
        old = path.read_text() if path.exists() else default.read_text()
        quoted = json.dumps(str(image))
        new, count = re.subn(
            r'(?m)^(\s*source:\s*)\S+\([^\n]*\),\s*$',
            lambda match: f"{match.group(1)}Path({quoted}),",
            old,
            count=1,
        )
        if count != 1:
            raise RuntimeError(f"Could not find a wallpaper source in {path}")
        new = re.sub(r"(?m)^(\s*filter_by_theme:\s*)(?:true|false)", r"\1false", new)
        if new != old or not path.exists():
            backup_once(path)
            atomic_write(path, new.encode())
            print(f"COSMIC: {path} -> {image}")
    same = directory / "same-on-all"
    if not same.exists() or same.read_text().strip() != "true":
        backup_once(same)
        atomic_write(same, b"true")


def refresh_cosmic_background_state(image: Path, config_home: Path):
    """Update the state COSMIC Greeter reads and notify its live watcher."""
    state_home = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
    state = state_home / "cosmic/com.system76.CosmicBackground/v1/wallpapers"
    quoted = json.dumps(str(image))
    if state.exists():
        old = state.read_text()
        new, count = re.subn(r'Path\("(?:\\.|[^"\\])*"\)',
                             lambda _: f"Path({quoted})", old)
        if count == 0:
            raise RuntimeError(f"No image wallpaper found in COSMIC state: {state}")
    else:
        config = config_home / "cosmic/com.system76.CosmicBackground/v1"
        outputs = [p.name.removeprefix("output.") for p in active_output_files(config)]
        if not outputs:
            raise RuntimeError("No COSMIC displays found for lock wallpaper state")
        new = "[\n" + "".join(f"    ({json.dumps(output)}, Path({quoted})),\n"
                              for output in outputs) + "]"
        old = None
    if old != new:
        backup_once(state)
    state.parent.mkdir(parents=True, exist_ok=True)
    # Keep the inode: cosmic-greeter's config-state subscription watches this
    # state file while the session is running.
    with state.open("w") as stream:
        stream.write(new)
        stream.flush()
        os.fsync(stream.fileno())
    print(f"COSMIC lock state: {state} -> {image}")


def update_boot_greeter(image: Path):
    # This helper is entered only through sudo from main().
    import tomlkit

    state = GREETER_DIR.stat()
    owner = (state.st_uid, state.st_gid)
    target = GREETER_DIR / f"wallpaper-cosmic-sync{image.suffix.lower()}"
    atomic_write(target, image.read_bytes(), owner=owner)

    config = GREETER_DIR / "greeter.toml"
    sync = GREETER_DIR / "sync.toml"
    doc = tomlkit.parse(config.read_text() if config.exists() else "")
    appearance = doc.get("appearance")
    if appearance is None:
        appearance = tomlkit.table()
        doc["appearance"] = appearance
    wallpaper = appearance.get("wallpaper")
    if wallpaper is None:
        wallpaper = tomlkit.table()
        appearance["wallpaper"] = wallpaper
    wallpaper["path"] = str(target)
    wallpaper["fill_mode"] = "crop"

    # An output-specific wallpaper takes priority over the global one.
    outputs = set()
    for source in (doc, tomlkit.parse(sync.read_text()) if sync.exists() else {}):
        output_table = source.get("appearance", {}).get("wallpapers", {})
        outputs.update(output_table.keys())
    if outputs:
        wallpapers = appearance.get("wallpapers")
        if wallpapers is None:
            wallpapers = tomlkit.table()
            appearance["wallpapers"] = wallpapers
        for output in sorted(outputs):
            entry = wallpapers.get(output)
            if entry is None:
                entry = tomlkit.table()
                wallpapers[output] = entry
            entry["path"] = str(target)
            entry["fill_mode"] = "crop"

    old = config.read_bytes() if config.exists() else None
    new = tomlkit.dumps(doc).encode()
    if old != new:
        backup_once(config)
        atomic_write(config, new, owner=owner)
    print(f"Boot greeter: {target}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", nargs="?", choices=["current"],
                        help="copy the current desktop wallpaper to lock and boot screens")
    parser.add_argument("-file", "--file", type=Path,
                        help='your wallpaper path, for example -file "~/Pictures/wallpaper.png"')
    parser.add_argument("--skip-theme", action="store_true", help="leave the COSMIC theme alone")
    parser.add_argument("--skip-boot", action="store_true", help="leave the boot greeter alone (no sudo)")
    parser.add_argument("--dry-run", action="store_true", help="show intended changes only")
    parser.add_argument("--boot-helper", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.mode == "current" and args.file is not None:
        parser.error("use either current or -file, not both")
    if args.mode is None and args.file is None:
        parser.error("provide current or -file PATH")
    if args.boot_helper and args.file is None:
        parser.error("--boot-helper requires -file PATH")
    config_home = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    image = (current_cosmic_background(config_home) if args.mode == "current"
             else args.file.expanduser().resolve(strict=True))
    validate_image(image)

    if args.boot_helper:
        if os.geteuid() != 0:
            raise RuntimeError("Boot helper must run through sudo")
        update_boot_greeter(image)
        return
    if os.geteuid() == 0:
        raise RuntimeError("Run this script as your normal desktop user, not with sudo")
    apply_theme = args.mode != "current" and not args.skip_theme
    if apply_theme and not THEME.is_file():
        raise RuntimeError(f"Missing theme file: {THEME}")
    print(f"Wallpaper: {image}")
    if args.dry_run:
        print("Would align COSMIC desktop and Super+Esc lock wallpaper"
              + (", Noctalia boot wallpaper" if not args.skip_boot else "")
              + (", and import the supplied dark theme." if apply_theme else "."))
        return

    # Obtain privilege before making user-level changes, so a cancelled prompt
    # does not leave desktop and boot wallpapers different.
    if not args.skip_boot:
        subprocess.run(["sudo", "-v"], check=True)
    if apply_theme:
        backup_dir = Path.home() / ".local/share/cosmic-look-backups"
        backup_dir.mkdir(parents=True, exist_ok=True)
        backup = backup_dir / f"theme-{datetime.now():%Y%m%d-%H%M%S}.ron"
        subprocess.run(["cosmic-settings", "appearance", "export", str(backup)], check=True)
        print(f"Previous theme: {backup}")
    update_cosmic_background(image, config_home)
    refresh_cosmic_background_state(image, config_home)
    if not args.skip_boot:
        subprocess.run(["sudo", sys.executable, str(Path(__file__).resolve()),
                        "--boot-helper", "-file", str(image)], check=True)
    if apply_theme:
        subprocess.run(["cosmic-settings", "appearance", "import", str(THEME)], check=True)
        print("Imported COSMIC dark theme.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(1)
