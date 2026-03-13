//
//  ObjCRuntimeBridge.swift
//  HotSwift
//
//  Created by Sina Parsa on 13/3/26.
//

// Bridge to the Objective-C runtime for class discovery and method swizzling

#if DEBUG
import Foundation
import ObjectiveC

// MARK: - ObjC Runtime Bridge

/// Provides Swift-friendly access to Objective-C runtime introspection and
/// method replacement APIs.
///
/// HotSwift uses this bridge for two primary purposes:
/// 1. **Class discovery** — Enumerating all loaded ObjC classes to find subclasses
///    of a given base (e.g., `UIViewController`) that may need refreshing.
/// 2. **Method swizzling** — Replacing method implementations (`IMP`s) on a class
///    so that existing instances pick up recompiled code immediately.
///
/// All operations go through the stable `objc/runtime.h` API surface.
final class ObjCRuntimeBridge {

    // MARK: - Types

    /// Describes a single Objective-C method on a class.
    struct MethodInfo {
        /// The selector (method name) as a string, e.g. `"viewDidLoad"`.
        let selectorName: String
        /// The Objective-C type encoding string for the method signature.
        let typeEncoding: String
        /// The current implementation pointer.
        let implementation: IMP
    }

    // MARK: - Class Enumeration

    /// Returns all Objective-C classes currently registered with the runtime.
    ///
    /// - Returns: An array of `AnyClass` representing every registered class.
    ///   On a typical iOS app this can be 10,000+ entries, so callers should
    ///   filter the result promptly.
    static func allRegisteredClasses() -> [AnyClass] {
        var count: UInt32 = 0
        guard let classList = objc_copyClassList(&count) else { return [] }
        defer { free(UnsafeMutableRawPointer(classList)) }

        var classes = [AnyClass]()
        classes.reserveCapacity(Int(count))

        for index in 0..<Int(count) {
            classes.append(classList[index])
        }

        return classes
    }

    /// Returns all subclasses (direct and indirect) of a given base class.
    ///
    /// Walks the full class list and checks inheritance chains using
    /// `class_getSuperclass`. This is an O(n) scan over all loaded classes.
    ///
    /// - Parameter baseClass: The class to find subclasses of.
    /// - Returns: An array of classes that inherit from `baseClass`.
    static func subclasses(of baseClass: AnyClass) -> [AnyClass] {
        let all = allRegisteredClasses()
        return all.filter { cls in
            var current: AnyClass? = cls
            while let superclass = class_getSuperclass(current) {
                if superclass == baseClass {
                    return true
                }
                current = superclass
            }
            return false
        }
    }

    /// Returns all class names that match one of the given type name strings.
    ///
    /// This performs a suffix match on the ObjC class name, which accounts for
    /// Swift module-name prefixing (e.g., `MyApp.MyViewController` matches `"MyViewController"`).
    ///
    /// - Parameter typeNames: Swift type names to search for (unmangled).
    /// - Returns: An array of matching ObjC classes.
    static func findClasses(named typeNames: [String]) -> [AnyClass] {
        guard !typeNames.isEmpty else { return [] }

        let nameSet = Set(typeNames)
        let all = allRegisteredClasses()

        return all.filter { cls in
            let className = NSStringFromClass(cls)
            // Check for exact match or suffix match after module prefix (e.g., "Module.ClassName")
            if nameSet.contains(className) { return true }
            if let dotIndex = className.lastIndex(of: ".") {
                let shortName = String(className[className.index(after: dotIndex)...])
                return nameSet.contains(shortName)
            }
            return false
        }
    }

    // MARK: - Method Introspection

    /// Returns all instance methods declared directly on the given class
    /// (not inherited methods).
    ///
    /// - Parameter cls: The class to inspect.
    /// - Returns: An array of `MethodInfo` structs describing each method.
    static func instanceMethods(of cls: AnyClass) -> [MethodInfo] {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &count) else { return [] }
        defer { free(methods) }

        var result = [MethodInfo]()
        result.reserveCapacity(Int(count))

        for index in 0..<Int(count) {
            let method = methods[index]
            let selector = method_getName(method)
            let selectorName = NSStringFromSelector(selector)
            let typeEncoding = method_getTypeEncoding(method).flatMap { String(cString: $0) } ?? ""
            let imp = method_getImplementation(method)

            result.append(MethodInfo(
                selectorName: selectorName,
                typeEncoding: typeEncoding,
                implementation: imp
            ))
        }

        return result
    }

    /// Returns all class methods declared directly on the given class.
    ///
    /// - Parameter cls: The class to inspect.
    /// - Returns: An array of `MethodInfo` structs for class-level methods.
    static func classMethods(of cls: AnyClass) -> [MethodInfo] {
        guard let metaClass = object_getClass(cls) else { return [] }
        return instanceMethods(of: metaClass)
    }

    // MARK: - Method Replacement

    /// Replace the implementation of an instance method on a class.
    ///
    /// If the method does not exist on the class (but may exist on a superclass),
    /// this first adds it to the class so the superclass is not modified.
    ///
    /// - Parameters:
    ///   - cls: The class to modify.
    ///   - selector: The selector of the method to replace.
    ///   - newImplementation: The new `IMP` to install.
    ///   - typeEncoding: The ObjC type encoding string for the method signature.
    /// - Returns: The previous `IMP`, or `nil` if the method was newly added.
    @discardableResult
    static func replaceInstanceMethod(
        on cls: AnyClass,
        selector: Selector,
        newImplementation: IMP,
        typeEncoding: String
    ) -> IMP? {
        let previous = class_replaceMethod(
            cls,
            selector,
            newImplementation,
            typeEncoding
        )
        return previous
    }

    /// Replace the implementation of a class method.
    ///
    /// - Parameters:
    ///   - cls: The class whose metaclass will be modified.
    ///   - selector: The selector of the class method to replace.
    ///   - newImplementation: The new `IMP`.
    ///   - typeEncoding: The ObjC type encoding string.
    /// - Returns: The previous `IMP`, or `nil` if the method was newly added.
    @discardableResult
    static func replaceClassMethod(
        on cls: AnyClass,
        selector: Selector,
        newImplementation: IMP,
        typeEncoding: String
    ) -> IMP? {
        guard let metaClass = object_getClass(cls) else { return nil }
        return class_replaceMethod(
            metaClass,
            selector,
            newImplementation,
            typeEncoding
        )
    }

    // MARK: - Bulk Method Replacement

    /// Replace all methods on `targetClass` with implementations from `sourceClass`.
    ///
    /// For every instance method declared directly on `sourceClass`, if `targetClass`
    /// responds to the same selector, its implementation is replaced with the one
    /// from `sourceClass`.
    ///
    /// - Parameters:
    ///   - targetClass: The class whose methods will be overwritten.
    ///   - sourceClass: The class providing the new implementations.
    /// - Returns: The number of methods that were replaced.
    @discardableResult
    static func replaceAllMethods(
        on targetClass: AnyClass,
        from sourceClass: AnyClass
    ) -> Int {
        let sourceMethods = instanceMethods(of: sourceClass)
        var replacedCount = 0

        for methodInfo in sourceMethods {
            let selector = NSSelectorFromString(methodInfo.selectorName)

            // Only replace methods that already exist on the target class.
            // Adding methods that the target never had can corrupt its vtable
            // or introduce unexpected behavior.
            guard class_getInstanceMethod(targetClass, selector) != nil else { continue }

            replaceInstanceMethod(
                on: targetClass,
                selector: selector,
                newImplementation: methodInfo.implementation,
                typeEncoding: methodInfo.typeEncoding
            )

            replacedCount += 1
        }

        // Also handle class methods.
        let sourceClassMethods = classMethods(of: sourceClass)
        let targetMetaClass: AnyClass? = object_getClass(targetClass)
        for methodInfo in sourceClassMethods {
            let selector = NSSelectorFromString(methodInfo.selectorName)

            // Only replace class methods that already exist on the target metaclass.
            guard let meta = targetMetaClass,
                  class_getInstanceMethod(meta, selector) != nil else { continue }

            replaceClassMethod(
                on: targetClass,
                selector: selector,
                newImplementation: methodInfo.implementation,
                typeEncoding: methodInfo.typeEncoding
            )

            replacedCount += 1
        }

        return replacedCount
    }

    // MARK: - Protocol Conformance

    /// Checks whether the given class conforms to a protocol with the specified name.
    ///
    /// - Parameters:
    ///   - cls: The class to check.
    ///   - protocolName: The name of the protocol (e.g., `"Injectable"`).
    /// - Returns: `true` if the class conforms to the named protocol.
    static func classConforms(_ cls: AnyClass, toProtocolNamed protocolName: String) -> Bool {
        guard let proto = objc_getProtocol(protocolName) else { return false }
        return class_conformsToProtocol(cls, proto)
    }

    /// Checks whether the given class or any of its superclasses responds to a selector.
    ///
    /// - Parameters:
    ///   - cls: The class to check.
    ///   - selector: The selector to look for.
    /// - Returns: `true` if instances of `cls` respond to `selector`.
    static func classResponds(_ cls: AnyClass, to selector: Selector) -> Bool {
        return class_getInstanceMethod(cls, selector) != nil
    }
}
#endif
