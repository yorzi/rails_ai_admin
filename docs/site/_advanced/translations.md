---
layout: default
title: Translations
nav_order: 10
description: Translate every page, notice and validation message the admin shows, with ordinary Rails I18n.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* Where the admin's English text lives and how to add a locale.
* How the current locale is chosen for a request.
* Which text is not translated by the engine.

## Where the Text Lives

Every string the admin shows comes from the engine's
`config/locales/en.yml`, under the `rails_ai_admin` key: page headings,
buttons, notices, status pages, field validation messages, Chat messages and
the few messages its JavaScript shows (`rails_ai_admin.script`). Rails loads
the file automatically.

To translate the admin, copy that file into your application as
`config/locales/rails_ai_admin.de.yml`, change the top-level `en:` to `de:`
and translate the values. Keep every `%{…}` placeholder, and keep keys ending
in `_html` as HTML-safe text: their placeholders receive markup such as a
`<time>` or `<code>` element.

To change one English sentence, override only that key in your own
`config/locales/en.yml`:

```yaml
en:
  rails_ai_admin:
    dashboard:
      intro: Choose what you want to manage today.
```

## Choosing the Locale

The engine never picks a locale. It uses `I18n.locale` as your application set
it, so set it the way you already do, for example in an `around_action` in a
controller the admin inherits from, or with
`config.i18n.default_locale`. The page's `<html lang>` follows the locale.

Missing keys behave as your I18n configuration says. Enable
`config.i18n.fallbacks` if a partial translation should fall back to English,
and `config.i18n.raise_on_missing_translations` in tests to catch a missing key.

## Not Translated Here

* **Your resource text**: resource labels, field labels, help text, choice
  labels and operation descriptions are what you declared. Pass translated
  strings (for example `label: I18n.t("admin.orders")`) if you need them per
  locale; they are read when resources load, not per request.
* **Model validation messages** come from your models and Rails' own locale
  files.
* **Text sent to the AI model**: tool descriptions and tool results stay in
  English, which models follow most reliably. The model may still answer in the
  language the person writes in.
* **Formats**: dates and timestamps in lists use a fixed, unambiguous format
  (`30 Oct 2026 01:30 UTC`).
