# tools/

Repo-only maintenance utilities. **Nothing here is installed** and nothing here
runs as part of `install.sh` or `sudo-elevation uninstall` — the installed tree
is `bin/`, `libexec/sudo-elevation/`, `share/sudo-elevation/` only.

Keep it that way: these tools exist to be run by hand, from a checkout, when
something needs clearing that the normal lifecycle deliberately will not touch.

## `purge-legacy-skill.sh`

Removes `SKILL.md` files left behind by installs that predate the
`Managed by sudo-elevation` ownership marker.

Those installs exist because the skill deletion guard used to decide ownership
by the substring `sudo-elevation request` — which a third-party skill could
contain by accident, and deleting a third party's file is the direction that
hurts. The guard now requires the marker, so a pre-marker install keeps its
`SKILL.md` through a purge. The uninstall says so by name and points here.

Run it report-only first; it deletes nothing without `--yes`:

```sh
tools/purge-legacy-skill.sh                # report, current account
tools/purge-legacy-skill.sh --all-users    # report for every account in the manifest (root)
tools/purge-legacy-skill.sh --yes          # actually remove what was reported
```

A file counts as legacy only when it has **no** marker, **does** have the old
signature, **and** has `name: sudo-elevation` in its frontmatter. Both
conditions are needed: the signature alone is too weak to delete on, the name
alone is too weak to trust without it.

Not covered on purpose: a custom `--skill-dir` from an install whose manifest is
already gone, and any layout older than the manifest — neither is knowable from
here. Pass such a path with `--dir /path/to/dir`.
