<a id="42a0328b-0001"></a>

# Project display text

The framework's [language guide](https://github.com/alissonsol/yuruna/blob/main/docs/globalization.md)
explains locale selection, catalog messages, supported languages, and the
translation exchange. English remains the source for official project display
values. [Portuguese documents](pt-BR/index.md) cover the translated operator
subset; runtime language support follows the framework locale manifest.

Keep project IDs, file paths, commands, image names, and protocol fields stable.
Translate only enrolled display fields through the project locale map and its
source-hash sidecar. Do not rename YAML keys to translate a description.
The framework export includes these fields with their source text and pointer;
the validated import places the returned values at that exact field.

When English changes, the framework's drafter writes a machine draft into
the localized map and marks its sidecar row `"origin": "machine"`; a
professional batch imported through the maintainers' exchange replaces
the draft and removes the marker. Run
`tools/Invoke-ProjectLocaleMap.ps1 -ProjectRoot` from the framework with
this checkout's absolute path, and then the full paired gate. A matching
source hash proves which English text a value translates; the marker says
whether a person has replaced the draft.

Back to the [project guide](../README.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.
