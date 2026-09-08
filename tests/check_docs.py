"""Standard-library documentation checks; optional HTTP check of external links."""
import argparse
import concurrent.futures
import json
from pathlib import Path
import re
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--external', action='store_true')
args = parser.parse_args()
errors, external = [], set()
files = [ROOT / 'README.md', *sorted((ROOT / 'docs').glob('*.md')), ROOT / 'NOTICE.md', *sorted((ROOT / 'review').glob('*.md'))]
for file in files:
    if not file.exists():
        errors.append(f'Missing document: {file.relative_to(ROOT)}')
        continue
    text = file.read_text()
    if len(re.findall(r'^```', text, re.M)) % 2:
        errors.append(f'Unclosed code fence: {file.relative_to(ROOT)}')
    for dest in re.findall(r'!?\[[^\]]*\]\(([^)]+)\)', text):
        dest = dest.split(' "', 1)[0].strip('<>')
        if dest.startswith(('https://', 'http://')):
            external.add(dest)
            continue
        path = urllib.parse.unquote(dest.split('#', 1)[0])
        if path:
            current = file.parent
            for component in Path(path).parts:
                if component == '..': current = current.parent
                elif component == '.': continue
                elif not current.is_dir() or component not in {p.name for p in current.iterdir()}:
                    errors.append(f'{file.relative_to(ROOT)}: missing/case-mismatched link {dest}')
                    break
                else: current /= component
    if 'your-org/azure-migrate-workshop' in text:
        errors.append(f'{file.relative_to(ROOT)}: nonfunctional clone URL')
print(f'Checked {len(files)} documents, case-sensitive local links and code fences.')
if args.external:
    def check(url):
        try:
            request = urllib.request.Request(url, headers={'User-Agent': 'CES-Workshop-Documentation-Review/1.0'})
            with urllib.request.urlopen(request, timeout=30) as response:
                return {'url': url, 'status': response.status, 'final_url': response.url}
        except Exception as exc:
            return {'url': url, 'error': str(exc)}
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        results = list(pool.map(check, sorted(external)))
    (ROOT / 'review/external-links.json').write_text(json.dumps(results, indent=2) + '\n')
    for result in results:
        if 'error' in result: errors.append(f"External check needs attention: {result['url']}: {result['error']}")
    print(f'Checked {len(results)} external links; details: review/external-links.json')
for error in errors: print(error)
raise SystemExit(bool(errors))
