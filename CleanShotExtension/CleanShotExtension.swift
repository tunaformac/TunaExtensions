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
        description: "CleanShot X captures and utilities.",
        iconName: "camera.viewfinder"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.79", minTunaKit: "1.13.0"),
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
