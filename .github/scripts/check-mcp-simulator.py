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

BUNDLE = "dev.tjb.SaveStateDemo"


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
            message = json.loads(self.lines.get(timeout=40))
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

    failed, text = server.call("savestate_list_apps")
    apps = json.loads(text) if not failed else []
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
    expect(not failed and "this launch" in text, "a set is scoped to this launch", text)

    if len(sys.argv) > 3:
        subprocess.run(["xcrun", "simctl", "io", udid, "screenshot", sys.argv[3]], check=True)

    server.process.stdin.close()
    server.process.terminate()


if __name__ == "__main__":
    main()
