## 2024-05-18 - Avoid array allocations in tight loops

**Learning:** In periodic UI updates on macOS (like sampling active processes every 5 seconds), seemingly innocent standard library functions like `String.split()` and `.firstIndex()` can cause unnecessary object churn and CPU usage. Splitting paths is a common pattern that is computationally expensive if done for hundreds of background processes.

**Action:** For simple substring matches in paths, favor direct String range finding like `.range(of:)` and `.hasSuffix()` over splitting into arrays and joining.
