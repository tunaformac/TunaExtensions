import Foundation

/// Response bodies captured from Dokploy's router code (v0.30.7 and v0.24 shapes).
enum DokployFixtures {
  /// `project.all` on v0.29+: services nested in environments, minimal columns only.
  static let projectsWithEnvironments = """
    [
      {
        "projectId": "proj_1",
        "name": "Web",
        "description": null,
        "createdAt": "2026-01-02T10:00:00.000Z",
        "organizationId": "org_1",
        "env": "",
        "projectTags": [],
        "environments": [
          {
            "environmentId": "env_prod",
            "name": "production",
            "isDefault": true,
            "applications": [
              { "applicationId": "app_1", "name": "frontend", "applicationStatus": "done" },
              { "applicationId": "app_2", "name": "api", "applicationStatus": "error" }
            ],
            "compose": [
              { "composeId": "cmp_1", "name": "analytics", "composeStatus": "running" }
            ],
            "postgres": [{ "postgresId": "pg_1" }]
          },
          {
            "environmentId": "env_staging",
            "name": "staging",
            "isDefault": false,
            "applications": [],
            "compose": []
          }
        ]
      },
      {
        "projectId": "proj_2",
        "name": "Empty",
        "environments": []
      }
    ]
    """

  /// `project.all` before v0.25: services directly on the project, full rows.
  static let legacyProjects = """
    [
      {
        "projectId": "proj_old",
        "name": "Legacy",
        "applications": [
          {
            "applicationId": "app_old",
            "name": "blog",
            "appName": "blog-x1y2",
            "applicationStatus": "idle",
            "domains": [{ "host": "blog.example.com", "https": true, "path": "/" }]
          }
        ],
        "compose": [
          { "composeId": "cmp_old", "name": "stack", "appName": "stack-a1", "composeStatus": null }
        ]
      }
    ]
    """

  static let domains = """
    [
      { "domainId": "d0", "host": "off.example.com", "https": true, "path": "/", "port": 3000, "enabled": false },
      { "domainId": "d1", "host": "app.example.com", "https": true, "path": "/docs", "port": 3000 },
      { "domainId": "d2", "host": "plain.example.com", "https": false, "path": "/", "port": 80 }
    ]
    """

  static let unauthorized = #"{"message":"Unauthorized"}"#

  static let trpcNotFound = """
    {"message":"Application not found","code":"NOT_FOUND","data":{"code":"NOT_FOUND","httpStatus":404,"path":"application.one","zodError":null}}
    """

  static let trpcBadRequest = """
    {"message":"Deployment already running","code":"BAD_REQUEST","data":{"code":"BAD_REQUEST","httpStatus":400,"path":"application.deploy","zodError":null}}
    """
}
