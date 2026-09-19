<a id="42b695d8-0001"></a>

# Project display text

The framework's [language guide](https://github.com/alissonsol/yuruna/blob/main/docs/globalization.md)
explains locale selection, catalog messages, supported languages, and reviewed
translation exchange. English remains the source for official project display
values. [Portuguese documents](pt-BR/index.md) cover the translated operator
subset; runtime language support follows the framework locale manifest.

Keep project IDs, file paths, commands, image names, and protocol fields stable.
Translate only enrolled display fields through the project locale map and its
source-hash sidecar. Do not rename YAML keys to translate a description.
The framework export includes these fields with their source text and pointer;
the validated import places reviewed values at that exact field.

When English changes, export a new request from both current repositories.
Unchanged reviewed values carry forward; changed rows need a translator and a
different reviewer. Run `tools/Invoke-ProjectLocaleMap.ps1 -ProjectRoot` from
the framework with this checkout's absolute path, and then the full paired
gate. A matching source hash proves which text was reviewed, not that review
happened; retain the real reviewer metadata supplied by the exchange.

Back to the [project guide](../README.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.
