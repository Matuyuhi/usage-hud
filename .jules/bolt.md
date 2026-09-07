## 2024-05-18 - Avoid array allocations in tight loops

**Learning:** In periodic UI updates on macOS (like sampling active processes every 5 seconds), seemingly innocent standard library functions like `String.split()` and `.firstIndex()` can cause unnecessary object churn and CPU usage. Splitting paths is a common pattern that is computationally expensive if done for hundreds of background processes.

**Action:** For simple substring matches in paths, favor direct String range finding like `.range(of:)` and `.hasSuffix()` over splitting into arrays and joining.

## 2024-05-19 - Avoid String creations for C string prefix checks

**Learning:** When checking the prefix of a C string (`UnsafePointer<CChar>`) in a tight loop (e.g., polling network interfaces every 2 seconds), converting it to a Swift `String` just to use `.hasPrefix()` causes unnecessary object allocations and CPU overhead.

**Action:** For simple fixed ASCII prefixes, perform a direct byte comparison (e.g., `name[0] == 101 && name[1] == 110` for "en") on the pointer instead of instantiating a `String`.

## 2024-06-25 - Avoid String allocations in split operations

**Learning:** When reading output from external commands (like `ps` via `ProcessSession`) which return hundreds of lines, splitting the buffer and mapping it to new `String` instances (`.map(String.init)`) causes hundreds of unnecessary heap allocations per tick.

**Action:** For string splitting operations in tight polling loops, return and process `[Substring]` arrays. `Substring` acts as a view on the original buffer's memory, avoiding allocations. Convert to `String` only at the exact boundaries where external libraries or JSON serialization strictly requires it.

## 2024-11-20 - Avoid repeated syscalls and resource leaks in polling loops

**Learning:** In periodic UI updates (like fetching CPU and Memory stats every 2 seconds via `SystemSampler`), repeatedly calling `mach_host_self()` can cause port exhaustion if the Mach port is not deallocated properly. Moreover, constantly querying `host_page_size()` is redundant since the kernel page size doesn't change during the application lifecycle.

**Action:** Cache kernel constants like `host_page_size` and Mach ports initialized via `mach_host_self()` during the object initialization phase. Always ensure proper cleanup of cached Mach ports in `deinit` using `mach_port_deallocate(mach_task_self_, port)` to prevent resource leaks.
