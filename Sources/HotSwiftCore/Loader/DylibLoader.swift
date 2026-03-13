//
//  DylibLoader.swift
//  HotSwift
//
//  Created by Sina Parsa on 13/3/26.
//

// Loads compiled dynamic libraries into the running process at runtime

#if DEBUG
import Foundation

// MARK: - Errors

/// Errors that can occur when loading dynamic libraries.
enum DylibLoaderError: LocalizedError {
    /// The dylib file was not found at the specified path.
    case fileNotFound(String)
    /// `dlopen` failed to load the dylib. Contains the underlying `dlerror()` message.
    case loadFailed(path: String, reason: String)
    /// `dlsym` failed to resolve a symbol. Contains the symbol name and any `dlerror()` message.
    case symbolNotFound(name: String, reason: String?)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Dylib not found at: \(path)"
        case .loadFailed(let path, let reason):
            return "Failed to load dylib at \(path): \(reason)"
        case .symbolNotFound(let name, let reason):
            let base = "Symbol '\(name)' not found"
            if let reason = reason {
                return "\(base): \(reason)"
            }
            return base
        }
    }
}

// MARK: - Loaded Image

/// Tracks a single loaded dynamic library image.
///
/// Each time a recompiled dylib is loaded, a new `LoadedImage` is created with
/// an incremented version number. The `handle` is the raw pointer returned by `dlopen`.
struct LoadedImage {
    /// The opaque handle returned by `dlopen`. Used for `dlsym` lookups.
    let handle: UnsafeMutableRawPointer
    /// The absolute filesystem path of the loaded dylib.
    let path: String
    /// A monotonically increasing version counter for this loader session.
    let version: Int
    /// The wall-clock time the library was loaded.
    let loadedAt: Date
}

// MARK: - Loader

/// Loads compiled `.dylib` files into the running process using `dlopen`.
///
/// Each call to `load(dylibPath:)` opens the library with `RTLD_NOW` so that all
/// symbol references are resolved immediately — any unresolved symbols surface as
/// an error at load time rather than crashing later.
///
/// - Important: Loaded images are never closed via `dlclose`. On Apple platforms
///   `dlclose` does not reliably unload code, and calling it can leave dangling
///   function pointers that cause crashes. The OS reclaims memory when the process exits.
final class DylibLoader {

    // MARK: - Properties

    /// All images loaded during this session, ordered by version (oldest first).
    private(set) var loadedImages: [LoadedImage] = []

    /// The next version number to assign.
    private var nextVersion: Int = 1

    // MARK: - Loading

    /// Load a dynamic library at the given path.
    ///
    /// - Parameter dylibPath: Absolute path to a `.dylib` file.
    /// - Returns: A `LoadedImage` representing the newly loaded library.
    /// - Throws: `DylibLoaderError.fileNotFound` if the file does not exist,
    ///           or `DylibLoaderError.loadFailed` if `dlopen` fails.
    @discardableResult
    func load(dylibPath: String) throws -> LoadedImage {
        guard FileManager.default.fileExists(atPath: dylibPath) else {
            throw DylibLoaderError.fileNotFound(dylibPath)
        }

        // Clear any stale dlerror state before calling dlopen.
        _ = dlerror()

        guard let handle = dlopen(dylibPath, RTLD_NOW) else {
            let errorMessage = dlerror().flatMap { String(cString: $0) } ?? "unknown dlopen error"
            throw DylibLoaderError.loadFailed(path: dylibPath, reason: errorMessage)
        }

        let image = LoadedImage(
            handle: handle,
            path: dylibPath,
            version: nextVersion,
            loadedAt: Date()
        )

        nextVersion += 1
        loadedImages.append(image)

        return image
    }

    // MARK: - Symbol Lookup

    /// Resolve the address of a symbol within a loaded image.
    ///
    /// - Parameters:
    ///   - name: The mangled symbol name to look up (e.g. `_$s7MyClass4nameSSvg`).
    ///   - image: The loaded image to search in.
    /// - Returns: A pointer to the symbol, or `nil` if it could not be found.
    func symbol(named name: String, in image: LoadedImage) -> UnsafeMutableRawPointer? {
        // Clear stale error state.
        _ = dlerror()

        let result = dlsym(image.handle, name)
        return result
    }

    /// Resolve the address of a symbol, throwing on failure.
    ///
    /// - Parameters:
    ///   - name: The mangled symbol name to look up.
    ///   - image: The loaded image to search in.
    /// - Returns: A non-nil pointer to the symbol.
    /// - Throws: `DylibLoaderError.symbolNotFound` if `dlsym` returns `nil`.
    func requiredSymbol(named name: String, in image: LoadedImage) throws -> UnsafeMutableRawPointer {
        // Clear stale error state.
        _ = dlerror()

        guard let result = dlsym(image.handle, name) else {
            let reason = dlerror().flatMap { String(cString: $0) }
            throw DylibLoaderError.symbolNotFound(name: name, reason: reason)
        }

        return result
    }
}
#endif
