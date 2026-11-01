#!/usr/bin/env python3
"""Drives the demo app in a simulator through the real `savestate mcp` server.

Usage: check-mcp-simulator.py <path to savestate> <simulator udid> [screenshot.png]

The demo must be running in the booted simulator. Nothing here taps the screen.
"""
import json
import queue
import subprocess
import sys
import threading
import time

BUNDLE = "dev.tjb.SaveStateDemo"
# Long enough for a slow boot, and short enough to report a hung simulator rather than
# run into the job's timeout.
RETRY_SECONDS = 300


class Server:
    def __init__(self, path):
        self.process = subprocess.Popen(
            [path, "mcp"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        self.lines = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()
        self.next_id = 0

    def _read(self):
        for line in self.process.stdout:
            self.lines.put(line)

    def _send(self, message):
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def request(self, method, params):
        self.next_id += 1
        self._send({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params})
        while True:
            message = json.loads(self.lines.get(timeout=120))
            if message.get("id") == self.next_id:
                if "error" in message:
                    raise SystemExit(f"{method} failed: {message['error']}")
                return message["result"]

    def notify(self, method):
        self._send({"jsonrpc": "2.0", "method": method})

    def call(self, name, **arguments):
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        text = "".join(item.get("text", "") for item in result["content"])
        return bool(result.get("isError")), text


def expect(condition, message, detail=""):
    if not condition:
        raise SystemExit(f"FAILED: {message}\n{detail}")
    print(f"ok: {message}")


def read_value(server, key):
    failed, text = server.call("savestate_read", app=BUNDLE, key=key)
    return None if failed else json.loads(text)["value"]


def relaunch(server, udid):
    """Relaunches the demo and waits for its new endpoint to answer."""
    subprocess.run(["xcrun", "simctl", "terminate", udid, BUNDLE], check=True)
    subprocess.run(["xcrun", "simctl", "launch", udid, BUNDLE], check=True, stdout=subprocess.DEVNULL)
    deadline = time.monotonic() + RETRY_SECONDS
    while time.monotonic() < deadline:
        failed, text = server.call("savestate_describe", app=BUNDLE)
        if not failed:
            return
        print(f"retrying: the demo isn't back yet: {text}")
        time.sleep(0.5)
    raise SystemExit("FAILED: the demo didn't come back after a relaunch")


def main():
    path, udid = sys.argv[1], sys.argv[2]
    server = Server(path)
    server.request(
        "initialize",
        {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "check-mcp-simulator", "version": "0"},
        },
    )
    server.notify("notifications/initialized")

    tools = {tool["name"] for tool in server.request("tools/list", {})["tools"]}
    expect(
        tools
        == {
            "savestate_list_apps",
            "savestate_describe",
            "savestate_set",
            "savestate_run_action",
            "savestate_apply_scenario",
            "savestate_read",
        },
        "the server advertises the six tools",
        tools,
    )

    # A simulator that just booted can be slow to answer, and the app slow to listen.
    deadline = time.monotonic() + RETRY_SECONDS
    while True:
        failed, text = server.call("savestate_list_apps")
        apps = json.loads(text) if not failed else []
        if any(a["bundleIdentifier"] == BUNDLE and a["device"] == udid for a in apps):
            break
        print(f"retrying: the demo isn't listed yet: {text}")
        if time.monotonic() > deadline:
            break
        time.sleep(3)
    expect(any(a["bundleIdentifier"] == BUNDLE and a["device"] == udid for a in apps), "it finds the demo", text)
    expect("token" not in text, "the listing leaves out the token", text)

    failed, text = server.call("savestate_describe", app=BUNDLE)
    expect(not failed and "expired-trial" in text, "it describes the demo", text)

    failed, text = server.call("savestate_apply_scenario", app=BUNDLE, key="expired-trial")
    expect(not failed, "it applies expired-trial", text)

    failed, text = server.call("savestate_read", app=BUNDLE, key="premium")
    control = json.loads(text) if not failed else {}
    expect(control.get("value") == {"type": "bool", "value": False}, "the scenario turned premium off", text)

    failed, text = server.call("savestate_read", app=BUNDLE, key="clock")
    control = json.loads(text) if not failed else {}
    expect(control.get("value", {}).get("type") == "date", "the scenario moved the clock", text)

    failed, text = server.call("savestate_run_action", app=BUNDLE, key="erase")
    expect(failed and "destructive" in text, "it refuses a destructive action", text)

    failed, text = server.call("savestate_set", app=BUNDLE, key="project-limit", value=9)
    expect(not failed and "this launch" in text, "it sets a control", text)
    expect(read_value(server, "project-limit") == {"type": "int", "value": 9}, "the app holds the new value")

    if len(sys.argv) > 3:
        subprocess.run(["xcrun", "simctl", "io", udid, "screenshot", sys.argv[3]], check=True)

    relaunch(server, udid)
    expect(
        read_value(server, "project-limit") == {"type": "int", "value": 3},
        "a session write is gone after a relaunch",
    )

    server.process.stdin.close()
    server.process.terminate()


if __name__ == "__main__":
    main()
