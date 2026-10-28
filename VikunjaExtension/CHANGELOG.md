# Vikunja Extension Changelog

## 0.1

- Initial release: live task search, due-date browsing with a By Project group, project
  browsing, Open in Vikunja, Mark Done, Add to Vikunja, Add to Vikunja Project, and the New
  Vikunja Task quick-capture entry.
- Server URLs must use HTTPS (plain HTTP only for `localhost`), since the API token is sent
  with every request.
- With several connections, one failing server shows its error in its own group without
  hiding results from the others.
- Task lists stop at 300 open tasks (100 per search) and say so when cut off; project lists
  are fetched in full.
- Requires Tuna 0.96 / TunaKit 1.22.0 and macOS 15.
