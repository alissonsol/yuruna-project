# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
"""Check service resource keys, placeholders, source hashes, and draft provenance."""
import hashlib
from pathlib import Path
import re
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[2] / 'components/frontend/text-to-sql-ui/Services'
def catalog(path):
    return {row.attrib['name']: (row.findtext('value'), row.findtext('comment'))
            for row in ET.parse(path).getroot().findall('data')}
source = catalog(root / 'ServiceMessages.resx')
used = set()
for path in root.glob('*.cs'):
    used.update(re.findall(r'ServiceMessages.Get\("([^"]+)"', path.read_text()))
assert set(source) == used, (set(source), used)
for locale in ['pt-BR', 'zh-CN', 'he-IL']:
    entries = catalog(root / f'ServiceMessages.{locale}.resx')
    assert set(entries) == used, locale
    for key, (text, comment) in entries.items():
        assert text and text.strip(), (locale, key)
        assert hashlib.sha256(source[key][0].encode()).hexdigest() in comment, (locale, key)
        assert comment.startswith('Machine translation;'), (locale, key)
        assert sorted(re.findall(r'\{\d+\}', text)) == sorted(re.findall(r'\{\d+\}', source[key][0])), (locale, key)
print(f'{len(used)} service messages in 4 locales; no missing, stale, or unused entries.')
