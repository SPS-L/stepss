# macOS code signing and notarization for STEPSS releases

Date: 2026-09-22
Status: approved design, not yet implemented
Components touched: `stepss-ci` (new), `stepss-helios`, `stepss-ramses`, `stepss-Codegen`, `stepss-dyngraph`, `stepss-java-ui`, `stepss-python-ui`, umbrella `CLAUDE.md`

## 1. Problem

Every macOS artefact the platform publishes is unsigned. The release workflows say so in the text they generate for users, and they instruct those users to defeat Gatekeeper by hand: `stepss-Codegen/.github/workflows/release.yml:290`, `stepss-dyngraph/.github/workflows/release.yml:301` and `stepss-ramses/.github/workflows/release.yml:392` each emit a paragraph ending in `xattr -dr com.apple.quarantine`, and `stepss-python-ui/tools/update_helios_libs.sh:12` repeats the advice in a comment. The desktop `.dmg` that `stepss-java-ui` publishes is unsigned for the same reason, so it cannot be opened by double-clicking without the right-click gesture that suppresses the warning.

Cyprus University of Technology now holds an Apple Developer Program membership as an Organization, Team ID `SWZD63F3C7`, and has issued a Developer ID Application certificate and an App Store Connect API key for notarization. This design embeds signing and notarization into the release workflows that build the macOS binaries, so that the signature is applied where the binary is produced and travels with it into every downstream package.

## 2. Credentials supplied, and what was verified

The certificate is `Developer ID Application: Cyprus University of Technology (SWZD63F3C7)`, RSA-2048, issued by Apple's Developer ID Certification Authority G2, valid from 2026-09-11 to 2031-09-12, serial `65278977BECD2BE936DD93EB2D933B3B`. Developer ID Application is the one certificate type Gatekeeper accepts for software distributed outside the Mac App Store, so it matches the distribution model STEPSS already uses.

The supplied private key is the matching half. The SHA-256 of the DER-encoded public key is `d8a6fe803d8daa01ae0c4820a8b44628eb1a6900e6ca8790c5070c27c0ee749d` for the private key, for the certificate signing request, and for the certificate alike. Two certificate files were supplied and are byte-identical, SHA-256 `f57bf00da13581d10f61e37362406fe9758e1db4b32f95d0ea551080678b0d00`; one is redundant.

The notarization credential is an App Store Connect API key named "STEPSs Notarization", Key ID `8A4L5VF84Z`. Its Issuer ID was not supplied and is not derivable from the certificate: a search of the DER for a UUID-shaped string returns nothing, and the only identifiers the certificate carries are the Team ID, three times, and Apple's policy object identifiers. The Issuer ID must be copied from App Store Connect under Users and Access, Integrations, App Store Connect API.

The certificate and the API key are at present stored unencrypted in a cloud-synchronised folder. Both constitute the full signing authority for the university's Apple identity.

## 3. Constraints that shaped the design

**Notarization requires the hardened runtime, and the hardened runtime breaks the engines by default.** Every macOS binary in the platform links dynamically against Homebrew's GCC runtime rather than a static copy: `stepss-ramses/.github/workflows/release.yml:265` installs `gcc` and `openblas` before the build, the job carries an `otool -L` inventory step for exactly this reason, and `stepss-docs/src/content/docs/getting-started/installation.mdx:243` documents `brew install gcc openblas` as the macOS prerequisite. Homebrew dylibs carry ad-hoc signatures. Library validation, which the hardened runtime enables by default, refuses to load a dynamic library signed by a team other than the signing team or Apple, so a Developer ID signature applied without further thought would produce binaries that satisfy Gatekeeper and then fail to start. The entitlement `com.apple.security.cs.disable-library-validation` is therefore mandatory, not optional.

**A notarization ticket cannot be stapled to a tarball.** Stapling works on `.dmg`, `.pkg` and `.app` containers alone. The four command-line components ship bare Mach-O executables inside `.tar.gz` archives, and those archive names are contracts with other repositories: `stepss-python-ui/tools/update_ramses_libs.sh:42`, `stepss-python-ui/tools/update_helios_libs.sh:39`, `stepss-cg-studio/tools/update_codegen.sh` and java-ui's `versions.properties` patterns all fail hard on a missing or renamed asset. The ticket is keyed on each binary's code directory hash and is registered on Apple's servers, so a notarized but unstapled binary is accepted once Gatekeeper can reach the network. Asset names and formats are consequently left untouched, and the residual cost is that an offline first run on a quarantined copy still warns.

**`jpackage` cannot sign the engines.** The engines travel as `.tar.gz` resources inside `stepss.jar` and are extracted at run time, as the comment at `stepss-java-ui/build.xml:493` records. `jpackage` sees a jar, not a Mach-O file, so it signs neither. The engines must therefore carry signatures applied upstream, at the component that builds them, which also means the component releases must be signed before the desktop bundle is.

**Four of the five workflows cannot be tested without cutting a release.** `stepss-Codegen`, `stepss-dyngraph` and `stepss-ramses` run their release workflow on `release` and `workflow_dispatch` alone, and java-ui's manual dispatch always cuts a release. `stepss-helios` is the exception: `ci.yml` runs on every push and pull request, and builds the same kind of macOS artefacts.

**Signing at the component propagates for free.** `stepss-python-ui` installs the macOS `ramses.so` and `libhelios_api.dylib` into its PyPI wheel, and `stepss-cg-studio` does the same with the CODEGEN executables. Signing at the engine repositories fixes both wheels without either repository being modified. Signing only in java-ui would fix neither.

**`stepss-uramses` is out of scope.** Its release attaches no binary. The macOS kit `uramses-modules_m-<ver>.zip` holds `libramses.a` and Fortran module files, a static archive being unsignable, and `ramses.so` and `dynsim` are built on the user's own machine by `make -f build/Makefile.macos` (`stepss-uramses/.github/workflows/sync-ramses-release.yml:236`). A locally built binary is never quarantined and needs no Developer ID signature.

## 4. Architecture

One composite action in a new repository, referenced by five workflows, doing the same nine things in the same order everywhere, with the desktop bundle differing only in that `jpackage` performs the signing step and the ticket is stapled afterwards.

```
stepss-ci/sign-macos          composite action, tagged v1
   |
   +-- stepss-helios      ci.yml         helios, libhelios_api.dylib
   +-- stepss-ramses      release.yml    ramses, ramses.so
   +-- stepss-Codegen     release.yml    CODEGEN
   +-- stepss-dyngraph    release.yml    dyngraph
   +-- stepss-java-ui     release.yml    STEPSS.app inside STEPSS-<ver>.dmg
```

### Decisions taken and their alternatives

A shared repository was chosen over a per-repository copy of the script. The umbrella keeps action versions uniform across components by hand today, and the same discipline applied to sixty lines of signing shell would drift silently; a drifted signing script fails at a user's machine rather than in CI. The cost is a build-time dependency on a second repository being readable, which is addressed by opening the Actions access setting on `stepss-ci` to the organization so that the built-in token resolves it. No new cross-repo token is introduced.

The entitlement was chosen over bundling and re-signing Homebrew's GCC runtime inside each artefact. Bundling would remove the `brew install gcc` prerequisite entirely and is the better end state, but it changes what every macOS artefact contains, requires `install_name_tool` rewriting of load paths in four repositories, and is a separate piece of work from making the current artefacts trustworthy. It is recorded here as the natural successor, not as part of this design.

Signing the command-line binaries was chosen over signing the desktop bundle alone. The engines reach users through three independent channels, the component tarballs, the PyPI wheels and the desktop bundle, and only the component is common to all three.

## 5. The shared action: `SPS-L/stepss-ci/sign-macos`

The repository is added to the umbrella as a submodule with a relative URL, `../stepss-ci.git`, and its `.gitignore` carries `/.claude/` and `.mcp.json` before its first commit, as the umbrella requires of every new component. The action is referenced as `SPS-L/stepss-ci/sign-macos@v1`, pinned to the major, consistent with every other action version in the platform.

### 5.1 Inputs and outputs

| Input | Meaning |
|---|---|
| `paths` | Newline-separated Mach-O files to sign. Empty in notarize-only mode, and empty in `sign` mode when the caller signs through another tool, which makes steps 5 and 6 no-ops and reduces the action to preparing the keychain. |
| `mode` | `sign`, `notarize`, or `sign-and-notarize`. |
| `bundle` | A `.dmg` or `.app` to staple after notarization. Empty for bare executables. |
| `entitlements` | Path to an entitlements plist. Defaults to the one the action ships. |

The action outputs `keychain-path`, the temporary keychain it created, so that `jpackage` can be pointed at the same keychain rather than a second import being performed.

### 5.2 Steps, in order

1. **Refuse to run without credentials.** If `APPLE_SIGNING_P12` is empty the action fails with a named message. It does not skip. A skip publishes unsigned binaries under a green run, which is the failure mode that hides.
2. **Check the certificate expiry.** The certificate is decoded and its `notAfter` read; the action fails past 2031-09-12 and warns within 365 days of it. This mirrors the expiry warning that `stepss-apt` already carries for its GPG key.
3. **Create a temporary keychain** with a random password, import the PKCS#12 bundle, set the key partition list so that `codesign` is not prompted, and add it to the search list. A post step deletes it unconditionally.
4. **Resolve the identity by hash.** The SHA-1 of the signing identity is read from `security find-identity -v -p codesigning` rather than the identity being named by string, so that a renamed or absent certificate fails loudly instead of matching nothing.
5. **Sign** each path with `codesign --force --timestamp --options runtime --entitlements <plist> --sign <hash>`.
6. **Verify** each path with `codesign --verify --strict --verbose=2`.
7. **Notarize.** The paths are collected into one zip with `ditto -c -k --keepParent` and submitted with `xcrun notarytool submit --wait --key <p8> --key-id <id> --issuer <uuid>`. Any status other than `Accepted` fails the step, and `notarytool log` is printed before the failure so that the rejection reason reaches the run log.
8. **Staple and validate**, when a `.dmg` or `.app` was given.
9. **Assess** with `spctl`, as the final statement that the artefact is what it claims to be.

### 5.3 Entitlements

The shipped plist sets `com.apple.security.cs.disable-library-validation` to true, for the reason given in section 3. No other entitlement is granted. The desktop bundle does not use this plist; see section 7.

## 6. Per-component integration

Signing is placed immediately after the build step and before the existing regression gates, not after them. The Nordic gate, the runtime observables gate, the small-signal gates and the various smoke gates then exercise the signed binary at no additional cost, so a signature that prevents the binary from starting fails the build in the place that already exists to catch that. No new execution gate is written.

| Component | Artefacts signed | Workflow position |
|---|---|---|
| `stepss-helios` | `build/helios`, `build/libhelios_api.dylib` | After the build step, before the C API smoke test |
| `stepss-ramses` | `build/Release_gnu_m/ramses`, `build/Release_gnu_m/ramses.so` | After Build, before the Nordic regression gate |
| `stepss-Codegen` | `Release_m/CODEGEN` | After Build, before the example regression gate |
| `stepss-dyngraph` | `Release_m/dyngraph` | After Build, before the smoke gate |

One existing line conflicts and must change. `stepss-helios/.github/workflows/ci.yml:96` runs `codesign -dv build/libhelios_api.dylib || codesign --force -s - build/libhelios_api.dylib`, which replaces a Developer ID signature with an ad-hoc one whenever it fires. With real signing in place the fallback is removed, and the `codesign -dv` check becomes an assertion rather than a conditional.

Helios signs on pushes to `main` and on tags, and is skipped on `pull_request`, because a pull request receives no secrets and would otherwise fail on every contribution.

## 7. The java-ui desktop bundle

Signing is delegated to `jpackage` rather than performed afterwards, because `jpackage` builds the `.app` image, places the bundled Java 21 runtime inside it and wraps the result in the `.dmg` in a single invocation; signing afterwards would mean unpacking and repacking a disk image the tool has just produced. The shared action runs twice in this leg. It runs first in `sign` mode, which imports the identity and exports `keychain-path` without signing anything, and `build.xml` passes that path to `jpackage` through `--mac-signing-keychain`. It runs again after `ant bundle` in `notarize` mode with `bundle` set to the built `.dmg`, which submits, staples and validates.

Two details are read off the runner rather than assumed. The exact option spelling is taken from `jpackage --help` on the JDK 21 runner before the first commit, because later JDK versions introduced separate app-image and installer identity options alongside `--mac-sign`, `--mac-signing-key-user-name` and `--mac-signing-keychain`. The default entitlements are asserted rather than replaced: `jpackage` supplies its own entitlements file covering the JVM's requirements for just-in-time compilation and unsigned executable memory, and passing `--mac-entitlements` replaces that default wholesale rather than adding to it. The leg therefore passes no custom entitlements and instead runs `codesign -d --entitlements -` on the built `.app`, failing if `disable-library-validation` is absent. Whether it is present by default is a question for that assertion.

The bundle identifier is pinned explicitly through `--mac-package-identifier my.stepss` rather than left to `jpackage`'s derivation from the main class package. The reasoning is the one the `--win-upgrade-uuid` comment at `stepss-java-ui/build.xml:474` already sets out: an identifier by which the operating system recognises one installation as the successor of another must not be a side effect of a refactor. `my.stepss` is what the derivation currently produces, and writing it down is what prevents a package rename from moving it.

Notarization adds roughly two to fifteen minutes to the macOS leg. That cost falls inside a job whose result is already awaited: the release exists only as a draft until all three `bundles` legs succeed, so a notarization timeout fails the release and triggers the `discard` job rather than publishing a partial set. The promote and discard arrangement needs no change and must not be given one.

## 8. Rollout order and proof

The order follows from the dependency rather than from preference.

1. `stepss-ci` is created, the action written, the organization secrets and variables configured, and the Actions access setting on `stepss-ci` opened to the organization.
2. `stepss-helios` adopts the action. Several merges to `main` exercise the credentials, the entitlement and the notarization round trip against real artefacts, with no release at risk.
3. `stepss-ramses`, `stepss-Codegen` and `stepss-dyngraph` adopt it. Their first exercise is a genuine release; the risk is bounded by step 2 having already proved the chain.
4. `stepss-java-ui` adopts it last, because a `.dmg` built before step 3 has released would be a signed and notarized container holding four unsigned engines.

## 9. Secrets, variables, and the umbrella record

Five values are defined once at organization level on SPS-L, which is on the `team` plan and therefore permits organization secrets for private repositories, and scoped to the five repositories that need them.

| Name | Kind | Value |
|---|---|---|
| `APPLE_SIGNING_P12` | secret | base64 of the PKCS#12 bundle |
| `APPLE_SIGNING_P12_PASSWORD` | secret | the export password |
| `APPLE_NOTARY_KEY_P8` | secret | base64 of `AuthKey_8A4L5VF84Z.p8` |
| `APPLE_NOTARY_KEY_ID` | variable | `8A4L5VF84Z` |
| `APPLE_NOTARY_ISSUER_ID` | variable | the UUID from App Store Connect |

The two identifiers are organization variables and not secrets on purpose. The umbrella `CLAUDE.md` defends the property that `grep -rho 'secrets\.[A-Z_]*' stepss-*/.github/workflows/*.yml | sort -u` returns a short and meaningful answer, and an identifier that appears in build logs anyway would dilute it. The three that remain are signing material, the same category as `APT_GPG_PRIVATE_KEY` and equally not a credential for reaching another repository, so the justification the umbrella already records for a second secret name extends to them. The expected output of that grep is updated to five names in the same pass.

The PKCS#12 bundle is produced once, locally:

```sh
openssl x509 -inform DER -in developerID_application.cer -out cert.pem
openssl pkcs12 -export -legacy -inkey private.key -in cert.pem \
        -name "Developer ID Application" -out stepss-signing.p12
base64 -w0 stepss-signing.p12
base64 -w0 AuthKey_8A4L5VF84Z.p8
```

`-legacy` is deliberate: OpenSSL 3 encrypts PKCS#12 with AES-256 and PBKDF2 by default, which the macOS keychain importer has historically refused. Should `codesign` report an untrusted chain, the Developer ID Certification Authority G2 intermediate is added with `-certfile`, fetched from `http://certs.apple.com/devidg2.der` as the certificate's own authority information access extension names it. The hosted runner images normally carry it, so this is a contingency rather than a step.

The umbrella `CLAUDE.md` gains a section recording the three facts that read as implementation details inside any one repository and are invisible from the others: that the hardened runtime forces `disable-library-validation` because every engine links Homebrew's GCC runtime; that a ticket is keyed on the code directory hash and can be stapled to the `.dmg` alone, which is why the tarball assets were left untouched; and that engine binaries are signed upstream because `jpackage` cannot reach inside `stepss.jar`.

## 10. Documentation that becomes wrong

Four texts tell users the macOS binaries are unsigned and instruct them to strip the quarantine attribute. Each is corrected in the same commit as the workflow it sits in, so that no release can carry a signed binary beside an instruction to work around the absence of a signature.

- `stepss-Codegen/.github/workflows/release.yml:290`
- `stepss-dyngraph/.github/workflows/release.yml:301`
- `stepss-ramses/.github/workflows/release.yml:392`
- `stepss-python-ui/tools/update_helios_libs.sh:12`

`stepss-docs` needs no correction, since `installation.mdx` never made the claim. It may gain a sentence once the `.dmg` opens without the right-click gesture.

## 11. Maintenance

Two dates enter the record. The certificate expires on 2031-09-12, four weeks after the apt signing key's 2031-08-15, which makes 2031 a year in which two independent and otherwise unannounced failures would arrive within a month of each other. The Apple Developer Program membership renews annually on 2026-11-20, and a lapsed membership revokes the certificate, which makes the annual date the more likely surprise of the two.

The certificate expiry has a technical guard, step 2 of the action. The membership renewal has none and is recorded in the umbrella instead. Rotation replaces three organization secrets in one place and requires no repository to be touched.

## 12. Out of scope

Intel Macs remain unsupported; every macOS artefact is Apple Silicon only and signing does not change that. `stepss-uramses` is untouched, for the reason given in section 3. Bundling and re-signing the Homebrew GCC runtime so that `brew install gcc` is no longer a prerequisite is recorded in section 4 as the successor to this work and is not part of it. No release asset is renamed, reformatted, added or removed.

## 13. Open items before implementation

The Issuer ID must be copied from App Store Connect. The API key's role must be confirmed to permit notarization, which `xcrun notarytool store-credentials` establishes on the first attempt.
