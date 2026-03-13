//
//  HotReloadable.swift
//  HotSwift
//
//  Created by Sina Parsa on 13/3/26.
//

#if DEBUG

/// Conform to this protocol to opt in to automatic UI rebuild on hot-reload.
///
/// When a hot-reload event fires, any `UIViewController` or `UIView` that conforms
/// to `HotReloadable` will have its `rebuildUI()` method called automatically.
///
/// ```swift
/// final class MyViewController: UIViewController, HotReloadable {
///     func rebuildUI() {
///         view.subviews.forEach { $0.removeFromSuperview() }
///         setupUI()
///         setupConstraints()
///     }
/// }
/// ```
public protocol HotReloadable: AnyObject {
    /// Called after a hot-reload. Rebuild your UI here.
    func rebuildUI()
}

#else

public protocol HotReloadable: AnyObject {
    func rebuildUI()
}

#endif
