import Foundation
import TunaKit

@objc(CloudShareExtension)
public final class CloudShareExtension: Extension {
  static let catalogIdentifier = "cloudshare"
  static let actionsCatalogIdentifier = "cloudshare.actions"

  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "Cloud Share",
        author: "Tuna",
        description: "Upload files to your S3 storage and copy a public link.",
        iconName: "icloud.and.arrow.up"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.112", minTunaKit: "1.23.0"),
      catalogs: [
        CatalogDeclaration(
          id: Self.catalogIdentifier,
          type: CloudShareCatalog.self,
          name: "Cloud Shared",
          presentation: .source,
          enabledByDefault: true
        )
      ],
      actionCatalogs: [
        ActionCatalogDeclaration(
          id: Self.actionsCatalogIdentifier,
          type: CloudShareActionsCatalog.self,
          name: "Cloud Share Actions"
        )
      ],
      typeRegistrations: [
        TypeRegistrationDefinition(
          typeID: .cloudShareDestination,
          displayName: "Cloud Share Destinations",
          inheritsFrom: [.entity]
        ),
        TypeRegistrationDefinition(
          typeID: .cloudShareObject,
          displayName: "Cloud Shared Files",
          inheritsFrom: [.url]
        ),
      ]
    )
  }

  public override var connectionDefinitions: [ExtensionConnectionDefinition] {
    [
      ExtensionConnectionDefinition(
        providerIdentifier: CloudShareSettings.providerIdentifier,
        providerName: "S3 Storage",
        kind: .secret,
        supportsBaseURL: true,
        defaultBaseURL: "",
        baseURLLabel: "Endpoint (leave empty for AWS)",
        secretLabel: "Secret Access Key",
        description:
          "Amazon S3 or an S3-compatible service. The default destination is used by Cloud Share.",
        connectButtonLabel: "Add Destination",
        fields: CloudShareSettings.fields
      )
    ]
  }
}

extension TypeID {
  static let cloudShareDestination = TypeID("com.tuna.type.cloudshare-destination")
  static let cloudShareObject = TypeID("com.tuna.type.cloudshare-object")
}
