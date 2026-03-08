# GCS Access Policy — MANDATORY

This environment enforces strict Google Cloud Storage access boundaries via two environment variables. **You must check and respect these before any GCS operation. No exceptions.**

## Rules

### `GCS_READ_PATHS`
Contains a space-separated list of `gs://` paths you are permitted to **read** from.

- **Only read from paths that start with one of these prefixes.**
- If `GCS_READ_PATHS` is empty or unset, you have **no read access** to any GCS path.

### `GCS_WRITE_PATHS`
Contains a space-separated list of `gs://` paths you are permitted to **write** to.

- **Only write to paths that start with one of these prefixes.**
- If `GCS_WRITE_PATHS` is empty or unset, you have **no write access** to any GCS path. Do not create, upload, modify, or delete any GCS objects.

## Before Any GCS Operation

Always check the relevant variable first:

```python
import os

read_paths = os.environ.get("GCS_READ_PATHS", "").split()
write_paths = os.environ.get("GCS_WRITE_PATHS", "").split()

def is_readable(path):
    return any(path.startswith(p) for p in read_paths)

def is_writable(path):
    return any(path.startswith(p) for p in write_paths)
```

## What You Must NOT Do

- **Do not read from any `gs://` path not listed in `GCS_READ_PATHS`.**
- **Do not write, upload, modify, copy, or delete any `gs://` path not listed in `GCS_WRITE_PATHS`.**
- **Do not attempt to list or probe buckets outside of the permitted prefixes.**
- **Do not work around these restrictions** by using gsutil, the GCP console, or any other method.
- If a task requires accessing a path outside these variables, **stop and tell the user** rather than proceeding.

## When Variables Are Not Set

If `GCS_READ_PATHS` and `GCS_WRITE_PATHS` are both absent, treat this as **zero GCS access**. Do not attempt any GCS operations.
