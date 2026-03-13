# HotSwift — iOS Hot-Reload Engine

<!-- Badges -->
![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)
![iOS 14+](https://img.shields.io/badge/iOS-14%2B-blue.svg)
![macOS 12+](https://img.shields.io/badge/macOS-12%2B-blue.svg)
![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)

**Drop-in hot-reload for iOS apps. Edit Swift files and see changes instantly — no restart required.**

HotSwift watches your Swift source files, recompiles changed files on the fly, and loads the new code into the running process. Completely standalone — no dependency on InjectionIII or any external tool.

## Features

- **File Watcher** — FSEvents-based monitoring with configurable debounce, glob exclude patterns, and `.swift`-only filtering
- **Smart Change Analysis** — SwiftSyntax-powered diffing distinguishes body-only changes (hot-reloadable) from structural changes (needs rebuild)
- **Hot-Reload via dlopen** — Modified method bodies are recompiled into a standalone `.dylib` and loaded at runtime in under a second
- **Auto-Rebuild** — Structural changes (new properties, changed signatures, new types) automatically trigger an Xcode Build & Run
- **Pbxproj Management** — New files are automatically added to `project.pbxproj`; deleted files are automatically removed
- **UIKit Support** — `HotReloadable` protocol for automatic UI rebuild on hot-reload
- **SwiftUI Support** — `@ObserveHotReload` property wrapper and `.enableHotReload()` modifier trigger view redraws
- **Debug-Only** — Compiles to empty stubs in Release. Zero overhead, zero binary size impact

## Requirements

| Requirement | Minimum |
|---|---|
| iOS | 14.0+ |
| macOS | 12.0+ |
| Xcode | 15.0+ |
| Swift | 5.9+ |

## Installation

### Swift Package Manager

Add HotSwift to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/pars-co/HotSwift.git", from: "0.1.0"),
]
```

Then add the targets you need:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "HotSwift", package: "HotSwift"),       // Core API
        .product(name: "HotSwiftUI", package: "HotSwift"),     // UIKit & SwiftUI helpers
    ]
)
```

Or in Xcode: File > Add Package Dependencies > paste the repository URL.

### Linker Flag

Add this to your **Debug** build settings to enable runtime method replacement:

```
OTHER_LDFLAGS = -Xlinker -interposable
```

## Quick Start

Add a single call to your `AppDelegate`:

```swift
#if DEBUG
import HotSwift
#endif

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {

        #if DEBUG
        HotSwift.start()
        #endif

        return true
    }
}
```

That's it. Edit any `.swift` file, save, and the UI updates automatically.

## Configuration

Customize behavior by passing a `HotSwiftConfiguration`:

```swift
#if DEBUG
var config = HotSwiftConfiguration()
config.watchPaths = ["/Users/you/Project/Sources"]   // Explicit paths (default: auto-detect)
config.excludePatterns = ["DerivedData", "Pods", ".build", "*.generated.swift"]
config.debounceInterval = 0.5                         // Seconds to wait before reloading
config.verbose = true                                 // Log every pipeline step
config.pbxprojPath = "/path/to/project.pbxproj"      // For auto-add/remove of files
config.projectName = "MyApp"                          // For DerivedData lookup
HotSwift.start(config: config)
#endif
```

All parameters are optional. By default, HotSwift auto-detects your project root from `#file`.

## How It Works

HotSwift uses SwiftSyntax to analyze each change and picks the fastest strategy:

| Change Type | Example | Strategy | Speed |
|---|---|---|---|
| **Body-only** | Change a color, text, or layout logic | `swiftc` > `dlopen` > notify (hot-reload) | < 1 second |
| **Structural** | Add a property, change a signature, add imports | Detect > Xcode Build & Run (auto-rebuild) | Full build cycle |
| **New file** | Create `MyNewView.swift` | Generate GUID > update pbxproj > Xcode rebuild | Full build cycle |
| **Deleted file** | Delete a file | Remove from pbxproj > Xcode rebuild | Full build cycle |

### Pipeline

```
File saved
    |
    v
[FSEvents Watcher] -- debounce --> [Change Analyzer (SwiftSyntax)]
                                        |
                        +---------------+---------------+
                        |               |               |
                   body-only       structural      new/deleted
                        |               |               |
                   [Compile]    [Xcode Rebuild]   [Update pbxproj]
                        |                           + [Xcode Rebuild]
                   [dlopen]
                        |
                   [Notify UI]
```

## UIKit Integration

### HotReloadable Protocol

Conform your view controllers to `HotReloadable` for automatic UI rebuild:

```swift
#if DEBUG
import HotSwiftUI
#endif

final class ProfileViewController: UIViewController, HotReloadable {
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupConstraints()
    }

    func rebuildUI() {
        view.subviews.forEach { $0.removeFromSuperview() }
        setupUI()
        setupConstraints()
    }

    private func setupUI() {
        view.backgroundColor = .systemBackground
        // ... your UI code
    }

    private func setupConstraints() {
        // ... your SnapKit constraints
    }
}
```

### Manual Observation

Use Combine or NotificationCenter to respond to reload events:

```swift
// Combine
HotSwift.reloadEvents
    .filter { $0.status == .success }
    .sink { event in
        print("Reloaded: \(event.filePath)")
        print("Affected: \(event.affectedClasses)")
        print("Duration: \(event.duration)s")
    }
    .store(in: &cancellables)

// NotificationCenter
NotificationCenter.default.addObserver(
    forName: HotSwift.didReloadNotification,
    object: nil,
    queue: .main
) { notification in
    let filePath = notification.userInfo?["filePath"] as? String
    let classes = notification.userInfo?["affectedClasses"] as? [String]
    // Refresh your UI
}
```

## SwiftUI Integration

### View Modifier

```swift
import SwiftUI
#if DEBUG
import HotSwiftUI
#endif

struct ContentView: View {
    var body: some View {
        VStack {
            Text("Hello, World!")
            Image(systemName: "globe")
        }
        #if DEBUG
        .enableHotReload()
        #endif
    }
}
```

### Property Wrapper

For more control, use the `@ObserveHotReload` property wrapper directly:

```swift
import HotSwiftUI

struct ContentView: View {
    @ObserveHotReload var hotReload

    var body: some View {
        Text("Edit me!")
            .foregroundColor(.blue)  // Change this, save, see it update
    }
}
```

## Architecture

```
HotSwift (Public API)
    |-- HotSwiftCore (Engine)
    |   |-- FileWatcher (FSEvents)
    |   |-- Analyzer (SwiftSyntax diff)
    |   |-- Compiler (swiftc wrapper)
    |   |-- Loader (dlopen/dlsym)
    |   |-- Interposer (fishhook + ObjC runtime)
    |   |-- ProjectManager (pbxproj editor + Xcode control)
    |   |-- Notification (class diff + injected() calls)
    |   +-- Pipeline (orchestrator)
    |-- HotSwiftUI (UIKit/SwiftUI helpers)
    |-- HotSwiftDiagnostics (error parsing + logging)
    +-- CHotSwiftFishhook (Mach-O symbol rebinding, C)
```

| Module | Purpose |
|---|---|
| `HotSwift` | Public API (`HotSwift.start()`, configuration, events) |
| `HotSwiftCore` | Engine internals (file watcher, compiler, loader, analyzer, pbxproj editor) |
| `HotSwiftUI` | UIKit helpers (`HotReloadable`) and SwiftUI helpers (`.enableHotReload()`) |
| `HotSwiftDiagnostics` | Logging and diagnostic engine |
| `CHotSwiftFishhook` | C target for Mach-O symbol rebinding (fishhook) |

## Debug-Only Guarantee

All HotSwift code is wrapped in `#if DEBUG` / `#endif` guards. In Release builds:

- `HotSwift.start()` and `HotSwift.stop()` compile to empty stubs
- `HotSwiftConfiguration` properties are inert
- No file watchers, no compilation, no dlopen calls
- **Zero runtime overhead, zero binary size impact**

You do not need to conditionally link the package. The compiler eliminates all HotSwift code in Release builds automatically.

## License

MIT License. See [LICENSE](LICENSE) for details.

Copyright (c) 2024 Sina Parsa
