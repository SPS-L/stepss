# Homebrew tap for STEPSS on macOS: design

Date: 2026-10-13. Status: approved in conversation, awaiting review of this written form.

## Goal

A macOS user installs STEPSS GUI with one command and receives later releases through `brew upgrade`. This is the macOS counterpart of `stepss-apt` on Debian and Ubuntu and `stepss-scoop` on Windows, and it follows the same shape so that the three channels are maintained the same way.

Success means four things hold:

1. `brew install --cask sps-l/stepss/stepss` on a clean Apple Silicon Mac leaves a working `STEPSS.app` whose engines find their runtime libraries.
2. A new STEPSS release updates the cask with no manual step.
3. The installation page on stepss.sps-lab.org documents the route, and no longer says the dmg needs nothing else installed.
4. The umbrella repository pins the tap and its CLAUDE.md describes the new contracts.

## Facts the design rests on

All of these were checked against `STEPSS-3.83.dmg` and the `STEPSS.app` it installs, not assumed.

| Fact | Value |
|---|---|
| Release asset | `STEPSS-<version>.dmg`, tag `v<version>`, on `SPS-L/stepss-java-ui` |
| SHA-256 of 3.83 | `508f6cc6e8b07c6777238fecc7455c8a3d914cf4196000936d9692fb2f96bcda`, equal to the release API `digest` |
| Bundle name | `STEPSS.app` |
| Bundle identifier | `my.stepss.StepssUI` |
| `LSMinimumSystemVersion` | `10.11` |
| Architecture | Apple Silicon only |
| RAMSES links | `libopenblas.0` from `/opt/homebrew/opt/openblas/`; `libgfortran.5`, `libgomp.1`, `libquadmath.0` from `/opt/homebrew/opt/gcc/` |
| CODEGEN, DYNGRAPH link | `libgfortran.5`, `libquadmath.0` from `/opt/homebrew/opt/gcc/` |
| Helios links | nothing from Homebrew |
| Where the engines live | `.tar.gz` resources inside `Contents/app/stepss.jar`, extracted at run time, so they are not visible inside the `.app` |
| Notarization | the dmg carries the stapled ticket and no signature; the app carries the Developer ID signature and no ticket |

Two consequences follow. The cask depends on both `openblas` and `gcc`, unconditionally. And a cask copies the app out of the dmg, so the installed app has no stapled ticket and Gatekeeper verifies it online on first launch; the install line takes no `--no-quarantine`.

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| Repository name | `SPS-L/homebrew-stepss` | Homebrew resolves `sps-l/stepss` to it, so users need no URL |
| Place in the umbrella | Submodule, tracking `main` | Same treatment as every other component |
| Update mechanism | Workflow in the tap, woken by `repository_dispatch` | Mirrors `stepss-scoop`; keeps tap logic out of the release run |
| Local test | Full install on the maintainer's Mac, replacing the hand-installed app | Proves the dependency claim on a real machine |
| `zap` stanza | Omitted unless the install test shows files STEPSS alone owns | Java preferences share one plist with every other Java application |
| `depends_on macos` | Omitted | The bundle declares 10.11, older than anything Homebrew supports |

Two alternatives were rejected. Having java-ui push the cask itself puts a write to a second repository inside the release run, where a failure reddens a release that already shipped. Updating by hand with `brew bump-cask-pr` is simple and guarantees drift.

## Component 1: the tap

Repository `SPS-L/homebrew-stepss`, public, default branch `main`.

```
Casks/stepss.rb
tools/check-engine-libs.sh
.github/workflows/update-cask.yml
README.md
.gitignore
```

`.gitignore` carries `/.claude/` and `.mcp.json` before the first commit, as the umbrella CLAUDE.md requires of every component.

### The cask

```ruby
cask "stepss" do
  version "3.83"
  sha256 "508f6cc6e8b07c6777238fecc7455c8a3d914cf4196000936d9692fb2f96bcda"

  url "https://github.com/SPS-L/stepss-java-ui/releases/download/v#{version}/STEPSS-#{version}.dmg",
      verified: "github.com/SPS-L/stepss-java-ui/"
  name "STEPSS"
  desc "Static and transient electric power systems simulation platform"
  homepage "https://stepss.sps-lab.org/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  # Runtime requirements of the bundled engines: RAMSES loads OpenBLAS, and
  # RAMSES, CODEGEN and DYNGRAPH load libgfortran from Homebrew's gcc.
  depends_on formula: ["openblas", "gcc"]

  app "STEPSS.app"

  caveats <<~EOS
    STEPSS is not free software taken as a whole. The licence is shown on
    first launch; see https://stepss.sps-lab.org/getting-started/license/
  EOS
end
```

`url` interpolates `#{version}`, so an update touches the `version` and `sha256` lines and nothing else. `brew style` and `brew audit` are the authority on stanza order and wording; where they disagree with the text above, they win and the cask is changed to satisfy them.

### The update workflow

`.github/workflows/update-cask.yml` has two jobs.

**`update`**, on `ubuntu-latest` with `contents: write`:

1. Checks out the tap with `actions/checkout@v7`.
2. Lists the last five non-draft releases of `SPS-L/stepss-java-ui` and takes the newest one carrying an asset whose name ends in `.dmg`. It fails when none does.
3. Takes the SHA-256 from the release API `digest` field, and downloads the asset to compute it only when the field is empty.
4. Rewrites the `version` and `sha256` lines with `sed`, then checks both new values are present.
5. Commits as `github-actions[bot]` and pushes, only when the file changed.

**`verify`**, on `macos-latest`, after `update`: checks out `main`, taps the checkout, runs `brew style`, `brew audit --cask --online`, `brew install --cask`, asserts `/Applications/STEPSS.app` exists, runs `tools/check-engine-libs.sh` against it, and uninstalls. If Homebrew on the runner refuses to load an untrusted tap, the job runs `brew trust --tap sps-l/stepss` before the audit.

Triggers:

| Trigger | Purpose |
|---|---|
| `repository_dispatch`, type `stepss-release` | java-ui announcing a published release |
| `schedule`, weekly, Monday 04:41 UTC | insurance against a dropped or 401ing dispatch, which is silent on this side |
| `workflow_dispatch` | by hand |
| `push` to `main` touching `Casks/**` or the workflow | runs `verify` on a hand edit; the rewrite step is skipped on this event so the workflow cannot loop on its own commit |

Rules carried over from the scoop workflow:

- No `${{ }}` expression is interpolated into a `run:` script. Values arrive through `env:` and are read as quoted shell variables, so a hostile tag name cannot run commands in a job holding a write token.
- The built-in token is spelled `${{ github.token }}`. The tap uses no configured secret.
- `concurrency` group `homebrew-cask` with `cancel-in-progress: false`, so two wake-ups queue.
- The run is idempotent: it commits nothing when the cask already names the newest release.

### The README

Modelled on `stepss-scoop/README.md`: the install, upgrade and uninstall commands; that the route is Apple Silicon only, serves the current release only and is not an official Homebrew cask; the licensing summary, pointing at `https://stepss.sps-lab.org/getting-started/license/` as the single owner of those facts; that the dmg is downloaded from the release page and never mirrored; how the cask stays current; and that the asset name `STEPSS-<version>.dmg` is a contract with stepss-java-ui. It also carries the maintenance table and the troubleshooting list from the original setup guide, corrected for the notarization facts above.

## Component 2: the dispatch in stepss-java-ui

In `.github/workflows/release.yml`, the `promote` job gains a third dispatch step after the scoop one:

```yaml
      - name: Tell the Homebrew tap there is a new .dmg
        env:
          GH_TOKEN: ${{ secrets.STEPSS_TOKEN }}
          VERSION: ${{ needs.release.outputs.version }}
        run: |
          set -euo pipefail
          gh api repos/SPS-L/homebrew-stepss/dispatches \
            -f event_type=stepss-release \
            -f "client_payload[tag]=$VERSION"
          echo "homebrew-stepss asked to update its cask for $VERSION."
```

The surrounding comments that say "both dispatches" and name two weekly schedules are updated to three. The step sits before "Discard the draft if publishing failed", whose `steps.publish.outcome` gate already keeps a failed dispatch from deleting a published release.

This step cannot be test-run: a manual dispatch of `release.yml` always cuts a release. It is first exercised by the next real release. The tap's receiving side is tested separately by sending the same event by hand.

## Component 3: stepss-docs

`src/content/docs/getting-started/installation.mdx`:

- The introduction to "Installing STEPSS GUI" says there is a package manager on each of two platforms. It becomes three: APT on Debian and Ubuntu, Scoop on Windows, Homebrew on macOS.
- The Installer tab says the installers need nothing else. That is true of the `.msi` and the `.deb` and false of the `.dmg`. The macOS line gains the requirement `brew install gcc openblas` and a pointer to the Homebrew tab as the better route, in the same form as the Windows and Linux lines.
- A new **macOS (Homebrew)** tab, placed after the Windows (Scoop) tab, with: the install command; upgrade and uninstall; that the cask brings `gcc` and `openblas` with it; the trust note (`brew trust --tap sps-l/stepss`); that the first launch needs a network connection; and a caution block matching the other two tabs (Apple Silicon only, current release only, not Apache 2.0 taken as a whole, not an official Homebrew cask, do not mirror).

`src/content/docs/resources/releases.md`: a Homebrew row in the channel table beside APT and Scoop.

`src/content/docs/resources/repositories.md`: an entry for `homebrew-stepss`.

The site is built before committing. The user guide PDF, whose chapters are generated from these pages, is not regenerated as part of this work.

## Component 4: the umbrella

- `git submodule add -b main ../homebrew-stepss.git homebrew-stepss`, with the relative URL the other components use.
- Pointer bumps for `stepss-java-ui` and `stepss-docs`. The java-ui pointer is currently seven commits behind its `main`, so the bump carries v3.82 and v3.83 with it.
- CLAUDE.md:
  - the `STEPSS_TOKEN` paragraph names the tap among java-ui's dispatch targets;
  - the release paragraph says `promote` fires three package-manager dispatches;
  - the asset-name contracts gain `STEPSS-<ver>.dmg`, which the cask builds its URL from;
  - the licensing section counts six summaries, the sixth being the cask's `caveats` and the tap README;
  - the two shell checks that iterate over `stepss-*/` are extended to cover `homebrew-stepss`, since its name does not match the glob.

## Testing

| Stage | Check | Pass condition |
|---|---|---|
| Local | `brew style sps-l/stepss` | no offences |
| Local | `brew audit --cask --online --strict sps-l/stepss/stepss` | no problems |
| Local | move the hand-installed app to the Trash, then `brew install --cask sps-l/stepss/stepss` | `/Applications/STEPSS.app` present at 3.83, `gcc` and `openblas` installed |
| Local and CI | `tools/check-engine-libs.sh`, which extracts the macOS engines from the installed `stepss.jar` and reads `otool -L` on each | every non-system library an engine links exists on disk; fails before `gcc` is installed and passes after |
| Published | `brew untap`, then install from GitHub | same result from the public tap |
| CI | `workflow_dispatch` of `update-cask.yml` | `update` commits nothing, `verify` green, no annotations |
| CI | hand-sent `stepss-release` dispatch | a run starts, logs "Woken by", commits nothing |
| Docs | site build | succeeds, new tab renders |

## Order of work

1. Create the tap locally, write the cask, pass style and audit.
2. Run the local install test.
3. Create `SPS-L/homebrew-stepss`, push, add the workflow, run it, send the dispatch.
4. Commit the dispatch step in stepss-java-ui and push.
5. Commit the docs changes in stepss-docs and push.
6. Add the submodule, bump the pointers, update CLAUDE.md, commit and push the umbrella.

Each component is pushed before the umbrella pins it.

## Not covered

- **`STEPSS_TOKEN` scope.** If the token is fine-grained with a repository list, `homebrew-stepss` has to be added to that list by its owner. Until then the new dispatch step fails with a 401, which reddens `promote` after the release is already published; the weekly schedule still updates the cask within a week.
- **Intel Macs.** There is no x86-64 macOS build of the engines.
- **Older versions.** The tap serves the current release only.
- **The user guide PDF.**
