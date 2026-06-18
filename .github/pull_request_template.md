## Summary

- 

## Verification

- [ ] `swift build`
- [ ] `swift run agentic-secrets-contract-tests`
- [ ] `./script/ui_smoke.sh`
- [ ] `./scripts/ci.sh`
- [ ] `./scripts/tahoe_compatibility_check.sh`
- [ ] `./scripts/check_secret_authority.sh`
- [ ] `git diff --check`

## Security Notes

- [ ] This change does not add real secrets, tokens, private keys, credential files, or secret-derived logs.
- [ ] Any secret-handling behavior change is documented in the PR description.
