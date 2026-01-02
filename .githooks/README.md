# Git Hooks for this repository

This repository includes a pre-commit hook that enforces static analysis and automatic fixes.

Files:
- `pre-commit` - POSIX shell script that runs `dart fix --apply` then `flutter analyze`. Exits non-zero on failure.
- `pre-commit.ps1` - PowerShell variant for Windows environments.

To enable these hooks for this repository (set your repo hooks path):

```bash
git config core.hooksPath .githooks
```

After running that command, the pre-commit hook will run automatically on every commit. If `flutter` or `dart` are not available in your PATH, the hook will fail; ensure you have Flutter and Dart installed and accessible.
