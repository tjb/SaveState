# Upstream issue: URLSession never calls back after cancel under the swift.org 6.4.2 Swift Testing runner

**Status:** filed as [swiftlang/swift-testing#2032](https://github.com/swiftlang/swift-testing/issues/2032).
It comes from SaveState [#27](https://github.com/tjb/SaveState/issues/27).

Everything below the line is the issue text. The filed issue also ends with a
Related section linking swiftlang/swift#91716.

---

## Description

On macOS, a Swift Testing test built and run with the swift.org 6.4.2 toolchain
cancels a `URLSessionWebSocketTask` that has a `send` pending. URLSession then
never calls the send's completion handler, so an `await` on the send never
resumes and the test hangs forever.

The same code behaves correctly in three other setups:

- XCTest, built with the same swift.org compiler
- Swift Testing under Xcode's toolchain
- a plain executable

In each of them, the completion handler runs within milliseconds with
`NSURLErrorDomain -999 "cancelled"`.

## Environment

- macOS 26.6.2 (25G83), arm64
- swift.org toolchain: `Apple Swift version 6.4.2 (swift-6.4.2-RELEASE)`,
  `org.swift.642202610261a`, installed with swiftly 1.2.0. The runner prints
  `Testing Library Version: 6.4.2 (288a2328ff84644)`.
- Xcode 27.2 (27B52), `swiftlang-6.4.2.1.9`. The runner prints
  `Testing Library Version: 2403`.
- Both builds load Foundation, CFNetwork and `libswift_Concurrency.dylib` from the
  OS.

## Reproduction

This package has no dependencies. The server accepts TCP and never completes the
WebSocket upgrade, so the client's first `send` stays pending.

`Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WebSocketCancelRepro",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "Repro"),
        .testTarget(name: "ReproTests", dependencies: ["Repro"]),
    ]
)
```

`Sources/Repro/Repro.swift`:

```swift
import Foundation
import Network

public func log(_ s: String) { FileHandle.standardError.write(Data("REPRO \(s)\n".utf8)) }

/// Sends a WebSocket message to a server that accepts TCP and never upgrades,
/// racing the send against a 500 ms timeout. On timeout the group is cancelled,
/// and the cancellation handler cancels the socket task, which should end the send.
public func sendToAServerThatNeverUpgrades(withCompletionHandler: Bool = false) async throws -> String {
    let queue = DispatchQueue(label: "listener")
    let listener = try NWListener(using: .tcp, on: .any)
    defer { listener.cancel() }
    listener.newConnectionHandler = { $0.start(queue: queue) }
    let port: UInt16 = await withCheckedContinuation { c in
        nonisolated(unsafe) var pending: CheckedContinuation<UInt16, Never>? = c
        listener.stateUpdateHandler = { if case .ready = $0 { pending?.resume(returning: listener.port!.rawValue); pending = nil } }
        listener.start(queue: queue)
    }
    let task = URLSession(configuration: .ephemeral).webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
    task.resume()
    return try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask {
            try await withTaskCancellationHandler {
                log("send started")
                if withCompletionHandler {
                    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                        task.send(.string("hello")) { error in
                            log("completion handler called: \(String(describing: error))")
                            if let error { c.resume(throwing: error) } else { c.resume() }
                        }
                    }
                } else {
                    try await task.send(.string("hello"))
                }
                log("send returned")
                return "sent"
            } onCancel: {
                log("onCancel: cancelling the socket task")
                task.cancel(with: .normalClosure, reason: nil)
            }
        }
        group.addTask {
            try await Task.sleep(for: .milliseconds(500))
            log("timeout fired")
            return "timed out"
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
```

`Tests/ReproTests/ReproTests.swift`:

```swift
import Testing
import Repro

@Test func aCancelledSendToAServerThatNeverUpgradesReturns() async throws {
    let result = try await sendToAServerThatNeverUpgrades()
    log("group returned: \(result)")
    #expect(result == "timed out")
}

@Test func aCancelledCompletionHandlerSendReturns() async throws {
    let result = try await sendToAServerThatNeverUpgrades(withCompletionHandler: true)
    log("group returned: \(result)")
    #expect(result == "timed out")
}
```

`Tests/ReproTests/XCTestRepro.swift`, the same calls under XCTest:

```swift
import XCTest
import Repro

final class XCTestRepro: XCTestCase {
    func testACancelledCompletionHandlerSendReturns() async throws {
        let result = try await sendToAServerThatNeverUpgrades(withCompletionHandler: true)
        log("XCTest group returned: \(result)")
        XCTAssertEqual(result, "timed out")
    }

    func testACancelledAsyncSendReturns() async throws {
        let result = try await sendToAServerThatNeverUpgrades()
        log("XCTest async group returned: \(result)")
        XCTAssertEqual(result, "timed out")
    }
}
```

Commands, where `$TC` is `~/Library/Developer/Toolchains/swift-6.4.2-RELEASE.xctoolchain/usr/bin`:

```bash
/usr/bin/swift test --disable-xctest                                         # Xcode, Swift Testing: passes
$TC/swift test --scratch-path .build-oss --disable-swift-testing             # swift.org, XCTest: passes
$TC/swift test --scratch-path .build-oss --disable-xctest \
  --filter aCancelledCompletionHandlerSendReturns                            # swift.org, Swift Testing: hangs
```

Under the swift.org Swift Testing runner, stderr didn't reach a redirected log
before the hung run was killed. The `REPRO` lines below for that case were written
to a file instead.

## Expected behavior

`cancel(with:reason:)` ends the pending `send`. Its completion handler runs with
`NSURLErrorDomain -999`, the async `send` throws, the group returns `"timed out"`,
and the test passes in about 0.5 s.

## Actual behavior

| Built with | Runner | Completion handler after `cancel(with:reason:)` | Result |
| --- | --- | --- | --- |
| swift.org 6.4.2 | Swift Testing (`swiftpm-testing-helper`) | Never called | Hangs (killed after 2 min) |
| swift.org 6.4.2 | XCTest (`xctest`, `--disable-swift-testing`) | Called 1 ms after the cancel, `-999 "cancelled"` | Passes, 0.52 s per test |
| Xcode 27.2 | Swift Testing (`swiftpm-testing-helper`) | Called 4 ms after the cancel, `-999 "cancelled"` | Passes, 0.55 s |

The async `task.send` variant behaves the same in every row. The same code as a
plain executable built with `swiftc` returns in about 535 ms under both toolchains.

The hanging run's log:

```
REPRO send started
REPRO timeout fired         (about 0.5 s later)
REPRO onCancel: cancelling the socket task
<nothing more>
```

A passing run's log, for comparison (Xcode 27.2):

```
REPRO send started
REPRO timeout fired
REPRO onCancel: cancelling the socket task
REPRO completion handler called: Optional(Error Domain=NSURLErrorDomain Code=-999 "cancelled" ...)
REPRO group returned: timed out
```

`sample` of the hung `swiftpm-testing-helper` shows 0% CPU and only two threads.
Neither thread is in test, URLSession or Testing code:

```
Thread_1  DispatchQueue_1: com.apple.main-thread  (serial)
  main (in swiftpm-testing-helper) -> Entrypoint.main() -> main (in ReproTests, test_entry_point.swift)
  -> swift_task_asyncMainDrainQueue -> DispatchMainExecutor RunLoopExecutor.run()
  -> CFMainExecutor.run() -> CFRunLoopRun -> __CFRunLoopServiceMachPort -> mach_msg2_trap
Thread_2
  start_wqthread -> _pthread_wqthread -> __workq_kernreturn
```

lldb can attach, but `language swift task list` finds no tasks in this process.
`swift-inspect dump-concurrency` needs root.

## Observation: swift.org builds load two copies of Swift Testing

Both swift.org-built test processes load two copies of Swift Testing, including
the XCTest run, which passes. So the duplicate alone doesn't cause the hang.
Whether it plays any part is an open question, discussed below.

`vmmap` of each test process, lines that mention Testing:

| Process | Swift Testing images loaded |
| --- | --- |
| swift.org 6.4.2, Swift Testing (hangs) | toolchain `usr/lib/swift/macosx/testing/libTesting.dylib` and `lib_TestingInterop.dylib`, **and** Xcode `Testing.framework` and `_Testing_Foundation.framework` |
| swift.org 6.4.2, XCTest (passes) | the same four |
| Xcode 27.2, Swift Testing (passes) | Xcode `Testing.framework`, `_Testing_Foundation.framework` and `usr/lib/lib_TestingInterop.dylib` only |

Here's how the second copy arrives. `otool -L` of the swift.org-built test binary
shows it links both the toolchain's Swift Testing and Xcode's XCTest support:

```
@rpath/XCTest.framework/Versions/A/XCTest
@rpath/libXCTestSwiftSupport.dylib
@rpath/libTesting.dylib
```

Its rpaths include both
`~/Library/Developer/Toolchains/swift-6.4.2-RELEASE.xctoolchain/usr/lib/swift-6.2/macosx`
and Xcode's `Platforms/MacOSX.platform` paths. Xcode's
`libXCTestSwiftSupport.dylib` links `@rpath/Testing.framework` and
`@rpath/_Testing_Foundation.framework`, which resolve to Xcode's copies. SwiftPM
links XCTest even when the target has no XCTest code: SaveState's
`SaveStateClientKitTests` has none and links the same three.
`-Xlinker -dead_strip_dylibs` doesn't remove them.

## What this rules out, and what it doesn't

- **The compiler's async bridge for the Objective-C method:** with a hand-written
  continuation around `send(_:completionHandler:)`, the handler still never runs.
- **Foundation and CFNetwork alone:** they're the same OS binaries in every row, and
  they call the handler under XCTest built by the same compiler.
- **The two copies of Swift Testing alone:** the XCTest process loads both copies
  and passes.

**Still open:** whether the duplicate copy is needed for the hang at all, or
whether the swift.org Swift Testing host would hang without it. I couldn't build
a swift.org Swift Testing binary without Xcode's XCTest support to test that. The
host differs from the passing XCTest one in how it runs `main`: an async main
drained by `CFMainExecutor` on the main run loop, which is the setup
[swiftlang/swift#91716](https://github.com/swiftlang/swift/issues/91716) is
about. URLSession's callback for the cancelled task seems not to be delivered
under that setup.

## Workaround

Build and test with Xcode's toolchain (`swiftly use xcode`). Or make the waiting
code not depend on the callback: SaveState 0.2.1 returns on timeout without
waiting for the cancelled socket.
