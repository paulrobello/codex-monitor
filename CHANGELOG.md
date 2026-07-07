# Changelog

## Unreleased

- Support multiple labeled OpenRouter API keys and show one usage snapshot per key.
- Show the selected OpenRouter key label as a subheader in the smallest widget while keeping compact Usage and Credits percentages.
- Hide cached usage for disabled providers across the app, menu bar, widgets, and Beacon API output.
- Show the next refresh countdown in the main app instead of the fetched-at age.
- Schedule widget countdown timeline entries so the macOS widget refresh remaining time advances.
- Fix widget next-refresh text so it shows minute-only countdowns until the final minute, then switches to seconds.
- Track each widget entry's next refresh date and use it for the WidgetKit timeline policy.
- Keep the visible widget refresh countdown updating without requiring the app to be running.
