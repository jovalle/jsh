"""Mute the Elgato Wave:3 when it first appears in a desktop session."""

import ctypes
import fcntl
import os
import subprocess
import sys
import time
from pathlib import Path

PREFIX = "alsa_input.usb-Elgato_Systems_Elgato_Wave_3_"


def sources():
    result = subprocess.run(
        ["pactl", "list", "short", "sources"],
        capture_output=True,
        text=True,
        check=True,
        timeout=1,
    )
    return {
        fields[0]
        for line in result.stdout.splitlines()
        if len(fields := line.split("\t")) >= 2 and fields[1].startswith(PREFIX)
    }


class UsbControl(ctypes.Structure):
    _fields_ = [
        ("request_type", ctypes.c_uint8),
        ("request", ctypes.c_uint8),
        ("value", ctypes.c_uint16),
        ("index", ctypes.c_uint16),
        ("length", ctypes.c_uint16),
        ("timeout", ctypes.c_uint32),
        ("data", ctypes.c_void_p),
    ]


def usb_device():
    devices = []
    for device in Path("/sys/bus/usb/devices").iterdir():
        try:
            if (device / "idVendor").read_text().strip() != "0fd9":
                continue
            if (device / "idProduct").read_text().strip() != "0070":
                continue
            bus = int((device / "busnum").read_text())
            number = int((device / "devnum").read_text())
            devices.append(Path(f"/dev/bus/usb/{bus:03d}/{number:03d}"))
        except (OSError, ValueError):
            continue
    if len(devices) != 1:
        raise OSError("Wave:3 device unavailable or ambiguous")
    return devices[0]


def usb_control(request_type, request_id, value, index, data):
    control = UsbControl(
        request_type, request_id, value, index, len(data), 1000, ctypes.addressof(data)
    )
    request = 0xC0000000 | (ctypes.sizeof(UsbControl) << 16) | (ord("U") << 8)
    fd = os.open(usb_device(), os.O_RDWR)
    try:
        length = fcntl.ioctl(fd, request, control)
    finally:
        os.close(fd)
    if length != len(data):
        raise OSError("short Wave:3 USB response")


def hardware_mute():
    data = (ctypes.c_ubyte * 16)()
    usb_control(0xA1, 0x85, 0, 0x3303, data)
    if data[4] not in (0, 1):
        raise OSError("invalid Wave:3 mute response")
    return bool(data[4])


def set_hardware_mute(muted):
    data = (ctypes.c_ubyte * 1)(int(muted))
    usb_control(0x21, 0x01, 0x0100, 0x0603, data)
    if hardware_mute() != muted:
        raise OSError("Wave:3 mute state did not change")


def set_mute(muted):
    if not muted:
        current = sources()
        if len(current) != 1:
            raise OSError("Wave:3 audio source unavailable or ambiguous")
        source = next(iter(current))
        result = subprocess.run(
            ["pactl", "get-source-mute", source],
            capture_output=True,
            text=True,
            check=True,
            timeout=1,
        )
        if result.stdout.strip() == "Mute: yes":
            subprocess.run(
                ["pactl", "set-source-mute", source, "0"],
                capture_output=True,
                check=True,
                timeout=1,
            )
        elif result.stdout.strip() != "Mute: no":
            raise OSError("Wave:3 software mute state unavailable")
    set_hardware_mute(muted)


def mute_hardware():
    set_hardware_mute(True)


def status():
    try:
        current = sources()
        if len(current) != 1:
            return "unavailable"
        result = subprocess.run(
            ["pactl", "get-source-mute", next(iter(current))],
            capture_output=True,
            text=True,
            check=True,
            timeout=1,
        )
        software = {"Mute: yes": True, "Mute: no": False}.get(result.stdout.strip())
        if software is None:
            return "unavailable"
        if hardware_mute() or software:
            return "muted"
        return "live"
    except (OSError, subprocess.SubprocessError):
        return "unavailable"


def panel():
    state = status()
    icon = Path(__file__).resolve().parent / f"microphone-{state}.svg"
    label = {"live": "Live", "muted": "Muted", "unavailable": "Unavailable"}[state]
    print(f"<img>{icon}</img><tool>Elgato Wave:3: {label}</tool>")


def update(seen):
    current = sources()
    seen.intersection_update(current)
    for source in current - seen:
        mute_hardware()
        seen.add(source)


def watch():
    seen = set()
    while True:
        try:
            update(seen)
        except (OSError, subprocess.SubprocessError):
            pass
        time.sleep(1)


if __name__ == "__main__":
    if sys.argv[1:] == ["--panel"]:
        panel()
    elif sys.argv[1:] in (["--mute"], ["--unmute"]):
        set_mute(sys.argv[1] == "--mute")
    else:
        watch()
