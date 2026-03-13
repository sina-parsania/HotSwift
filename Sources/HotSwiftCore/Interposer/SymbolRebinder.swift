//
//  SymbolRebinder.swift
//  HotSwift
//
//  Created by Sina Parsa on 13/3/26.
//

// Swift wrapper around the CHotSwiftFishhook C library for Mach-O symbol rebinding

#if DEBUG
import Foundation
import CHotSwiftFishhook

// MARK: - Symbol Rebinder

/// Provides a Swift-friendly API over the low-level `fishhook` C library.
///
/// `fishhook` works by patching the lazy and non-lazy symbol pointer tables in
/// loaded Mach-O images. This lets us redirect calls from the original function
/// to a replacement while still retaining a pointer to the original.
///
/// Usage:
/// ```swift
/// var rebindings = [
///     SymbolRebinder.Rebinding(name: "_myFunction", replacement: newImpl)
/// ]
/// let success = SymbolRebinder.rebind(&rebindings)
/// let original = rebindings[0].original // pointer to the old implementation
/// ```
final class SymbolRebinder {

    // MARK: - Types

    /// A single symbol rebinding request.
    ///
    /// - `name`: The C symbol name to rebind (including leading underscore for Swift-mangled names).
    /// - `replacement`: Pointer to the new implementation that calls should be redirected to.
    /// - `original`: After a successful rebind, this is set to the pointer of the original
    ///   implementation so callers can still invoke the old code if needed.
    struct Rebinding {
        let name: String
        let replacement: UnsafeMutableRawPointer
        var original: UnsafeMutableRawPointer?
    }

    // MARK: - Rebinding (All Images)

    /// Rebind symbols across all loaded Mach-O images in the current process.
    ///
    /// Each entry in `rebindings` is matched by symbol name. When a match is found,
    /// the symbol pointer table entry is overwritten with `replacement`, and
    /// `original` is set to the previous value.
    ///
    /// - Parameter rebindings: An array of rebinding requests. Updated in place with
    ///   the original function pointers.
    /// - Returns: `true` if `fishhook` reported success, `false` otherwise.
    @discardableResult
    static func rebind(_ rebindings: inout [Rebinding]) -> Bool {
        guard !rebindings.isEmpty else { return true }

        // Allocate storage for the original pointers that fishhook will write back.
        // Each element needs its own stable pointer so fishhook can write to it.
        var originals = [UnsafeMutablePointer<UnsafeMutableRawPointer?>]()
        originals.reserveCapacity(rebindings.count)

        for _ in rebindings {
            let storage = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 1)
            storage.initialize(to: nil)
            originals.append(storage)
        }

        // Build the C-level rebinding structs.
        // Retain NSString objects so their utf8String pointers remain valid
        // through the fishhook call (the bridged NSString can be released
        // before fishhook reads the pointer, causing a use-after-free).
        var retainedStrings = [NSString]()
        retainedStrings.reserveCapacity(rebindings.count)

        var cRebindings = [hotswift_rebinding]()
        cRebindings.reserveCapacity(rebindings.count)

        for (index, binding) in rebindings.enumerated() {
            let nsName = binding.name as NSString
            retainedStrings.append(nsName)
            guard let cName = nsName.utf8String else { continue }
            let cRebinding = hotswift_rebinding(
                name: cName,
                replacement: binding.replacement,
                replaced: UnsafeMutablePointer(OpaquePointer(originals[index]))
            )
            cRebindings.append(cRebinding)
        }

        // Call into fishhook — keep retainedStrings alive so their
        // utf8String pointers remain valid throughout the C call.
        let result = withExtendedLifetime(retainedStrings) {
            hotswift_rebind_symbols(&cRebindings, cRebindings.count)
        }

        // Copy the original pointers back into the Swift structs.
        for (index, storage) in originals.enumerated() {
            rebindings[index].original = storage.pointee
            storage.deinitialize(count: 1)
            storage.deallocate()
        }

        return result == 0
    }

    // MARK: - Rebinding (Single Image)

    /// Rebind symbols in a specific Mach-O image loaded via `dlopen`.
    ///
    /// This variant is more targeted than `rebind(_:)` — it only patches symbol
    /// pointers within the given image header rather than scanning all loaded images.
    ///
    /// - Parameters:
    ///   - header: The Mach-O header pointer of the target image (from `dlopen`).
    ///   - slide: The ASLR slide value for the image.
    ///   - rebindings: An array of rebinding requests. Updated in place.
    /// - Returns: `true` if `fishhook` reported success, `false` otherwise.
    @discardableResult
    static func rebindImage(
        header: UnsafeMutableRawPointer,
        slide: Int,
        rebindings: inout [Rebinding]
    ) -> Bool {
        guard !rebindings.isEmpty else { return true }

        var originals = [UnsafeMutablePointer<UnsafeMutableRawPointer?>]()
        originals.reserveCapacity(rebindings.count)

        for _ in rebindings {
            let storage = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 1)
            storage.initialize(to: nil)
            originals.append(storage)
        }

        // Retain NSString objects so their utf8String pointers remain valid
        // through the fishhook call.
        var retainedStrings = [NSString]()
        retainedStrings.reserveCapacity(rebindings.count)

        var cRebindings = [hotswift_rebinding]()
        cRebindings.reserveCapacity(rebindings.count)

        for (index, binding) in rebindings.enumerated() {
            let nsName = binding.name as NSString
            retainedStrings.append(nsName)
            guard let cName = nsName.utf8String else { continue }
            let cRebinding = hotswift_rebinding(
                name: cName,
                replacement: binding.replacement,
                replaced: UnsafeMutablePointer(OpaquePointer(originals[index]))
            )
            cRebindings.append(cRebinding)
        }

        // Call into fishhook — keep retainedStrings alive so their
        // utf8String pointers remain valid throughout the C call.
        let result = withExtendedLifetime(retainedStrings) {
            hotswift_rebind_symbols_image(
                header,
                slide,
                &cRebindings,
                cRebindings.count
            )
        }

        for (index, storage) in originals.enumerated() {
            rebindings[index].original = storage.pointee
            storage.deinitialize(count: 1)
            storage.deallocate()
        }

        return result == 0
    }

    // MARK: - Convenience

    /// Rebind a single named symbol to a new implementation.
    ///
    /// - Parameters:
    ///   - name: The symbol name to rebind.
    ///   - replacement: Pointer to the new implementation.
    /// - Returns: The original implementation pointer, or `nil` if rebinding failed
    ///   or the symbol was not found.
    @discardableResult
    static func rebindSingle(
        name: String,
        replacement: UnsafeMutableRawPointer
    ) -> UnsafeMutableRawPointer? {
        var rebindings = [Rebinding(name: name, replacement: replacement)]
        let success = rebind(&rebindings)
        guard success else { return nil }
        return rebindings[0].original
    }
}
#endif
