local _ = require("gettext")
return {
    fullname = _("Miniflux Download"),
    description = _([[Downloads unread articles from a Miniflux server as EPUB files (with images) for offline reading.]]),
    -- `version` and `built_at` are placeholders in the repository and are
    -- rewritten by the CI when it builds a release artifact (see
    -- .github/workflows/release.yml). They drive the in-app updater: a build
    -- with version "dev" / no `built_at` is treated as older than any release.
    version = "dev",
    built_at = nil,
}
