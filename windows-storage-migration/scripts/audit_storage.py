"""Read-only Windows directory audit; never follow reparse points."""
import argparse
import json
import os
import shutil
from pathlib import Path


def scan(root):
    total = files = errors = 0
    links = []
    stack = [root]
    while stack:
        directory = stack.pop()
        try:
            with os.scandir(directory) as entries:
                for entry in entries:
                    try:
                        info = entry.stat(follow_symlinks=False)
                        if entry.is_symlink() or getattr(info, 'st_file_attributes', 0) & 0x400:
                            links.append(entry.path)
                        elif entry.is_dir(follow_symlinks=False):
                            stack.append(entry.path)
                        else:
                            total += info.st_size
                            files += 1
                    except OSError:
                        errors += 1
        except OSError:
            errors += 1
    return {'logical_bytes': total, 'files': files, 'unreadable': errors,
            'skipped_reparse_points': len(links), 'link_examples': links[:5]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', action='append', required=True)
    parser.add_argument('--exclude', action='append', default=[], help='Exact immediate child name to skip')
    parser.add_argument('--output', help='Optional JSON report; otherwise stdout only')
    parser.add_argument('--scan-resolved-root', action='store_true', help='Explicitly scan a redirected root; attribute it to its resolved physical volume')
    args = parser.parse_args()
    report = []
    excluded = {name.casefold() for name in args.exclude}
    for value in args.root:
        root = Path(value).absolute()
        if not root.is_dir():
            report.append({'root': str(root), 'error': 'not a readable directory'})
            continue
        is_link = root.is_symlink() or (root.is_junction() if hasattr(root, 'is_junction') else False)
        resolved = root.resolve()
        redirected = os.path.normcase(str(root)) != os.path.normcase(str(resolved))
        if (is_link or redirected) and not args.scan_resolved_root:
            report.append({'root': str(root), 'resolved': str(resolved),
                           'root_is_link': is_link, 'root_or_ancestor_redirected': True,
                           'physical_volume_root': resolved.anchor, 'scan_skipped': True})
            continue
        scan_root = resolved if redirected or is_link else root
        children = []
        for child in scan_root.iterdir():
            if child.name.casefold() in excluded:
                continue
            try:
                stat = child.lstat()
                if child.is_symlink() or getattr(stat, 'st_file_attributes', 0) & 0x400:
                    children.append({'path': str(child), 'is_link': True, 'target': str(child.resolve()), 'scan_skipped': True})
                elif child.is_dir():
                    path = str(child)
                    if os.name == 'nt' and not path.startswith('\\\\?\\'):
                        path = '\\\\?\\' + path
                    children.append({'path': str(child), **scan(path)})
                else:
                    children.append({'path': str(child), 'logical_bytes': stat.st_size, 'files': 1, 'unreadable': 0})
            except OSError as error:
                children.append({'path': str(child), 'error': type(error).__name__})
        children.sort(key=lambda item: item.get('logical_bytes', 0), reverse=True)
        report.append({'root': str(root), 'resolved': str(resolved), 'scan_root': str(scan_root),
                       'root_or_ancestor_redirected': redirected or is_link,
                       'physical_volume_root': resolved.anchor,
                       'free_volume_bytes': shutil.disk_usage(resolved).free,
                       'size_semantics': 'logical file lengths; not allocated bytes or guaranteed reclaimable space',
                       'children': children})
    serialized = json.dumps(report, ensure_ascii=False, indent=2)
    if args.output:
        Path(args.output).write_text(serialized, encoding='utf-8')
    else:
        print(serialized)


if __name__ == '__main__':
    main()
