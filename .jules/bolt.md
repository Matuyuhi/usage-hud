## 2024-05-18 - Avoid array allocations in tight loops

**Learning:** In periodic UI updates on macOS (like sampling active processes every 5 seconds), seemingly innocent standard library functions like `String.split()` and `.firstIndex()` can cause unnecessary object churn and CPU usage. Splitting paths is a common pattern that is computationally expensive if done for hundreds of background processes.

**Action:** For simple substring matches in paths, favor direct String range finding like `.range(of:)` and `.hasSuffix()` over splitting into arrays and joining.

## 2024-05-19 - Avoid String creations for C string prefix checks

**Learning:** When checking the prefix of a C string (`UnsafePointer<CChar>`) in a tight loop (e.g., polling network interfaces every 2 seconds), converting it to a Swift `String` just to use `.hasPrefix()` causes unnecessary object allocations and CPU overhead.

**Action:** For simple fixed ASCII prefixes, perform a direct byte comparison (e.g., `name[0] == 101 && name[1] == 110` for "en") on the pointer instead of instantiating a `String`.

## 2024-05-20 - Avoid unnecessary String allocations from output splitting

**Learning:** When splitting standard output from processes (like `ps`), using `String.split()` and then mapping the results to `String` (i.e. `.map(String.init)`) causes an unnecessary object allocation for every line. For commands producing hundreds of lines every few seconds, this significantly churns memory and increases CPU usage.

**Action:** Return `[Substring]` directly from functions that split output and only allocate a `String` (e.g. `String(token)`) when specifically required for downstream processing or to avoid retaining the original large string in memory longer than necessary.
