## 2024-05-18 - Avoid array allocations in tight loops

**Learning:** In periodic UI updates on macOS (like sampling active processes every 5 seconds), seemingly innocent standard library functions like `String.split()` and `.firstIndex()` can cause unnecessary object churn and CPU usage. Splitting paths is a common pattern that is computationally expensive if done for hundreds of background processes.

**Action:** For simple substring matches in paths, favor direct String range finding like `.range(of:)` and `.hasSuffix()` over splitting into arrays and joining.

## 2024-05-19 - Avoid String creations for C string prefix checks

**Learning:** When checking the prefix of a C string (`UnsafePointer<CChar>`) in a tight loop (e.g., polling network interfaces every 2 seconds), converting it to a Swift `String` just to use `.hasPrefix()` causes unnecessary object allocations and CPU overhead.

**Action:** For simple fixed ASCII prefixes, perform a direct byte comparison (e.g., `name[0] == 101 && name[1] == 110` for "en") on the pointer instead of instantiating a `String`.

## 2024-06-25 - Avoid String allocations in split operations

**Learning:** When reading output from external commands (like `ps` via `ProcessSession`) which return hundreds of lines, splitting the buffer and mapping it to new `String` instances (`.map(String.init)`) causes hundreds of unnecessary heap allocations per tick.

**Action:** For string splitting operations in tight polling loops, return and process `[Substring]` arrays. `Substring` acts as a view on the original buffer's memory, avoiding allocations. Convert to `String` only at the exact boundaries where external libraries or JSON serialization strictly requires it.

## 2024-09-06 - [Performance Improvement] Cache Mach Ports and Kernel Constants in Swift Polling Loops
**Learning:** In macOS system monitoring apps that poll for statistics frequently, repeatedly querying constant kernel values (like `host_page_size`) and initializing Mach ports (via `mach_host_self()`) inside the polling loop introduces unnecessary system call overhead and can lead to resource leaks.
**Action:** When working with periodic polling in Swift (e.g., using a `Timer` or polling loop), always cache invariants like kernel constants and Mach ports at initialization. Ensure proper cleanup of cached ports using `mach_port_deallocate()` in the `deinit` block to prevent resource leaks and port exhaustion.
