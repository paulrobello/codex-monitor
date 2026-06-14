# Changelog

## Unreleased

- Fix widget next-refresh text so it shows minute-only countdowns until the final minute, then switches to seconds.
- Track each widget entry's next refresh date and use it for the WidgetKit timeline policy.
- Keep the visible widget refresh countdown updating without requiring the app to be running.
