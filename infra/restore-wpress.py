# Unpacks an All-in-One WP Migration .wpress export (no paid extension needed)
# usage: python3 -I restore-wpress.py backup.wpress outdir
#
# A .wpress file is a list of: 4377 byte header, then the file's bytes.
# Header = name (255) + size (14) + mtime (12) + path (4096), all null padded.
# The archive ends with an all-zero header.
# Result: outdir/database.sql, outdir/package.json, outdir/uploads/..., outdir/plugins/... etc

import os
import sys

archive, outdir = sys.argv[1], os.path.realpath(sys.argv[2])

with open(archive, 'rb') as f:
    while True:
        header = f.read(4377)
        if len(header) < 4377 or header == b'\0' * 4377:
            break
        name = header[:255].rstrip(b'\0').decode()
        size = int(header[255:269].rstrip(b'\0'))
        path = header[281:].rstrip(b'\0').decode()

        target = os.path.realpath(os.path.join(outdir, path, name))
        if not target.startswith(outdir + os.sep):
            sys.exit(f'path outside outdir: {path}/{name}')

        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, 'wb') as out:
            remaining = size
            while remaining:
                chunk = f.read(min(remaining, 1024 * 1024))
                out.write(chunk)
                remaining -= len(chunk)

print('done')
