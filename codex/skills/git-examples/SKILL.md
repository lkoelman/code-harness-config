---
name: remote-git-examples
description: Use when asked to inspect code on github (https://github.com/...) or other remote git url
---

When asked to inspect code accessible through a github URL or other hosted git service, always use `git clone` rather than web fetch tools.
Clone or download the code to a temporary folder (`mktemp -d`).

Examples:

```sh
# shallow clone (single commit), to look around
git clone --depth 1 <repo-url> <temp-dir>

# single file: use githubusercontent.com
curl -L -o <temp-dir>/README.md https://raw.githubusercontent.com/<user>/<repo>/refs/heads/<branch>/README.md
```
