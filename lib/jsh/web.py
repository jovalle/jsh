"""HTTPS downloads with mandatory SHA-256 verification, and JSON metadata fetches."""

import hashlib
import json
import urllib.request


def metadata(url):
    request = urllib.request.Request(url, headers={"User-Agent": "jsh"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def download(url, target, digest):
    if not url.startswith("https://"):
        raise ValueError(f"downloads require HTTPS: {url}")
    if not digest or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
        raise ValueError(f"a SHA-256 digest is required for {url}")
    request = urllib.request.Request(url, headers={"User-Agent": "jsh"})
    checksum = hashlib.sha256()
    with urllib.request.urlopen(request, timeout=120) as response, open(target, "wb") as stream:
        while True:
            block = response.read(1024 * 1024)
            if not block:
                break
            checksum.update(block)
            stream.write(block)
    if checksum.hexdigest() != digest:
        raise ValueError(f"checksum mismatch for {url}")
