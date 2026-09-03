## 2024-05-18 - Avoid array allocations in tight loops

**Learning:** In periodic UI updates on macOS (like sampling active processes every 5 seconds), seemingly innocent standard library functions like `String.split()` and `.firstIndex()` can cause unnecessary object churn and CPU usage. Splitting paths is a common pattern that is computationally expensive if done for hundreds of background processes.

**Action:** For simple substring matches in paths, favor direct String range finding like `.range(of:)` and `.hasSuffix()` over splitting into arrays and joining.

## 2024-05-19 - Avoid String creations for C string prefix checks

**Learning:** When checking the prefix of a C string (`UnsafePointer<CChar>`) in a tight loop (e.g., polling network interfaces every 2 seconds), converting it to a Swift `String` just to use `.hasPrefix()` causes unnecessary object allocations and CPU overhead.

**Action:** For simple fixed ASCII prefixes, perform a direct byte comparison (e.g., `name[0] == 101 && name[1] == 110` for "en") on the pointer instead of instantiating a `String`.

## 2025-02-12 - Avoid String allocations when parsing command output

**Learning:** When reading and parsing large blocks of text from standard output in tight loops (like `ps` command output updated frequently), splitting into lines using `String.split()` and immediately mapping each `Substring` to a new `String` via `.map(String.init)` causes massive and unnecessary memory allocations and garbage collection overhead.

**Action:** Leave the results of `String.split()` as `[Substring]` where possible, particularly when filtering lines, matching prefixes, or extracting parts of a path. Only instantiate a full `String` when an external API or data struct explicitly requires it.
