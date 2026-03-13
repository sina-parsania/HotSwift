//
//  UIViewController+HotSwift.swift
//  HotSwift
//
//  Created by Sina Parsa on 13/3/26.
//

#if DEBUG
#if canImport(UIKit)
import UIKit
import HotSwift

// MARK: - Method Swizzling for Automatic Hot-Reload

extension UIViewController {

    private static let swizzleOnce: Void = {
        let originalSelector = #selector(UIViewController.viewDidLoad)
        let swizzledSelector = #selector(UIViewController.hotSwift_viewDidLoad)

        guard
            let originalMethod = class_getInstanceMethod(UIViewController.self, originalSelector),
            let swizzledMethod = class_getInstanceMethod(UIViewController.self, swizzledSelector)
        else { return }

        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()

    /// Call this once (e.g. in AppDelegate) to enable automatic hot-reload for all
    /// view controllers. VCs that conform to `HotReloadable` or have a `setupUI()`
    /// method will be refreshed automatically.
    public static func enableGlobalHotReload() {
        _ = swizzleOnce
    }

    @objc private func hotSwift_viewDidLoad() {
        // Call the original viewDidLoad (implementations are swapped).
        hotSwift_viewDidLoad()

        registerForHotReload()
    }

    // MARK: - Manual Opt-In

    /// Manually register this view controller for hot-reload notifications.
    ///
    /// Call this in `viewDidLoad()` if you don't want global swizzling:
    /// ```swift
    /// override func viewDidLoad() {
    ///     super.viewDidLoad()
    ///     enableHotReload()
    /// }
    /// ```
    public func enableHotReload() {
        registerForHotReload()
    }

    // MARK: - Private

    private static var hotSwiftRegisteredKey: UInt8 = 0

    private func registerForHotReload() {
        guard objc_getAssociatedObject(self, &Self.hotSwiftRegisteredKey) == nil else { return }
        objc_setAssociatedObject(self, &Self.hotSwiftRegisteredKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotSwift_handleReload(_:)),
            name: HotSwift.didReloadNotification,
            object: nil
        )
    }

    @objc private func hotSwift_handleReload(_ notification: Notification) {
        let affectedClasses = notification.userInfo?["affectedClasses"] as? [String] ?? []
        let selfClassName = String(describing: type(of: self))

        // Only refresh if this VC's class is among the affected classes,
        // or if no class info is available (refresh all).
        guard affectedClasses.isEmpty || affectedClasses.contains(selfClassName) else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if let reloadable = self as? HotReloadable {
                reloadable.rebuildUI()
            } else {
                // Fallback: call setupUI() if the VC responds to it.
                let setupUISelector = NSSelectorFromString("setupUI")
                if self.responds(to: setupUISelector) {
                    self.perform(setupUISelector)
                }
            }

            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        }
    }
}

#endif
#endif

#if !DEBUG
#if canImport(UIKit)
import UIKit
extension UIViewController {
    @objc public static func enableGlobalHotReload() {}
    @objc public func enableHotReload() {}
}
#endif
#endif
