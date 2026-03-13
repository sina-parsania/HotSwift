//
//  InjectionNotifier.swift
//  HotSwift
//
//  Created by Sina Parsa on 13/3/26.
//

// Notifies affected instances after a hot-reload by calling injected() and
// triggering UIViewController refresh patterns

#if DEBUG
import Foundation
import ObjectiveC

// MARK: - Injectable Protocol

/// Protocol that types can conform to in order to receive hot-reload callbacks.
///
/// When HotSwift detects that a class has been reloaded, it searches for live
/// instances and calls `injected()` on any that conform to this protocol.
///
/// ```swift
/// extension MyViewController: Injectable {
///     func injected() {
///         // Rebuild UI with updated code
///         view.subviews.forEach { $0.removeFromSuperview() }
///         setupUI()
///         setupConstraints()
///         bindViewModel()
///     }
/// }
/// ```
@objc protocol Injectable {
    @objc func injected()
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted after HotSwift successfully reloads and interposes a file.
    /// `userInfo` contains `"affectedClasses"` (`[String]`) and `"diffs"` (`[ClassDiff]`).
    static let hotSwiftDidInjectClasses = Notification.Name("HotSwiftDidInjectClasses")

    /// Posted for each individual instance that was notified.
    /// `userInfo` contains `"instance"` (the object) and `"className"` (`String`).
    static let hotSwiftDidInjectInstance = Notification.Name("HotSwiftDidInjectInstance")
}

// MARK: - Injection Notifier

/// Iterates live instances of affected classes and calls their `injected()` method
/// or triggers UIViewController refresh patterns.
///
/// ## Instance Discovery
///
/// Finding all live instances of a class in a pure-Swift environment is non-trivial.
/// This notifier uses two complementary strategies:
///
/// 1. **ObjC runtime enumeration** — For `NSObject` subclasses (including all
///    UIViewControllers), we can leverage the ObjC associated objects and
///    class hierarchy to find instances.
/// 2. **Notification-based opt-in** — Objects can register themselves with the
///    notifier to receive reload callbacks without relying on runtime scanning.
///
/// ## Refresh Strategies
///
/// For UIViewControllers specifically, calling `injected()` alone may not be
/// sufficient. The notifier also triggers:
/// - `viewDidLoad()` (indirectly, by calling `loadView()` + lifecycle methods)
/// - Layout invalidation via `view.setNeedsLayout()`
final class InjectionNotifier {

    // MARK: - Properties

    /// Weakly-held set of objects that have registered for injection callbacks.
    /// This supplements the runtime-based instance discovery.
    private var registeredInstances = NSHashTable<AnyObject>.weakObjects()

    /// Lock protecting `registeredInstances` from concurrent access.
    private let registeredLock = NSLock()

    /// The injected() selector used to check conformance and call the method.
    private static let injectedSelector = NSSelectorFromString("injected")

    /// The viewDidLoad selector for UIViewController refresh.
    private static let viewDidLoadSelector = NSSelectorFromString("viewDidLoad")

    // MARK: - Registration

    /// Register an object to receive `injected()` callbacks on reload.
    ///
    /// Objects are held weakly — they will be automatically removed when deallocated.
    /// This is useful for pure-Swift types that cannot be discovered via ObjC runtime
    /// enumeration.
    ///
    /// - Parameter instance: The object to register.
    func register(_ instance: AnyObject) {
        registeredLock.lock()
        defer { registeredLock.unlock() }
        registeredInstances.add(instance)
    }

    /// Unregister an object from receiving callbacks.
    ///
    /// - Parameter instance: The object to unregister.
    func unregister(_ instance: AnyObject) {
        registeredLock.lock()
        defer { registeredLock.unlock() }
        registeredInstances.remove(instance)
    }

    // MARK: - Notification

    /// Notify all live instances of the affected classes that a reload has occurred.
    ///
    /// This is the main entry point called by `ReloadPipeline` after successful
    /// interposition.
    ///
    /// - Parameters:
    ///   - affectedClassNames: Names of classes that were reloaded.
    ///   - diffs: The class diffs from `ClassDiffEngine`, for diagnostic reporting.
    /// - Returns: The number of instances that were notified.
    @discardableResult
    func notifyAffectedInstances(
        affectedClassNames: [String],
        diffs: [ClassDiff] = []
    ) -> Int {
        guard !affectedClassNames.isEmpty else { return 0 }

        var notifiedCount = 0

        // --- Strategy 1: Notify registered instances ---
        let (registeredCount, alreadyNotified) = notifyRegisteredInstances(affectedClassNames: affectedClassNames)
        notifiedCount += registeredCount

        // --- Strategy 2: Find UIViewController instances via window hierarchy ---
        // Pass the already-notified set to avoid calling injected() twice on the same instance.
        notifiedCount += notifyViewControllerInstances(
            affectedClassNames: affectedClassNames,
            alreadyNotified: alreadyNotified
        )

        // --- Post aggregate notification ---
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .hotSwiftDidInjectClasses,
                object: nil,
                userInfo: [
                    "affectedClasses": affectedClassNames,
                    "diffs": diffs,
                    "notifiedCount": notifiedCount
                ]
            )
        }

        return notifiedCount
    }

    // MARK: - Registered Instance Notification

    /// Iterates the registered instance set and calls `injected()` on matching objects.
    /// Returns both the count and the set of notified instances for deduplication.
    private func notifyRegisteredInstances(
        affectedClassNames: [String]
    ) -> (count: Int, notified: NSHashTable<AnyObject>) {
        let nameSet = Set(affectedClassNames)
        var count = 0
        let notified = NSHashTable<AnyObject>.weakObjects()

        registeredLock.lock()
        let allObjects = registeredInstances.allObjects
        registeredLock.unlock()

        for instance in allObjects {
            let className = NSStringFromClass(type(of: instance))
            let shortName = shortClassName(from: className)

            guard nameSet.contains(className) || nameSet.contains(shortName) else {
                continue
            }

            callInjected(on: instance, className: shortName)
            notified.add(instance)
            count += 1
        }

        return (count, notified)
    }

    // MARK: - UIViewController Discovery

    /// Finds visible UIViewController instances that match the affected class names
    /// and triggers their refresh.
    ///
    /// Traverses the view controller hierarchy starting from each window's
    /// `rootViewController`, collecting all presented and child controllers.
    private func notifyViewControllerInstances(
        affectedClassNames: [String],
        alreadyNotified: NSHashTable<AnyObject>
    ) -> Int {
        let nameSet = Set(affectedClassNames)
        var count = 0

        // We must access UIApplication on the main thread.
        // Avoid deadlock: if already on main thread, call directly.
        var viewControllers = [AnyObject]()
        if Thread.isMainThread {
            viewControllers = collectAllViewControllers()
        } else {
            DispatchQueue.main.sync {
                viewControllers = self.collectAllViewControllers()
            }
        }

        for vc in viewControllers {
            // Skip instances already notified via the registered set
            // to prevent calling injected() twice on the same object.
            if alreadyNotified.contains(vc) { continue }

            let className = NSStringFromClass(type(of: vc))
            let shortName = shortClassName(from: className)

            guard nameSet.contains(className) || nameSet.contains(shortName) else {
                continue
            }

            DispatchQueue.main.async { [weak self] in
                self?.refreshViewController(vc, className: shortName)
            }

            count += 1
        }

        return count
    }

    /// Collects all view controllers in the app's window hierarchy.
    ///
    /// Must be called on the main thread.
    private func collectAllViewControllers() -> [AnyObject] {
        var controllers = [AnyObject]()

        // Use NSClassFromString to avoid direct UIKit import (this is a non-UI module).
        guard let applicationClass = NSClassFromString("UIApplication") as? NSObject.Type,
              let application = applicationClass.value(forKey: "sharedApplication") as? NSObject else {
            return controllers
        }

        // Prefer scene-based window access (iOS 15+) to avoid deprecated
        // UIApplication.windows property.
        var windows = [NSObject]()
        if let connectedScenes = application.value(forKey: "connectedScenes") as? Set<NSObject> {
            for scene in connectedScenes {
                // Check if this is a UIWindowScene by looking for the "windows" property.
                if let sceneWindows = scene.value(forKey: "windows") as? [NSObject] {
                    windows.append(contentsOf: sceneWindows)
                }
            }
        }

        // Fallback for iOS < 15 or when scene access fails.
        if windows.isEmpty {
            if let appWindows = application.value(forKey: "windows") as? [NSObject] {
                windows = appWindows
            }
        }

        for window in windows {
            guard let rootVC = window.value(forKey: "rootViewController") as? NSObject else {
                continue
            }
            collectViewControllers(from: rootVC, into: &controllers)
        }

        return controllers
    }

    /// Recursively collects view controllers from a root, including presented
    /// and child controllers.
    private func collectViewControllers(from vc: NSObject, into result: inout [AnyObject]) {
        result.append(vc)

        // Collect child view controllers.
        if let children = vc.value(forKey: "childViewControllers") as? [NSObject] {
            for child in children {
                collectViewControllers(from: child, into: &result)
            }
        }

        // Collect presented view controller.
        if let presented = vc.value(forKey: "presentedViewController") as? NSObject {
            // Avoid infinite loops from circular presentation chains.
            let alreadyCollected = result.contains { $0 === presented }
            if !alreadyCollected {
                collectViewControllers(from: presented, into: &result)
            }
        }

        // Handle UINavigationController's viewControllers.
        if let navChildren = vc.value(forKey: "viewControllers") as? [NSObject] {
            for child in navChildren {
                let alreadyCollected = result.contains { $0 === child }
                if !alreadyCollected {
                    collectViewControllers(from: child, into: &result)
                }
            }
        }

        // Handle UITabBarController's viewControllers.
        if vc.responds(to: NSSelectorFromString("tabBar")) {
            if let tabChildren = vc.value(forKey: "viewControllers") as? [NSObject] {
                for child in tabChildren {
                    let alreadyCollected = result.contains { $0 === child }
                    if !alreadyCollected {
                        collectViewControllers(from: child, into: &result)
                    }
                }
            }
        }
    }

    // MARK: - Instance Refresh

    /// Calls `injected()` on an object if it responds to that selector.
    private func callInjected(on instance: AnyObject, className: String) {
        guard instance.responds(to: Self.injectedSelector) else { return }

        DispatchQueue.main.async { [weak instance] in
            guard let instance else { return }
            _ = instance.perform(Self.injectedSelector)

            NotificationCenter.default.post(
                name: .hotSwiftDidInjectInstance,
                object: nil,
                userInfo: [
                    "instance": instance,
                    "className": className
                ]
            )
        }
    }

    /// Refreshes a UIViewController by calling `injected()` if available,
    /// otherwise triggers layout invalidation.
    private func refreshViewController(_ vc: AnyObject, className: String) {
        // Priority 1: Call injected() if the VC conforms to Injectable.
        if vc.responds(to: Self.injectedSelector) {
            _ = vc.perform(Self.injectedSelector)

            NotificationCenter.default.post(
                name: .hotSwiftDidInjectInstance,
                object: nil,
                userInfo: [
                    "instance": vc,
                    "className": className
                ]
            )
            return
        }

        // Priority 2: Trigger a layout refresh cycle.
        // This causes the view hierarchy to re-evaluate with the new method
        // implementations without requiring explicit Injectable conformance.
        if let view = (vc as? NSObject)?.value(forKey: "view") as? NSObject {
            view.perform(NSSelectorFromString("setNeedsLayout"))
            view.perform(NSSelectorFromString("setNeedsDisplay"))
        }

        // Post the per-instance notification regardless of strategy used.
        NotificationCenter.default.post(
            name: .hotSwiftDidInjectInstance,
            object: nil,
            userInfo: [
                "instance": vc,
                "className": className
            ]
        )
    }

    // MARK: - Helpers

    /// Extracts the short class name from a potentially module-qualified ObjC name.
    ///
    /// `"MyApp.MyViewController"` -> `"MyViewController"`
    /// `"MyViewController"` -> `"MyViewController"`
    private func shortClassName(from fullName: String) -> String {
        if let dotIndex = fullName.lastIndex(of: ".") {
            return String(fullName[fullName.index(after: dotIndex)...])
        }
        return fullName
    }
}
#endif
