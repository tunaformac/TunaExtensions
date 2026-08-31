import Foundation
import TunaKit

@objc(Messages2FAExtension)
public final class Messages2FAExtension: Extension {
  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "Messages 2FA",
        author: "Tuna",
        description: "Find and use recent two-factor authentication codes from Messages.",
        iconName: "message.badge"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.95", minTunaKit: "1.21.0"),
      settings: Messages2FASettings.definitions,
      catalogs: [
        CatalogDeclaration(
          id: "messages-2fa",
          type: Messages2FACatalog.self,
          name: "Messages 2FA",
          presentation: .source,
          enabledByDefault: true
        )
      ],
      typeRegistrations: [
        TypeRegistrationDefinition(
          typeID: .authenticationCode,
          displayName: "Authentication Codes",
          inheritsFrom: [.textSnippet]
        )
      ],
      appBrowseEnrichments: [
        AppBrowseEnrichmentDefinition(
          bundleIdentifiers: ["com.apple.MobileSMS"],
          entries: [AppBrowseEnrichmentEntryDefinition(catalogIdentifier: "messages-2fa")]
        )
      ]
    )
  }
}

enum Messages2FASettings {
  static let lookBackMinutes = CatalogSettingDefinition(
    key: "LookBackMinutes",
    type: .string,
    label: "Look back",
    defaultValue: "10",
    description: "How far back Tuna searches incoming Messages for authentication codes.",
    options: [
      .init(value: "5", label: "5 minutes"),
      .init(value: "10", label: "10 minutes"),
      .init(value: "30", label: "30 minutes"),
      .init(value: "60", label: "1 hour"),
    ]
  )
  static let ignoreRead = CatalogSettingDefinition(
    key: "IgnoreRead",
    type: .bool,
    label: "Ignore read messages",
    defaultValue: "false",
    description: "Only show codes from messages you have not read."
  )

  static let definitions = [lookBackMinutes, ignoreRead]

  static var current: Values {
    let bundle = Bundle(for: Messages2FAExtension.self)
    let identifier = bundle.bundleIdentifier
      ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "TunaMessages2FA")
    let store = CatalogSettingStore(catalogIdentifier: identifier)
    let rawMinutes = store.stringValue(for: lookBackMinutes)
    let requestedMinutes = Int(rawMinutes) ?? 10
    let minutes = [5, 10, 30, 60].contains(requestedMinutes) ? requestedMinutes : 10
    return Values(minutes: minutes, ignoreRead: store.boolValue(for: ignoreRead))
  }

  struct Values: Sendable {
    let minutes: Int
    let ignoreRead: Bool
  }
}

extension TypeID {
  static let authenticationCode = TypeID("com.tuna.type.authentication-code")
}
