# ubchrome Test Plan

## Scope
Regression suite for `dockerhubatbasrco/ubchrome` — verifies every component on every release before publishing.

## Test Cases

| ID | Area | Test | Pass Criteria |
|----|------|------|---------------|
| T01 | Container | 3 instances start successfully | All 3 containers reach `running` state within 30s |
| T02 | Chrome | Binary present and correct version | `google-chrome --version` exits 0, version matches VERSION file |
| T03 | Chrome | Not Snap-confined | Binary path is `/usr/bin/google-chrome-stable` or `/opt/google/chrome/chrome`, NOT `/snap/` |
| T04 | Node.js | Runtime available | `node --version` exits 0, version >= 22 |
| T05 | Claude Code | CLI installed | `claude --version` exits 0, version string returned |
| T06 | Codex CLI | CLI installed | `codex --version` exits 0, version string returned |
| T07 | Gemini CLI | CLI installed | `gemini --version` exits 0, version string returned |
| T08 | Desktop | noVNC port reachable | HTTP 200 on `localhost:{port}` within 15s |
| T09 | Memory | Within limits | Container RSS < 2GiB at idle |
| T10 | Isolation | Instances independent | Each container has unique port, unique name |
| T11 | Report | Generated successfully | `reports/{tag}/test_report.html` created, size > 50KB |
| T12 | Cleanup | All containers removed after test | `docker ps` shows no ubchrome containers |

## Release Gate
All 12 tests must PASS before `docker push` of a new version tag.

## Execution
```bash
./regression.sh              # run full suite against current VERSION
./regression.sh --bump=patch # bump patch version, build, test, push
./regression.sh --bump=minor # bump minor version, build, test, push
```
