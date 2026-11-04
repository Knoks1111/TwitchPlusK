# Translations

Translations are stored separately in `Languages/fr.strings` and `Languages/en.strings`. Each entry maps a stable key to its text:

```text
"common_ok" = "OK";
```

Files use UTF-8. Preserve keys, meaningful spaces, line breaks, and format specifiers such as `%@`, `%ld`, and `%lu`. Write accented characters directly; escape quotation marks with `\"`, backslashes with `\\`, and line breaks with `\n`. Both `//` and `/* ... */` comments are supported. String escapes follow JSON syntax; write Unicode characters in UTF-8 instead of using OpenStep `\U` sequences.

`make` runs `Sources/Localization/compile_localizations.py` to generate `.theos/localization/tpk-localization-data.h`. This file is compiled into the dylib, so no separate language files or resource bundle need to be copied into the app. Do not edit or commit the generated file. Only Python 3 and its standard library are required.

The manager preserves `L(...)`, manual French/English selection, the `tpk_language` preference, English as the default, and language-change notifications. Missing or empty translations display `[Missing translation: key]`, always in English regardless of the selected language.

To add a language:

1. Create `Languages/<code>.strings` from an existing table and translate its values.
2. Add an entry to `TPKLanguage` and its enum-to-code mapping in `stringForKey:`.
3. Add the language to settings and update settings import handling if needed.
4. Build and test language selection and display. The generator discovers `.strings` files automatically; duplicate keys or syntax errors stop the build.
