# DCO Sign-Off Guide

This project requires all commits to carry a
[Developer Certificate of Origin](https://developercertificate.org/) (DCO) sign-off.
The DCO is a lightweight way for contributors to certify that they have the right to
submit their contribution under the project's open-source license.

## What is the sign-off?

A sign-off is a single line appended to your commit message:

```
Signed-off-by: Your Name <your@email.com>
```

By adding this line, you are agreeing to the DCO for that commit. The full DCO text is
available at [developercertificate.org](https://developercertificate.org/).

## How to sign off on commits

### When creating a new commit

Add the `--signoff` (or `-s`) flag:

```bash
git commit -s -m "feat: add new feature"
```

This automatically appends the `Signed-off-by` line using the name and email from your
Git configuration (`user.name` and `user.email`).

### Verify your Git identity

Make sure your Git config has the correct name and email:

```bash
git config user.name "Your Name"
git config user.email "your@email.com"
```

These should match the identity you want associated with your contributions.

## Fixing commits that are missing the sign-off

If the DCO check fails on your pull request, you need to add the sign-off to the
offending commits. The approach depends on how many commits need fixing.

### Fix the most recent commit

If only your last commit is missing the sign-off:

```bash
git commit --amend --signoff --no-edit
git push --force-with-lease
```

### Fix multiple commits on your branch

If several commits on your branch are missing the sign-off, use an interactive rebase.
First, find how many commits are on your branch:

```bash
git log --oneline main..HEAD
```

Then rebase that many commits (replace `N` with the count):

```bash
git rebase --signoff HEAD~N
git push --force-with-lease
```

The `--signoff` flag on `git rebase` adds the sign-off to every replayed commit
automatically.

### Fix all commits on a feature branch

To sign off every commit since your branch diverged from `main`:

```bash
git rebase --signoff main
git push --force-with-lease
```

### After force-pushing

The DCO check will re-run automatically when your branch is updated. Verify the check
passes before requesting review.

## Common issues

### "The email in the sign-off does not match the commit author"

The name and email in the `Signed-off-by` line must come from a real identity. If your
Git config email doesn't match, update it:

```bash
git config user.email "correct@email.com"
git commit --amend --signoff --no-edit
git push --force-with-lease
```

### "I used a no-reply GitHub email"

GitHub's `noreply` email addresses (e.g., `12345+username@users.noreply.github.com`)
are accepted. Set it in your Git config if you prefer not to expose your personal email:

```bash
git config user.email "12345+username@users.noreply.github.com"
```

### "I committed from the GitHub web UI"

Commits made through the GitHub web editor do not include a sign-off by default. You
will need to check out the branch locally and amend the commit:

```bash
gh pr checkout <PR-NUMBER>
git commit --amend --signoff --no-edit
git push --force-with-lease
```

## Further reading

- [Developer Certificate of Origin](https://developercertificate.org/) -- full DCO text
- [CONTRIBUTING.md](../CONTRIBUTING.md) -- project contribution guidelines
