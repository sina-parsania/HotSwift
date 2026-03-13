# Contributing to HotSwift

Thanks for your interest in contributing to HotSwift! This guide will help you get started.

## Development Setup

1. Clone the repo:
   ```bash
   git clone https://github.com/sina-parsania/HotSwift.git
   cd HotSwift
   ```

2. Open in Xcode:
   ```bash
   open Package.swift
   ```

3. Build and run tests:
   ```bash
   xcrun swift build
   xcrun swift test
   ```

## Project Structure

```
Sources/
  CHotSwiftFishhook/    # C target — Mach-O symbol rebinding (fishhook)
  HotSwiftCore/         # Core engine — watcher, analyzer, compiler, loader, pipeline
  HotSwiftDiagnostics/  # Logging utilities
  HotSwift/             # Public API surface
  HotSwiftUI/           # UIKit + SwiftUI integration helpers
Tests/
  HotSwiftTests/        # Unit and integration tests
```

## Architecture

The hot-reload pipeline flows through these stages:

```
FSEventsWatcher → ChangeAnalyzer → SwiftCompiler → DylibLoader → Interposer → Notification
```

- **FSEventsWatcher**: Monitors directories for `.swift` file changes using macOS FSEvents API
- **ChangeAnalyzer**: Uses SwiftSyntax to diff structural fingerprints (body-only vs structural)
- **SwiftCompiler**: Recompiles the changed file using cached Xcode build settings
- **DylibLoader**: Loads the compiled `.dylib` via `dlopen`
- **Interposer**: Uses fishhook for Mach-O symbol rebinding
- **ReloadPipeline**: Orchestrates all stages and emits events

## Guidelines

### Code

- All code must compile with `#if DEBUG` guards — zero overhead in Release builds
- Use `pthread_mutex_t` or `NSLock` for thread safety (not `DispatchQueue.sync`)
- Prefer `Unmanaged.passRetained` over `passUnretained` for C callbacks
- Read pipes on background threads before `waitUntilExit()` to prevent deadlocks
- Run `xcrun swift build` and `xcrun swift test` before submitting

### Tests

- Add tests for any new public or internal API
- Use temp directories for file-based tests and clean up in `tearDown`
- Tests run in `#if DEBUG` context (same as the library)

### Commits

- Follow [Conventional Commits](https://www.conventionalcommits.org/):
  - `feat:` new features
  - `fix:` bug fixes
  - `test:` adding/updating tests
  - `ci:` CI/workflow changes
  - `docs:` documentation
  - `refactor:` code restructuring without behavior change

### Pull Requests

- Fork the repo and create a branch from `main`
- Keep PRs focused — one feature or fix per PR
- Include tests for new functionality
- Ensure CI passes before requesting review

## Reporting Issues

- Use [GitHub Issues](https://github.com/sina-parsania/HotSwift/issues)
- Include: Xcode version, macOS version, Swift version, and steps to reproduce

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
