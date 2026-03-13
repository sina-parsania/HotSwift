//
//  ChangeAnalyzer.swift
//  HotSwift
//
//  Created by Sina Parsa on 13/3/26.
//

// Uses SwiftSyntax to compare old and new versions of a Swift file to determine ChangeType

#if DEBUG
import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - Change Analyzer

/// Compares successive versions of a Swift source file to classify
/// what kind of change occurred (`ChangeType`).
///
/// The analyzer caches the previous `SourceFileSyntax` for each watched
/// file path so it can diff the structural elements efficiently.
///
/// **Structural elements** — if any of these change the result is `.structural`:
///   - Stored property declarations (name, type, default value, attributes, modifiers)
///   - Type declarations (class, struct, enum, protocol — including attributes, modifiers, generics)
///   - Enum cases
///   - Init signatures (parameter types / labels)
///   - Function signatures (name, params, return type, generics)
///   - Subscript declarations
///   - Typealias declarations
///   - Extension declarations with conformances and generic constraints
///   - Protocol conformances / inheritance clauses
///   - Import statements
///   - Properties with willSet/didSet observers (stored, not computed)
///
/// If ONLY method / computed-property bodies differ the result is `.bodyOnly`.
final class ChangeAnalyzer {

    // MARK: - Properties

    /// Cache of the last parsed syntax tree per file path.
    private var previousTrees: [String: SourceFileSyntax] = [:]

    /// Thread-safety lock for `previousTrees` access.
    private let lock = NSLock()

    // MARK: - Public API

    /// Analyze a file change and return the appropriate `ChangeType`.
    ///
    /// - Parameters:
    ///   - filePath: Absolute path to the changed `.swift` file.
    ///   - eventType: The raw file-system event type (created / modified / deleted).
    /// - Returns: A `ChangeType` describing how the file changed.
    func analyze(filePath: String, eventType: FileEventType) -> ChangeType {
        switch eventType {
        case .created:
            cacheCurrentTree(for: filePath)
            return .newFile

        case .deleted:
            lock.lock()
            previousTrees.removeValue(forKey: filePath)
            lock.unlock()
            return .deleted

        case .modified:
            return analyzeModification(filePath: filePath)
        }
    }

    /// Clears all cached syntax trees.
    func resetCache() {
        lock.lock()
        previousTrees.removeAll()
        lock.unlock()
    }

    // MARK: - Private Methods

    /// Analyze a modification by comparing the old and new syntax trees.
    private func analyzeModification(filePath: String) -> ChangeType {
        guard let newSource = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return .structural
        }

        let newTree = Parser.parse(source: newSource)

        lock.lock()
        let oldTree = previousTrees[filePath]
        previousTrees[filePath] = newTree
        lock.unlock()

        guard let oldTree else {
            // First time seeing this file — treat as structural
            // so Xcode rebuilds with the correct state.
            return .structural
        }

        let oldFingerprint = StructuralFingerprint(tree: oldTree)
        let newFingerprint = StructuralFingerprint(tree: newTree)

        if oldFingerprint == newFingerprint {
            return .bodyOnly
        }

        return .structural
    }

    /// Parse and cache the current file contents.
    private func cacheCurrentTree(for filePath: String) {
        guard let source = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return
        }
        lock.lock()
        previousTrees[filePath] = Parser.parse(source: source)
        lock.unlock()
    }
}

// MARK: - Structural Fingerprint

/// A lightweight, `Equatable` snapshot of a source file's structural elements.
///
/// Two fingerprints are equal if and only if all structural elements match,
/// regardless of method / computed-property body content.
private struct StructuralFingerprint: Equatable {

    let importStatements: [String]
    let typeDeclarations: [String]
    let storedProperties: [String]
    let enumCases: [String]
    let initSignatures: [String]
    let inheritanceClauses: [String]
    let functionSignatures: [String]
    let typealiasDeclarations: [String]
    let extensionDeclarations: [String]

    init(tree: SourceFileSyntax) {
        let visitor = StructuralVisitor(viewMode: .sourceAccurate)
        visitor.walk(tree)

        // Order-insensitive: sorting is safe (adding an import anywhere shouldn't matter)
        self.importStatements = visitor.importStatements.sorted()
        self.typeDeclarations = visitor.typeDeclarations.sorted()
        self.inheritanceClauses = visitor.inheritanceClauses.sorted()
        self.functionSignatures = visitor.functionSignatures.sorted()
        self.typealiasDeclarations = visitor.typealiasDeclarations.sorted()
        self.extensionDeclarations = visitor.extensionDeclarations.sorted()

        // Order-sensitive: declaration order affects memory layout, raw values, or semantics
        self.storedProperties = visitor.storedProperties
        self.enumCases = visitor.enumCases
        self.initSignatures = visitor.initSignatures
    }
}

// MARK: - Structural Visitor

/// A `SyntaxVisitor` that collects structural elements from a Swift source file.
private final class StructuralVisitor: SyntaxVisitor {

    var importStatements: [String] = []
    var typeDeclarations: [String] = []
    var storedProperties: [String] = []
    var enumCases: [String] = []
    var initSignatures: [String] = []
    var inheritanceClauses: [String] = []
    var functionSignatures: [String] = []
    var typealiasDeclarations: [String] = []
    var extensionDeclarations: [String] = []

    // MARK: - Import Statements

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        importStatements.append(node.trimmedDescription)
        return .skipChildren
    }

    // MARK: - Type Declarations

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let attributes = node.attributes.trimmedDescription
        let modifiers = node.modifiers.trimmedDescription
        let genericParams = node.genericParameterClause?.trimmedDescription ?? ""
        let genericWhere = node.genericWhereClause?.trimmedDescription ?? ""
        typeDeclarations.append("class:\(attributes) \(modifiers) \(node.name.trimmedDescription)\(genericParams)\(genericWhere)")
        if let inheritance = node.inheritanceClause {
            inheritanceClauses.append("\(node.name.trimmedDescription):\(inheritance.trimmedDescription)")
        }
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        let attributes = node.attributes.trimmedDescription
        let modifiers = node.modifiers.trimmedDescription
        let genericParams = node.genericParameterClause?.trimmedDescription ?? ""
        let genericWhere = node.genericWhereClause?.trimmedDescription ?? ""
        typeDeclarations.append("struct:\(attributes) \(modifiers) \(node.name.trimmedDescription)\(genericParams)\(genericWhere)")
        if let inheritance = node.inheritanceClause {
            inheritanceClauses.append("\(node.name.trimmedDescription):\(inheritance.trimmedDescription)")
        }
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let attributes = node.attributes.trimmedDescription
        let modifiers = node.modifiers.trimmedDescription
        let genericParams = node.genericParameterClause?.trimmedDescription ?? ""
        let genericWhere = node.genericWhereClause?.trimmedDescription ?? ""
        typeDeclarations.append("enum:\(attributes) \(modifiers) \(node.name.trimmedDescription)\(genericParams)\(genericWhere)")
        if let inheritance = node.inheritanceClause {
            inheritanceClauses.append("\(node.name.trimmedDescription):\(inheritance.trimmedDescription)")
        }
        return .visitChildren
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        let attributes = node.attributes.trimmedDescription
        let modifiers = node.modifiers.trimmedDescription
        let genericWhere = node.genericWhereClause?.trimmedDescription ?? ""
        typeDeclarations.append("protocol:\(attributes) \(modifiers) \(node.name.trimmedDescription)\(genericWhere)")
        if let inheritance = node.inheritanceClause {
            inheritanceClauses.append("\(node.name.trimmedDescription):\(inheritance.trimmedDescription)")
        }
        return .visitChildren
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        let attributes = node.attributes.trimmedDescription
        let modifiers = node.modifiers.trimmedDescription
        let genericParams = node.genericParameterClause?.trimmedDescription ?? ""
        let genericWhere = node.genericWhereClause?.trimmedDescription ?? ""
        typeDeclarations.append("actor:\(attributes) \(modifiers) \(node.name.trimmedDescription)\(genericParams)\(genericWhere)")
        if let inheritance = node.inheritanceClause {
            inheritanceClauses.append("\(node.name.trimmedDescription):\(inheritance.trimmedDescription)")
        }
        return .visitChildren
    }

    // MARK: - Extension Declarations

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let extendedType = node.extendedType.trimmedDescription
        let inheritance = node.inheritanceClause?.trimmedDescription ?? ""
        let genericWhere = node.genericWhereClause?.trimmedDescription ?? ""
        extensionDeclarations.append("extension \(extendedType)\(inheritance)\(genericWhere)")
        return .visitChildren
    }

    // MARK: - Enum Cases

    override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
        enumCases.append(node.trimmedDescription)
        return .skipChildren
    }

    // MARK: - Stored Properties

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        // Capture stored properties (including those with willSet/didSet observers).
        // Computed properties (with get/set or getter body) are body-only changes.
        for binding in node.bindings {
            if let accessorBlock = binding.accessorBlock {
                // Check if this is a stored property with observers (willSet/didSet)
                let isObserver: Bool
                switch accessorBlock.accessors {
                case .accessors(let list):
                    isObserver = list.allSatisfy {
                        $0.accessorSpecifier.tokenKind == .keyword(.willSet) ||
                        $0.accessorSpecifier.tokenKind == .keyword(.didSet)
                    }
                case .getter:
                    isObserver = false
                }
                if isObserver {
                    let name = binding.pattern.trimmedDescription
                    let typeAnnotation = binding.typeAnnotation?.trimmedDescription ?? ""
                    let initializer = binding.initializer?.trimmedDescription ?? ""
                    let attributes = node.attributes.trimmedDescription
                    let modifiers = node.modifiers.trimmedDescription
                    storedProperties.append("\(attributes) \(modifiers) \(node.bindingSpecifier.trimmedDescription) \(name) \(typeAnnotation) \(initializer)")
                }
            } else {
                // No accessor block — plain stored property.
                let name = binding.pattern.trimmedDescription
                let typeAnnotation = binding.typeAnnotation?.trimmedDescription ?? ""
                let initializer = binding.initializer?.trimmedDescription ?? ""
                let attributes = node.attributes.trimmedDescription
                let modifiers = node.modifiers.trimmedDescription
                storedProperties.append("\(attributes) \(modifiers) \(node.bindingSpecifier.trimmedDescription) \(name) \(typeAnnotation) \(initializer)")
            }
        }
        return .skipChildren
    }

    // MARK: - Init Signatures

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        // Capture the full parameter signature but NOT the body.
        let params = node.signature.trimmedDescription
        let optionalMark = node.optionalMark?.trimmedDescription ?? ""
        initSignatures.append("init\(optionalMark)\(params)")
        return .skipChildren
    }

    // MARK: - Function Signatures

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let modifiers = node.modifiers.trimmedDescription
        let name = node.name.trimmedDescription
        let signature = node.signature.trimmedDescription
        let genericParams = node.genericParameterClause?.trimmedDescription ?? ""
        let genericWhere = node.genericWhereClause?.trimmedDescription ?? ""
        functionSignatures.append("\(modifiers) func \(name)\(genericParams)\(signature)\(genericWhere)")
        return .skipChildren
    }

    // MARK: - Subscript Declarations

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        let modifiers = node.modifiers.trimmedDescription
        let params = node.parameterClause.trimmedDescription
        let returnType = node.returnClause.trimmedDescription
        functionSignatures.append("\(modifiers) subscript\(params)\(returnType)")
        return .skipChildren
    }

    // MARK: - Typealias Declarations

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        typealiasDeclarations.append(node.trimmedDescription)
        return .skipChildren
    }

    // MARK: - Deinitializer (skip body)

    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        return .skipChildren
    }
}

#endif
