#!/usr/bin/env python3
"""Drives the demo app in a simulator through the real `savestate mcp` server.

Usage: check-mcp-simulator.py <path to savestate> <simulator udid> [screenshot.png]

The demo must be running in the booted simulator. Nothing here taps the screen.
"""
import json
import queue
import re
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


def timed_call(server, name, **arguments):
    """Calls a tool and returns whether it failed, its text, and the call's wall time in ms."""
    start = time.monotonic()
    failed, text = server.call(name, **arguments)
    return failed, text, round((time.monotonic() - start) * 1000)


def check_wait_timing(server):
    """Checks savestate_wait through the real server, and that it reports its timing.

    The seed-projects scenario counts item-count up from 0 to 5, one every 100 ms.
    This doesn't prove the wait woke on observation rather than its 100 ms tick, or
    that it had to wait at all: the bridge runs simctl to find the app before each
    wait starts its clock, which takes about 200 ms locally and can outlast the whole
    500 ms climb on CI, so the count may already be met. ProbeWaitTests proves the
    observation wake with a 10 s tick, so this only checks the timing is reported
    and plausible.
    """
    before = read_value(server, "item-count")
    expect(before is not None and before.get("type") == "int", "it reads the item-count probe", before)

    failed, text = server.call("savestate_apply_scenario", app=BUNDLE, key="seed-projects")
    expect(not failed, "it applies seed-projects", text)
    met_failed, met_text, met_wall = timed_call(
        server,
        "savestate_wait",
        app=BUNDLE,
        key="item-count",
        condition="atLeast",
        value=3,
        timeoutSeconds=5,
    )
    met = json.loads(met_text) if not met_failed else {}

    missed_failed, missed_text, missed_wall = timed_call(
        server,
        "savestate_wait",
        app=BUNDLE,
        key="item-count",
        condition="equals",
        value=999,
        timeoutSeconds=1,
    )
    match = re.search(r"The wait took (\d+) ms\.$", missed_text)
    missed_waited = int(match.group(1)) if match else None

    print("----- BEGIN savestate_wait timing -----")
    print(f"item-count before seed-projects: {json.dumps(before)}")
    print()
    print("savestate_wait item-count atLeast 3 (timeoutSeconds 5)")
    print(f"isError: {met_failed}; whole call: {met_wall} ms")
    print(met_text)
    if not met_failed:
        print(f"finding the app and the round trip: {met_wall - met.get('waitedMilliseconds', 0)} ms")
    print()
    print("savestate_wait item-count equals 999 (timeoutSeconds 1)")
    print(f"isError: {missed_failed}; whole call: {missed_wall} ms")
    print(missed_text)
    print("----- END savestate_wait timing -----")

    expect(not met_failed, "the wait for at least 3 projects succeeds", met_text)
    # Seeding stops at 5, so more means a cancelled run added a project.
    expect(3 <= met.get("value", {}).get("value", -1) <= 5, "the wait returns a count from 3 to 5", met_text)
    waited = met.get("waitedMilliseconds")
    expect(isinstance(waited, int) and waited < 1000, "the wait woke within a second", met_text)

    expect(missed_failed and "didn't meet the condition" in missed_text, "a wait for 999 times out", missed_text)
    expect(
        missed_waited is not None and abs(missed_waited - 1000) <= 200,
        "the timed-out wait took about its 1 s timeout",
        missed_text,
    )


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
            "savestate_wait",
        },
        "the server advertises the seven tools",
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

    check_wait_timing(server)

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
