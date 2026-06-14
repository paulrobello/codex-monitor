# Changelog

## Unreleased

- Show the next refresh countdown in the main app instead of the fetched-at age.
- Schedule widget countdown timeline entries so the macOS widget refresh remaining time advances.
- Fix widget next-refresh text so it shows minute-only countdowns until the final minute, then switches to seconds.
- Track each widget entry's next refresh date and use it for the WidgetKit timeline policy.
- Keep the visible widget refresh countdown updating without requiring the app to be running.
