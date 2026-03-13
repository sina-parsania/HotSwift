//
//  View+HotSwift.swift
//  HotSwift
//
//  Created by Sina Parsa on 13/3/26.
//

#if DEBUG
#if canImport(SwiftUI)
import SwiftUI
import HotSwift

@available(iOS 14.0, macOS 11.0, *)
extension View {
    /// Modifier that forces a re-render when hot-reload occurs.
    ///
    /// ```swift
    /// struct ContentView: View {
    ///     var body: some View {
    ///         Text("Hello")
    ///             .enableHotReload()
    ///     }
    /// }
    /// ```
    public func enableHotReload() -> some View {
        modifier(HotReloadModifier())
    }
}

@available(iOS 14.0, macOS 11.0, *)
struct HotReloadModifier: ViewModifier {
    @ObserveHotReload var hotReload

    func body(content: Content) -> some View {
        content.id(hotReload)
    }
}

#endif
#endif

#if !DEBUG
#if canImport(SwiftUI)
import SwiftUI
@available(iOS 14.0, macOS 11.0, *)
extension View {
    public func enableHotReload() -> some View { self }
}
#endif
#endif
