# Changelog

## 0.2.1

- Initial release: Add to Fantastical, Add Task to Fantastical, Search Fantastical, and Show Date
  in Fantastical text actions; Today, Tomorrow, Calendar, Mini Window, and calendar set views;
  app browse and action enrichment for Fantastical.app.
- Inline fields after a configurable separator (default `--`): title, start, end, due, allday,
  cal, url, notes map to Fantastical's parse parameters. Em and en dashes produced by macOS
  smart-dash substitution count as `--`.
- Add to Fantastical and Add Task accept link items: the title becomes the sentence and the address
  fills `url`.
