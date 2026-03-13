//
//  UIView+HotSwift.swift
//  HotSwift
//
//  Created by Sina Parsa on 13/3/26.
//

#if DEBUG
#if canImport(UIKit)
import UIKit
import HotSwift

extension UIView {

    /// Register this view for hot-reload notifications.
    ///
    /// On reload, the view will call `setNeedsLayout()` and `setNeedsDisplay()`.
    /// If the view conforms to `HotReloadable`, `rebuildUI()` is called instead.
    ///
    /// ```swift
    /// override init(frame: CGRect) {
    ///     super.init(frame: frame)
    ///     enableHotReload()
    /// }
    /// ```
    public func enableHotReload() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotSwift_handleViewReload(_:)),
            name: HotSwift.didReloadNotification,
            object: nil
        )
    }

    @objc private func hotSwift_handleViewReload(_ notification: Notification) {
        let affectedClasses = notification.userInfo?["affectedClasses"] as? [String] ?? []
        let selfClassName = String(describing: type(of: self))

        guard affectedClasses.isEmpty || affectedClasses.contains(selfClassName) else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if let reloadable = self as? HotReloadable {
                reloadable.rebuildUI()
            }

            self.setNeedsLayout()
            self.setNeedsDisplay()
        }
    }
}

#endif
#endif

#if !DEBUG
#if canImport(UIKit)
import UIKit
extension UIView {
    @objc public func enableHotReload() {}
}
#endif
#endif
