#!/usr/bin/env python3
"""Drive a private FilmCraft session without changing the user's preferences."""

import argparse
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time


class FilmcraftSession:
    def __init__(self, output):
        self.directory = Path(tempfile.mkdtemp(prefix="filmcraft-", dir=output))
        self.token = secrets.token_hex(32)
        self.process = None
        self.connection = None
        self.stream = None
        self.request_id = 0

    def __enter__(self):
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        environment = os.environ.copy()
        environment["FILMCRAFT_CONTROL_TOKEN"] = self.token
        self.log = (self.directory / "app.log").open("w")
        self.process = subprocess.Popen(
            [
                "/Applications/FilmCraft.app/Contents/MacOS/FilmCraft",
                "--control", str(port), "--no-recover",
                "--data-dir", str(self.directory),
            ],
            env=environment, stdin=subprocess.DEVNULL,
            stdout=self.log, stderr=self.log,
        )
        try:
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                if self.process.poll() is not None:
                    raise RuntimeError(f"FilmCraft exited; see {self.directory / 'app.log'}")
                try:
                    self.connection = socket.create_connection(("127.0.0.1", port), timeout=1)
                    self.connection.settimeout(120)
                    self.stream = self.connection.makefile("rw")
                    self.catalog = self.request("engine.commands")
                    return self
                except (ConnectionRefusedError, TimeoutError):
                    time.sleep(0.2)
            raise RuntimeError(f"FilmCraft did not start; see {self.directory / 'app.log'}")
        except BaseException:
            self.close()
            raise

    def request(self, method, **params):
        deadline = time.monotonic() + 45
        while True:
            self.request_id += 1
            self.stream.write(json.dumps({
                "id": self.request_id, "token": self.token,
                "method": method, "params": params,
            }) + "\n")
            self.stream.flush()
            line = self.stream.readline()
            if not line:
                raise RuntimeError("FilmCraft closed its control connection")
            reply = json.loads(line)
            if reply.get("ok"):
                return reply.get("result")
            error = reply.get("error", "unknown control error")
            if "still starting; send the request again" in str(error) and time.monotonic() < deadline:
                time.sleep(0.2)
                continue
            raise RuntimeError(f"{method}: {error}")

    def execute(self, command, **params):
        return self.request("engine.execute", command=command, params=params)

    def close(self):
        if self.stream is not None:
            try:
                self.connection.settimeout(3)
                self.request("app.quit")
            except (OSError, RuntimeError, ValueError):
                pass
            self.stream.close()
        if self.connection is not None:
            self.connection.close()
        if self.process is not None:
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                self.process.wait(timeout=5)
            self.log.close()

    def __exit__(self, *_):
        self.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("filters", nargs="*")
    arguments = parser.parse_args()
    arguments.output.mkdir(parents=True, exist_ok=True)
    with FilmcraftSession(arguments.output) as filmcraft:
        catalog = filmcraft.catalog
        (filmcraft.directory / "commands.json").write_text(json.dumps(catalog, indent=2) + "\n")
        commands = catalog.get("commands", []) if isinstance(catalog, dict) else catalog
        print(json.dumps({"session": str(filmcraft.directory), "commandCount": len(commands)}))
        for entry in commands:
            if not arguments.filters or any(term in entry["id"] for term in arguments.filters):
                print(json.dumps(entry))
