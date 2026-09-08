"""Build wiki pages from one committed revision. Never authenticates or pushes."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import posixpath
import re
import subprocess
import sys
from urllib.parse import quote, unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = '.workshop-wiki.json'
PAGE = re.compile(r'[A-Za-z_][A-Za-z0-9_-]*\Z')
LINK = re.compile(r'(!?\[[^\]\n]*\]\()([^\n)]+)(\))')


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args], text=True)


def digest(content):
    return hashlib.sha256(content.encode('utf-8')).hexdigest()


def rewrite_links(text, source, mapping, repository, revision):
    wiki_base = f'https://github.com/{repository}/wiki/'

    def replace(match):
        target = match[2]
        # Existing sources use simple inline destinations, optionally in <>.
        destination = target.strip('<>')
        parsed = urlsplit(destination)
        if parsed.scheme or parsed.netloc or not parsed.path:
            return match[0]
        relative = posixpath.normpath(str(PurePosixPath(source).parent / unquote(parsed.path)))
        if relative.startswith('../') or relative.startswith('/'):
            raise ValueError(f'Link escapes repository: {source}: {target}')
        page = mapping.get(relative)
        if relative == 'README.md':
            page = 'Architecture' if parsed.fragment == 'environment' else 'Home'
        if page:
            result = wiki_base + quote(page)
        else:
            result = f'https://github.com/{repository}/blob/{revision}/' + quote(relative, safe='/')
        if parsed.query:
            result += '?' + parsed.query
        # Architecture uses its own top-level title instead of README's heading.
        if parsed.fragment and not (relative == 'README.md' and parsed.fragment == 'environment'):
            result += '#' + parsed.fragment
        return match[1] + result + match[3]

    result, fence = [], None
    for line in text.splitlines(keepends=True):
        marker = re.match(r'^\s*(`{3,}|~{3,})', line)
        if marker:
            character = marker[1][0]
            if fence is None:
                fence = (character, len(marker[1]))
            elif character == fence[0] and len(marker[1]) >= fence[1]:
                fence = None
            result.append(line)
        else:
            result.append(line if fence else LINK.sub(replace, line))
    return ''.join(result)


def render_pages(specification, read_source, repository, revision):
    mapping, names = {}, set()
    for row in specification:
        page, source = row['page'], row['source']
        if not PAGE.fullmatch(page) or page.casefold() in names:
            raise ValueError('Invalid or duplicate wiki page name.')
        path = PurePosixPath(source)
        if path.is_absolute() or '..' in path.parts or path.suffix != '.md':
            raise ValueError('Wiki sources must be repository-relative Markdown files.')
        names.add(page.casefold())
        mapping[source] = page
    pages = {}
    for row in specification:
        page, source = row['page'], row['source']
        content = read_source(source)
        if row.get('section'):
            heading = '## ' + row['section'] + '\n'
            if heading not in content:
                raise ValueError(f'Missing source section: {source}: {row["section"]}')
            section = content.split(heading, 1)[1]
            section = re.split(r'^## ', section, maxsplit=1, flags=re.MULTILINE)[0]
            content = f'# {page.replace("-", " ")}\n\n' + section.lstrip()
        content = rewrite_links(content, source, mapping, repository, revision)
        content = f'<!-- Published from {repository}@{revision}; edit the versioned source. -->\n\n' + content.rstrip() + '\n'
        if not page.startswith('_'):
            content += (f'\n---\n\n[Workshop home](https://github.com/{repository}/wiki) · '
                        f'[Versioned source](https://github.com/{repository}/blob/{revision}/{quote(source, safe="/")}) · '
                        f'Source revision `{revision[:7]}`\n')
        pages[page + '.md'] = content
    wiki_prefix = f'https://github.com/{repository}/wiki/'
    for name, content in pages.items():
        for match in LINK.finditer(content):
            if match[2].startswith(wiki_prefix):
                target = unquote(urlsplit(match[2]).path.rsplit('/', 1)[-1]) + '.md'
                if target not in pages:
                    raise ValueError(f'{name} links to an unpublished wiki page: {target}')
    return pages


def publish_local(directory, pages, repository, revision, check=False, adopt_home=False):
    directory = Path(directory).resolve()
    if directory == ROOT or ROOT in directory.parents:
        raise ValueError('Use a separate wiki checkout or preview directory outside the source repository.')
    manifest_path = directory / MANIFEST
    if manifest_path.is_symlink():
        raise ValueError('Wiki ownership manifest must not be a symlink.')
    previous = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    if previous and (previous.get('schema') != 1 or previous.get('repository') != repository):
        raise ValueError('Wiki ownership manifest does not match the repository/schema.')
    owned = previous.get('pages', {})
    for name in owned:
        if not name.endswith('.md') or not PAGE.fullmatch(name[:-3]):
            raise ValueError('Invalid owned filename in wiki manifest.')
    existing = {file.name.casefold(): file.name for file in directory.glob('*.md')}
    writes, removals = {}, []
    for name, content in pages.items():
        path = directory / name
        if path.is_symlink() or (name.casefold() in existing and existing[name.casefold()] != name):
            raise ValueError(f'Refusing symlink or case-colliding wiki page: {name}')
        if path.exists():
            current = path.read_text(encoding='utf-8')
            if current == content:
                continue
            can_adopt = not previous and adopt_home and name == 'Home.md'
            if not can_adopt and (name not in owned or digest(current) != owned[name]):
                raise ValueError(f'Preserve/reconcile the existing wiki edit before publishing: {name}')
        writes[name] = content
    for name, old_hash in owned.items():
        if name not in pages:
            path = directory / name
            if path.exists() or path.is_symlink():
                if path.is_symlink() or digest(path.read_text(encoding='utf-8')) != old_hash:
                    raise ValueError(f'Refusing to remove an edited obsolete wiki page: {name}')
                removals.append(path)
    manifest = {'schema': 1, 'repository': repository, 'source_commit': revision,
                'pages': {name: digest(text) for name, text in sorted(pages.items())}}
    encoded = json.dumps(manifest, indent=2) + '\n'
    stale = bool(writes or removals or not manifest_path.exists() or manifest_path.read_text() != encoded)
    if check:
        if stale:
            raise ValueError('Wiki publication is stale; regenerate from the selected source revision.')
        return
    # All conflicts are checked before any page is modified.
    directory.mkdir(parents=True, exist_ok=True)
    for name, content in writes.items():
        (directory / name).write_text(content, encoding='utf-8')
    for path in removals:
        path.unlink()
    manifest_path.write_text(encoded, encoding='utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--wiki-dir', required=True)
    parser.add_argument('--revision', default='HEAD')
    parser.add_argument('--repository', default='j33pguy/azure-migrate-workshop')
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--adopt-home', action='store_true')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repository):
        raise ValueError('Supply a GitHub owner/repository name.')
    revision = git('rev-parse', '--verify', '--end-of-options', args.revision + '^{commit}').strip()
    read_source = lambda path: git('show', f'{revision}:{path}')
    specification = json.loads(read_source('wiki/pages.json'))
    pages = render_pages(specification, read_source, args.repository, revision)
    publish_local(args.wiki_dir, pages, args.repository, revision, args.check, args.adopt_home)
    print(f'{"Verified" if args.check else "Prepared"} {len(pages)} wiki files from {revision[:7]}. No remote changes were made.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f'Wiki publication stopped: {error}', file=sys.stderr)
        raise SystemExit(1)
