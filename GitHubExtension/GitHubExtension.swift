import Foundation
import TunaKit

@objc(GitHubExtension)
public final class GitHubExtension: Extension {
  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "GitHub",
        author: "Tuna",
        description: "GitHub notifications, pull requests, issues, and repositories.",
        iconName: "bell.badge"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.83", minTunaKit: "1.15.0"),
      catalogs: [
        CatalogDeclaration(
          id: "github.notifications",
          type: GitHubNotificationsCatalog.self,
          name: "Notifications",
          enabledByDefault: true
        ),
        CatalogDeclaration(
          id: "github.notifications.unread",
          type: GitHubUnreadNotificationsCatalog.self,
          name: "Unread Notifications",
          enabledByDefault: false
        ),
        CatalogDeclaration(
          id: "github.notifications.all",
          type: GitHubAllNotificationsCatalog.self,
          name: "All Notifications",
          enabledByDefault: false
        ),
        CatalogDeclaration(
          id: "github.pull-requests",
          type: GitHubPullRequestsCatalog.self,
          name: "Pull Requests",
          enabledByDefault: true
        ),
        CatalogDeclaration(
          id: "github.issues",
          type: GitHubIssuesCatalog.self,
          name: "Issues",
          enabledByDefault: true
        ),
        CatalogDeclaration(
          id: "github.repositories",
          type: GitHubRepositoriesCatalog.self,
          name: "Repositories",
          enabledByDefault: true
        ),
      ],
      appBrowseEnrichments: [
        AppBrowseEnrichmentDefinition(
          bundleIdentifiers: ["com.github.GitHubClient"],
          entries: [
            AppBrowseEnrichmentEntryDefinition(
              catalogIdentifier: "github.notifications",
              title: "Notifications"
            ),
            AppBrowseEnrichmentEntryDefinition(
              catalogIdentifier: "github.pull-requests",
              title: "Pull Requests"
            ),
            AppBrowseEnrichmentEntryDefinition(
              catalogIdentifier: "github.issues",
              title: "Issues"
            ),
            AppBrowseEnrichmentEntryDefinition(
              catalogIdentifier: "github.repositories",
              title: "Repositories"
            ),
          ]
        )
      ]
    )
  }

  public override var connectionDefinitions: [ExtensionConnectionDefinition] {
    [GitHubCatalogSupport.connectionDefinition]
  }
}
