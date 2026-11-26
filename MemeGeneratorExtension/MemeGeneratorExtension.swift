import Foundation
import TunaKit

@objc(MemeGeneratorExtension)
public final class MemeGeneratorExtension: Extension {
  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "Meme Generator",
        author: "Tuna",
        description: "Make memes from Memegen and Imgflip templates.",
        iconName: "face.smiling"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.113", minTunaKit: "1.22.0"),
      settings: MemeSettings.definitions,
      catalogs: [
        // Templates are only reached through "Make Meme"; they stay out of global search. Browse
        // roots take no scope: Make Meme is always searchable while enabled.
        CatalogDeclaration(
          id: "memes.templates", type: MemeTemplatesCatalog.self, name: "Meme Templates",
          presentation: .source,
          description: "Templates shown inside Make Meme. Not in global search by default.",
          enabledByDefault: true, initialGlobalScope: .none),
        CatalogDeclaration(
          id: "memes.templates.browse", type: MemeTemplatesBrowseCatalog.self,
          name: "Make Meme", presentation: .browseRoot(contents: "memes.templates"),
          enabledByDefault: true),
      ],
      actionCatalogs: [
        ActionCatalogDeclaration(
          id: "memes.actions", type: MemeActionsCatalog.self, name: "Meme Actions")
      ],
      typeRegistrations: [
        TypeRegistrationDefinition(
          typeID: .memeTemplate, displayName: "Meme Templates", inheritsFrom: [.entity]),
        TypeRegistrationDefinition(
          typeID: .memeImage, displayName: "Memes", inheritsFrom: [.file]),
      ],
      defaultActionRankings: [
        DefaultActionRankingDefinition(
          typeID: .memeTemplate,
          actions: [
            ActionReference(catalogIdentifier: "memes.actions", actionID: "make-meme"),
            ActionReference(catalogIdentifier: "memes.actions", actionID: "add-favorite"),
            ActionReference(catalogIdentifier: "memes.actions", actionID: "remove-favorite"),
          ]
        ),
        DefaultActionRankingDefinition(
          typeID: .memeImage,
          actions: [
            ActionReference(catalogIdentifier: "memes.actions", actionID: "copy-image"),
            ActionReference(catalogIdentifier: "memes.actions", actionID: "copy-url"),
          ]
        ),
      ]
    )
  }
}

enum MemeSettings {
  static let imgflipUsername = CatalogSettingDefinition(
    key: "ImgflipUsername",
    type: .string,
    label: "Imgflip username (optional)",
    defaultValue: "",
    description:
      "Adds Imgflip's 100 most popular templates. Create a free account at https://imgflip.com/signup."
  )

  static let imgflipPassword = CatalogSettingDefinition(
    key: "ImgflipPassword",
    type: .secret,
    label: "Imgflip password (optional)",
    defaultValue: "",
    description: "Used only to caption Imgflip templates. It stays in your Mac Keychain."
  )

  static let definitions = [imgflipUsername, imgflipPassword]

  static var imgflipCredentials: ImgflipCredentials? {
    let store = currentStore
    let username = store.stringValue(for: imgflipUsername)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let password = store.secretValue(for: imgflipPassword) ?? ""
    guard !username.isEmpty, !password.isEmpty else { return nil }
    return ImgflipCredentials(username: username, password: password)
  }

  static var enabledProviders: [MemeProvider] {
    imgflipCredentials == nil ? [.memegen] : [.memegen, .imgflip]
  }

  private static var currentStore: CatalogSettingStore {
    let bundle = Bundle(for: MemeGeneratorExtension.self)
    let identifier = bundle.bundleIdentifier
      ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "TunaMemeGenerator")
    return CatalogSettingStore(catalogIdentifier: identifier)
  }
}

extension TypeID {
  static let memeTemplate = TypeID("com.tuna.type.meme-template")
  static let memeImage = TypeID("com.tuna.type.meme-image")
}
