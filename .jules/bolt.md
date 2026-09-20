## 2024-05-18 - Avoid array allocations in tight loops

**Learning:** In periodic UI updates on macOS (like sampling active processes every 5 seconds), seemingly innocent standard library functions like `String.split()` and `.firstIndex()` can cause unnecessary object churn and CPU usage. Splitting paths is a common pattern that is computationally expensive if done for hundreds of background processes.

**Action:** For simple substring matches in paths, favor direct String range finding like `.range(of:)` and `.hasSuffix()` over splitting into arrays and joining.

## 2024-05-19 - Avoid String creations for C string prefix checks

**Learning:** When checking the prefix of a C string (`UnsafePointer<CChar>`) in a tight loop (e.g., polling network interfaces every 2 seconds), converting it to a Swift `String` just to use `.hasPrefix()` causes unnecessary object allocations and CPU overhead.

**Action:** For simple fixed ASCII prefixes, perform a direct byte comparison (e.g., `name[0] == 101 && name[1] == 110` for "en") on the pointer instead of instantiating a `String`.

## 2024-06-25 - Avoid String allocations in split operations

**Learning:** When reading output from external commands (like `ps` via `ProcessSession`) which return hundreds of lines, splitting the buffer and mapping it to new `String` instances (`.map(String.init)`) causes hundreds of unnecessary heap allocations per tick.

**Action:** For string splitting operations in tight polling loops, return and process `[Substring]` arrays. `Substring` acts as a view on the original buffer's memory, avoiding allocations. Convert to `String` only at the exact boundaries where external libraries or JSON serialization strictly requires it.

## 2024-07-28 - Cache Mach port and kernel constants in polling loops

**Learning:** In Swift polling loops on macOS, repeatedly calling system APIs like `mach_host_self()` and `host_page_size()` (e.g., inside `cpuPercent()` or `memoryBreakdown()`) every tick introduces unnecessary overhead and can cause resource leaks (port exhaustion) if the port is not correctly managed/deallocated.

**Action:** Cache these constants and initialized Mach ports during class initialization. Store the port in a property, re-use it during polling loops, and ensure proper cleanup using `mach_port_deallocate()` in the `deinit` block.

## 2024-09-20 - Bypass /usr/bin/env wrapper in Process loops

**Learning:** When using Swift's `Process` API inside tight polling loops, relying on the `/usr/bin/env` wrapper introduces significant `execve` and PATH resolution overhead on every tick. It also duplicates the command name in the `arguments` array unnecessarily.
**Action:** Bypass `/usr/bin/env` by resolving absolute paths manually (e.g., using `FileManager.default.isExecutableFile(atPath:)`) before setting `process.executableURL`. This saves process invocation overhead without losing functionality.
