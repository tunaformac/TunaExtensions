import Foundation
import TunaKit

@objc(MyMindExtension)
public final class MyMindExtension: Extension {
  static let catalogIdentifier = "mymind"

  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "mymind",
        author: "Tuna",
        description: "Search, browse, resolve, and save objects in your mind.",
        iconName: "brain"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.83", minTunaKit: "1.18.0"),
      settings: MyMindSettings.definitions,
      catalogs: [
        CatalogDeclaration(
          id: Self.catalogIdentifier,
          type: MyMindCatalog.self,
          name: "mymind",
          enabledByDefault: true
        ),
        CatalogDeclaration(
          id: "mymind.spaces",
          type: MyMindSpacesCatalog.self,
          name: "mymind Spaces",
          enabledByDefault: true
        )
      ],
      actionCatalogs: [
        ActionCatalogDeclaration(
          id: "mymind.actions",
          type: MyMindActionsCatalog.self,
          name: "mymind Actions"
        )
      ],
      typeRegistrations: [
        TypeRegistrationDefinition(
          typeID: .myMindObject,
          displayName: "mymind Objects",
          inheritsFrom: [.entity]
        ),
        TypeRegistrationDefinition(
          typeID: .myMindSpace,
          displayName: "mymind Spaces",
          inheritsFrom: [.entity]
        ),
      ],
      defaultActionRankings: [
        DefaultActionRankingDefinition(
          typeID: .myMindObject,
          actions: [
            ActionReference(catalogIdentifier: "mymind.actions", actionID: "resolve"),
            ActionReference(catalogIdentifier: "mymind.actions", actionID: "open-original"),
          ]
        )
      ],
      appBrowseEnrichments: [
        AppBrowseEnrichmentDefinition(
          bundleIdentifiers: ["com.mymind.mymind-mac"],
          entries: [
            AppBrowseEnrichmentEntryDefinition(catalogIdentifier: Self.catalogIdentifier)
          ]
        )
      ],
      appActionEnrichments: [
        AppActionEnrichmentDefinition(
          bundleIdentifiers: ["com.mymind.mymind-mac"],
          catalogIdentifiers: ["mymind.actions"]
        )
      ]
    )
  }
}

enum MyMindSettings {
  static let keyID = CatalogSettingDefinition(
    key: "KeyID",
    type: .string,
    label: "Key ID",
    defaultValue: "",
    description: "Create an access key at https://access.mymind.com/extensions."
  )
  static let privateKey = CatalogSettingDefinition(
    key: "PrivateKey",
    type: .secret,
    label: "Private Key",
    defaultValue: "",
    description: "The base64 private key shown once by mymind. It stays in your Mac Keychain."
  )
  static let accessLevel = CatalogSettingDefinition(
    key: "AccessLevel",
    type: .string,
    label: "Access Level",
    defaultValue: MyMindAccessLevel.readOnly.rawValue,
    description: "This must match the access level selected when the key was created.",
    options: [
      .init(value: MyMindAccessLevel.readOnly.rawValue, label: "Read only"),
      .init(value: MyMindAccessLevel.fullAccess.rawValue, label: "Full access"),
    ]
  )

  static let definitions = [keyID, privateKey, accessLevel]

  static func credentials(for type: AnyClass) throws -> MyMindCredentials {
    let bundle = Bundle(for: type)
    let identifier = bundle.bundleIdentifier
      ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "MyMindExtension")
    let store = CatalogSettingStore(catalogIdentifier: identifier)
    let keyIDValue = store.stringValue(for: keyID).trimmingCharacters(in: .whitespacesAndNewlines)
    let privateKeyValue: String
    switch store.readSecretValue(for: privateKey) {
    case .found(let value):
      privateKeyValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    case .notFound:
      privateKeyValue = ""
    case .failed:
      throw MyMindAPIError.keychainAccessDenied
    @unknown default:
      throw MyMindAPIError.keychainAccessDenied
    }
    let levelValue = store.stringValue(for: accessLevel)

    guard !keyIDValue.isEmpty, !privateKeyValue.isEmpty else {
      throw MyMindAPIError.credentialsRequired
    }
    guard let level = MyMindAccessLevel(rawValue: levelValue) else {
      throw MyMindAPIError.invalidAccessLevel
    }
    return MyMindCredentials(keyID: keyIDValue, privateKey: privateKeyValue, accessLevel: level)
  }
}

extension TypeID {
  static let myMindObject = TypeID("com.tuna.type.mymind-object")
  static let myMindSpace = TypeID("com.tuna.type.mymind-space")
}
