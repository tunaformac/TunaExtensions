//
//  CleanShotExtension.swift
//  CleanShotExtension
//

import Foundation
import TunaKit

@objc(CleanShotExtension)
public final class CleanShotExtension: Extension {
  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "CleanShot X",
        author: "Tuna",
        description: "Browse recent CleanShot images and run capture utilities.",
        iconName: "camera.viewfinder"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.84", minTunaKit: "1.17.0"),
      catalogs: [
        CatalogDeclaration(
          id: "cleanshot.commands",
          type: CleanShotCommandsCatalog.self,
          name: "CleanShot Commands",
          enabledByDefault: false
        )
      ],
      appBrowseEnrichments: [
        AppBrowseEnrichmentDefinition(
          bundleIdentifiers: ["pl.maketheweb.cleanshotx"],
          entries: [
            AppBrowseEnrichmentEntryDefinition(catalogIdentifier: "cleanshot.commands")
          ]
        )
      ]
    )
  }
}
