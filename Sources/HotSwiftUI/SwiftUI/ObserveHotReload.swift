//
//  ObserveHotReload.swift
//  HotSwift
//
//  Created by Sina Parsa on 13/3/26.
//

#if DEBUG
#if canImport(SwiftUI)
import SwiftUI
import HotSwift

/// Property wrapper that triggers a SwiftUI view redraw on hot-reload.
///
/// Usage:
/// ```swift
/// struct MyView: View {
///     @ObserveHotReload var hotReload
///
///     var body: some View {
///         Text("Hello")
///     }
/// }
/// ```
@available(iOS 14.0, macOS 11.0, *)
@propertyWrapper
public struct ObserveHotReload: DynamicProperty {
    @StateObject private var observer = HotReloadObserver()

    public var wrappedValue: Int { observer.reloadCount }

    public init() {}
}

@available(iOS 14.0, macOS 11.0, *)
final class HotReloadObserver: ObservableObject {
    @Published var reloadCount = 0
    private var observerToken: NSObjectProtocol?

    init() {
        observerToken = NotificationCenter.default.addObserver(
            forName: HotSwift.didReloadNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadCount += 1
        }
    }

    deinit {
        if let token = observerToken {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

#else

// Stub when SwiftUI is not available
@propertyWrapper
public struct ObserveHotReload {
    public var wrappedValue: Int { 0 }
    public init() {}
}

#endif

#else

// MARK: - Release Stub

#if canImport(SwiftUI)
import SwiftUI

/// Release stub — returns a constant value. Zero overhead.
@available(iOS 14.0, macOS 11.0, *)
@propertyWrapper
public struct ObserveHotReload: DynamicProperty {
    public var wrappedValue: Int { 0 }
    public init() {}
}

#else

/// Release stub when SwiftUI is not available.
@propertyWrapper
public struct ObserveHotReload {
    public var wrappedValue: Int { 0 }
    public init() {}
}

#endif

#endif
