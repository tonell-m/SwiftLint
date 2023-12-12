import Foundation
import SwiftLintCore
import SwiftSyntax

struct RedundantTypeAnnotationRule: SwiftSyntaxCorrectableRule, OptInRule {
    var configuration = RedundantTypeAnnotationConfiguration()

    func makeVisitor(file: SwiftLintFile) -> ViolationsSyntaxVisitor<ConfigurationType> {
        Visitor(configuration: configuration, file: file)
    }

    func makeRewriter(file: SwiftLintFile) -> (some ViolationsSyntaxRewriter)? {
        Rewriter(
            configuration: configuration,
            locationConverter: file.locationConverter,
            disabledRegions: disabledRegions(file: file)
        )
    }
}

private extension RedundantTypeAnnotationRule {
    final class Visitor: ViolationsSyntaxVisitor<ConfigurationType> {
        override func visitPost(_ node: VariableDeclSyntax) {
            guard node.isViolation(for: configuration),
                  let binding = node.bindings.last,
                  let typeAnnotation = binding.typeAnnotation
            else {
                return
            }

            violations.append(typeAnnotation.positionAfterSkippingLeadingTrivia)
        }
    }

    final class Rewriter: ViolationsSyntaxRewriter {
        private let configuration: RedundantTypeAnnotationConfiguration

        init(configuration: RedundantTypeAnnotationConfiguration,
             locationConverter: SourceLocationConverter,
             disabledRegions: [SourceRange]) {
            self.configuration = configuration

            super.init(locationConverter: locationConverter, disabledRegions: disabledRegions)
        }

        override func visit(_ node: VariableDeclSyntax) -> DeclSyntax {
            guard node.isViolation(for: configuration),
                  let lastBinding = node.bindings.last,
                  let typeAnnotation = lastBinding.typeAnnotation,
                  let initializer = lastBinding.initializer
            else {
                return super.visit(node)
            }

            correctionPositions.append(typeAnnotation.positionAfterSkippingLeadingTrivia)

            // Add a leading whitespace to the initializer sequence so there is one
            // between the variable name and the '=' sign
            let initializerWithLeadingWhitespace = initializer
                .with(\.leadingTrivia, Trivia.space)
            // Set the type annotation of the last binding to nil to remove redundancy
            let lastBindingWithoutTypeAnnotation = lastBinding
                .with(\.typeAnnotation, nil)
                .with(\.initializer, initializerWithLeadingWhitespace)

            return super.visit(node.with(
                \.bindings,
                node.bindings.dropLast() + [lastBindingWithoutTypeAnnotation]
            ))
        }
    }
}

private extension VariableDeclSyntax {
    func isViolation(for configuration: RedundantTypeAnnotationConfiguration) -> Bool {
        // Checks if none of the attributes flagged as ignored in the configuration
        // are set for this declaration
        let doesNotContainIgnoredAttributes = configuration.ignoredAnnotations.allSatisfy {
            !self.attributes.contains(attributeNamed: $0)
        }

        // Only take the last binding into account in case multiple
        // variables are declared on a single line.
        // This binding must have both a type declaration and an initializer
        // sequence for it to be potentially redundant.
        guard doesNotContainIgnoredAttributes,
              let binding = bindings.last,
              let typeAnnotation = binding.typeAnnotation,
              let type = typeAnnotation.type.as(IdentifierTypeSyntax.self),
              let typeName = type.typeName,
              var initializer = binding.initializer?.value
        else {
            return false
        }

        if let forceUnwrap = initializer.as(ForceUnwrapExprSyntax.self) {
            initializer = forceUnwrap.expression
        }

        // If the initializer is a function call (generally a constructor or static builder),
        // check if the base type is the same as the one from the type annotation.
        if let functionCall = initializer.as(FunctionCallExprSyntax.self) {
            if let calledExpression = functionCall.calledExpression.as(DeclReferenceExprSyntax.self) {
                // Parse generic arguments if there are any.
                var genericArguments = ""
                if let genericArgumentsClauseBytes = type.genericArguments?.trimmed.syntaxTextBytes {
                    genericArguments = String(bytes: genericArgumentsClauseBytes, encoding: .utf8) ?? ""
                }
                return calledExpression.baseName.text == typeName + genericArguments
            }

            // If the function call is a member access expression, check if it is a violation
            return isMemberAccessViolation(node: functionCall.calledExpression, typeName: typeName)
        }

        // If the initializer is a boolean expression, we consider using the `Bool` type
        // annotation as redundant.
        if initializer.as(BooleanLiteralExprSyntax.self) != nil {
            return typeName == "Bool"
        }

        // If the initializer is a member access, check if the base type name is the same as
        // the type annotation
        return isMemberAccessViolation(node: initializer, typeName: typeName)
    }

    /// Checks if the given node is a member access (i.e. an enum case or a static property or function)
    /// and if so checks if the base type is the same as the given type name.
    private func isMemberAccessViolation(node: some SyntaxProtocol, typeName: String) -> Bool {
        guard let memberAccess = node.as(MemberAccessExprSyntax.self),
              let base = memberAccess.base?.as(DeclReferenceExprSyntax.self) else {
            // If the type is implicit, `base` will be nil, meaning there is no redundancy.
            return false
        }

        return base.baseName.text == typeName
    }
}

extension RedundantTypeAnnotationRule {
    static let description = RuleDescription(
        identifier: "redundant_type_annotation",
        name: "Redundant Type Annotation",
        description: "Variables should not have redundant type annotation",
        kind: .idiomatic,
        nonTriggeringExamples: [
            Example("var url = URL()"),
            Example("var url: CustomStringConvertible = URL()"),
            Example("@IBInspectable var color: UIColor = UIColor.white"),
            Example("""
            enum Direction {
                case up
                case down
            }

            var direction: Direction = .up
            """),
            Example("""
            enum Direction {
                case up
                case down
            }

            var direction = Direction.up
            """),
            Example("var values: Set<Int> = Set([0, 1, 2])")
        ],
        triggeringExamples: [
            Example("var url↓:URL=URL()"),
            Example("var url↓:URL = URL(string: \"\")"),
            Example("var url↓: URL = URL()"),
            Example("let url↓: URL = URL()"),
            Example("lazy var url↓: URL = URL()"),
            Example("let url↓: URL = URL()!"),
            Example("let alphanumerics↓: CharacterSet = CharacterSet.alphanumerics"),
            Example("""
            class ViewController: UIViewController {
              func someMethod() {
                let myVar↓: Int = Int(5)
              }
            }
            """),
            Example("var isEnabled↓: Bool = true"),
            Example("""
            enum Direction {
                case up
                case down
            }

            var direction↓: Direction = Direction.up
            """),
            Example("var num: Int = Int.random(0..<10")
        ],
        corrections: [
            Example("var url↓: URL = URL()"): Example("var url = URL()"),
            Example("let url↓: URL = URL()"): Example("let url = URL()"),
            Example("let alphanumerics↓: CharacterSet = CharacterSet.alphanumerics"):
                Example("let alphanumerics = CharacterSet.alphanumerics"),
            Example("""
            class ViewController: UIViewController {
              func someMethod() {
                let myVar↓: Int = Int(5)
              }
            }
            """):
            Example("""
            class ViewController: UIViewController {
              func someMethod() {
                let myVar = Int(5)
              }
            }
            """),
            Example("var num: Int = Int.random(0..<10)"): Example("var num = Int.random(0..<10)")
        ]
    )
}
