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
# How long after sending a wait to apply the scenario it waits for. The bridge finds
# the app with simctl before the wait's clock starts, which takes about 200 ms locally
# and over a second on CI.
SEED_DELAY_SECONDS = 3


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

    def start(self):
        self.request(
            "initialize",
            {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "check-mcp-simulator", "version": "0"},
            },
        )
        self.notify("notifications/initialized")

    def stop(self):
        self.process.stdin.close()
        self.process.terminate()

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


def check_wait_timing(server, path):
    """Checks that savestate_wait wakes on a change, through the real server.

    The wait starts before seed-projects runs, which counts item-count up from 0 to
    5, one every 100 ms. The scenario goes through a second server, because the
    first is busy with the wait. The bridge finds the app with simctl before a
    wait's clock starts, so the scenario is applied a few seconds after the wait is
    sent, and the check proves from waitedMilliseconds that the wait's clock had
    started before the scenario was applied.
    """
    before = read_value(server, "item-count")
    expect(
        before is not None and before.get("type") == "int" and before.get("value", 3) < 3,
        "item-count starts below 3",
        before,
    )

    waiting = {}

    def wait():
        waiting["result"] = timed_call(
            server,
            "savestate_wait",
            app=BUNDLE,
            key="item-count",
            condition="atLeast",
            value=3,
            timeoutSeconds=SEED_DELAY_SECONDS + 5,
        )
        waiting["ended"] = time.monotonic()

    wait_sent = time.monotonic()
    waiter = threading.Thread(target=wait)
    waiter.start()
    time.sleep(SEED_DELAY_SECONDS)

    seeder = Server(path)
    seeder.start()
    seed_sent = time.monotonic()
    failed, text = seeder.call("savestate_apply_scenario", app=BUNDLE, key="seed-projects")
    seed_returned = time.monotonic()
    seeder.stop()
    expect(not failed, "it applies seed-projects while the wait runs", text)
    expect("ended" not in waiting, "the wait was still running when the scenario returned")

    waiter.join(timeout=SEED_DELAY_SECONDS + 30)
    expect("result" in waiting, "the wait returned")
    met_failed, met_text, met_wall = waiting["result"]
    met = json.loads(met_text) if not met_failed else {}
    waited = met.get("waitedMilliseconds")
    # When the wait's clock started, as seen from here. The response's trip back only
    # moves this later, so a start before seed_sent proves the wait was already running.
    clock_started = waiting["ended"] - (waited or 0) / 1000
    # The scenario has run by the time its call returns; the third project arrives
    # about 300 ms after that.
    after_seed = round((waiting["ended"] - seed_returned) * 1000)

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
    print(f"item-count before the wait: {json.dumps(before)}")
    print()
    print(f"savestate_wait item-count atLeast 3 (timeoutSeconds {SEED_DELAY_SECONDS + 5}), sent first")
    print(f"seed-projects applied {round((seed_sent - wait_sent) * 1000)} ms after the wait was sent")
    print(f"and returned {round((seed_returned - seed_sent) * 1000)} ms later")
    print(f"wait's clock started {round((seed_sent - clock_started) * 1000)} ms before seed-projects was applied")
    print(f"wait returned {after_seed} ms after seed-projects returned")
    print(f"isError: {met_failed}; whole call: {met_wall} ms")
    print(met_text)
    print()
    print("savestate_wait item-count equals 999 (timeoutSeconds 1)")
    print(f"isError: {missed_failed}; whole call: {missed_wall} ms")
    print(missed_text)
    print("----- END savestate_wait timing -----")

    expect(not met_failed, "the wait for at least 3 projects succeeds", met_text)
    # Seeding stops at 5, so more means a cancelled run added a project.
    expect(3 <= met.get("value", {}).get("value", -1) <= 5, "the wait returns a count from 3 to 5", met_text)
    expect(isinstance(waited, int), "the wait reports waitedMilliseconds", met_text)
    expect(clock_started < seed_sent, "the wait was waiting before seed-projects was applied", met_text)
    expect(waiting["ended"] > seed_returned, "the wait returned after seed-projects ran")
    expect(after_seed < 1000, "the wait woke within a second of seed-projects returning", f"{after_seed} ms")

    expect(missed_failed and "didn't meet the condition" in missed_text, "a wait for 999 times out", missed_text)
    expect(
        missed_waited is not None and abs(missed_waited - 1000) <= 200,
        "the timed-out wait took about its 1 s timeout",
        missed_text,
    )


def main():
    path, udid = sys.argv[1], sys.argv[2]
    server = Server(path)
    server.start()

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

    check_wait_timing(server, path)

    if len(sys.argv) > 3:
        subprocess.run(["xcrun", "simctl", "io", udid, "screenshot", sys.argv[3]], check=True)

    relaunch(server, udid)
    expect(
        read_value(server, "project-limit") == {"type": "int", "value": 3},
        "a session write is gone after a relaunch",
    )

    server.stop()


if __name__ == "__main__":
    main()
