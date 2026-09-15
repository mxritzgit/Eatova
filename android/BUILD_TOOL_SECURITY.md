# Android build-tool advisory triage

Reviewed 2026-09-15. Owner: Eatova maintainers. Recheck when AGP/Kotlin, build
tasks, caches, Jetifier or dependency resolution changes. This documents known
build-tool findings; it is not an assertion that the toolchain is vulnerability-free.

The required Android CI job scans app release-runtime/desugaring dependencies
strictly. It separately produces the `build-tool-security` artifact containing
the actual Settings-plugin classpath, bundled R8 version, unfiltered OSV JSON,
advisory table and this triage. Inventory/scanner errors fail the job. Known
build-tool advisories produce a visible warning rather than a global exception
that could hide an app-runtime vulnerability. The report includes every matched
advisory, including new ones that this dated triage has not evaluated.

## Inspected configuration

Flutter3.47.2, Java21, Gradle8.14.4, AGP8.11.1, Kotlin plugin2.2.20, bundled
R8 8.11.18. The Settings classpath contains151 modules; R8 adds one inventory
component because AGP bundles it. The app-runtime inventory contains169 selected
Maven components, with none of the Netty/Compress/jose4j/BC/JDOM modules below.
The build-tool scan currently returns45 distinct advisory IDs across12 packages.
No matched advisory was suppressed or force-resolved to a replacement version.

The actual configured projects have no KAPT plugin/task. Jetifier is explicitly
disabled. The [build policy](build_tool_policy.gradle) checks these conditions
before tasks execute; the generated SBOM records the effective AGP option.
Normal CI requests assemble/bundle,
not UTP instrumentation tests. Inspection of direct vendor bytecode references
is not a proof about all reflection, custom tasks or externally overridden flags.

## Applicability and supported follow-up

| Tool dependency | Inspected trigger / current use | Follow-up |
| --- | --- | --- |
| Kotlin Gradle plugin2.2.20 | CVE-2026-53914 concerns poisoned KAPT incremental `apt-cache.bin` / `java-cache.bin` deserialization. No KAPT plugins or tasks exist in the configured project. The manufacturer's fix is specific to KAPT, not all Kotlin compilation caches. | Reevaluate before adding KAPT or sharing untrusted build caches. The indexed fix starts2.4.20-Beta1; do not migrate to a prerelease solely to remove this currently inactive-path match. [Manufacturer patch](https://github.com/JetBrains/kotlin/commit/bf51df665b458fda7c3eaf436c4d88dc119d7ec6). |
| Netty4.1.110.Final via grpc-netty1.69.1 | Multiple HTTP/TLS/compression/Windows advisories. AGP's UTP test-result server uses gRPC, a certificate trust collection and required client authentication. It is not established to bind only to loopback. Normal assemble/bundle does not start those UTP tests; Windows loader issues also require attacker-created local input. | Netty4.1.138 is the current same-line security-update candidate, newer than the highest4.1.137 floor in the inspected advisory set. Re-resolve and test the complete aligned family and UTP consumers; do not claim the network parsers are universally unreachable. [Vendor security release](https://netty.io/news/2026/09/09/4-1-138-Final.html). |
| Commons Compress1.21 | CVE-2024-25710 requires corrupted DUMP parsing; CVE-2024-26308 requires broken Pack200 input. Inspected Android SDK installation/alignment consumers use ZIP classes, with no direct DUMP/Pack200 consumer found. The separate TAR advisory begins at1.22, not1.21. |1.26.0 is the fix floor for these two matches. Verify SDK ZIP/alignment behavior and new transitives before a buildtool constraint. [Apache security list](https://commons.apache.org/proper/commons-compress/security.html). |
| jose4j0.9.5 | CVE-2024-29371 requires compressed JWE decompression. Bundletool1.18.1 transparency code uses JWS with ES256-restricted verification; no JWE/decompression consumer was found in inspected Android modules. |0.9.6 is the narrow fix candidate. Verify bundletool/transparency compatibility rather than treating JWS as the JWE exploit. [Advisory and supplier patch reference](https://osv.dev/vulnerability/GHSA-3677-xxcr-wjqv). |
| Bouncy Castle provider/PKIX/util1.79 | Matches concern GOST CTR keystream reuse, explicit LDAPStoreHelper use, and draft composite-signature verification. Direct Android consumers found were UTP TLS and keystore helpers, with no direct references to the three affected APIs. APK signing alone does not prove use of those APIs. | Keep all three BC modules aligned.1.84 is a straightforward release candidate; manufacturer1.80.2/1.81.1 security backports need separate availability/supply-chain validation. [GOST](https://github.com/bcgit/bc-java/wiki/CVE%E2%80%902025%E2%80%9014813), [LDAP](https://github.com/bcgit/bc-java/wiki/CVE%E2%80%902026%E2%80%900636), [composite signatures](https://github.com/bcgit/bc-java/wiki/CVE%E2%80%902026%E2%80%905588). |
| JDOM2.0.6 via Jetifier1.0.0-beta10 | Jetifier constructs default SAXBuilder and parses POM XML without explicit entity restrictions. This is a risky path if Jetifier is enabled and handles attacker-influenced XML. The build policy now rejects effective enabling overrides. | Keep Jetifier off unless required. The indexed2.0.6.1 patch alone does not make a default SAXBuilder universally XXE-safe; enabling this path requires caller parser hardening plus benign-POM/XXE tests. [Supplier release](https://github.com/hunterhacker/jdom/releases/tag/JDOM-2.0.6.1). |

Prefer a compatible vendor AGP patch/minor whose **resolved** classpath improves
these dependencies. The latest documented AGP 8 candidate was checked below;
it does not replace any of the currently matched vulnerable modules.
Do not introduce global OSV ignores, untested transitive overrides or an AGP9 /
Kotlin-beta migration merely to turn the report green. Any justified toolchain
update needs fresh inventories and actual debug and release AAB/R8/AOT checks;
exercise the affected optional tools if enabling them. Production credentials
remain outside PR build jobs.

### Follow-up: vendor candidate and enforced exposure assumptions

On 2026-09-15, AGP **8.13.2** was resolved in an isolated checkout with the same
Flutter 3.47.2, Gradle 8.14.4, Kotlin 2.2.20 and Java 21. The vendor documents
Gradle 8.13 / JDK 17 minimums and bundled R8 8.13.19 in its
[release notes](https://developer.android.com/build/releases/agp-8-13-0-release-notes).
No forced transitive versions or advisory exclusions were applied.

| Resolved evidence | Current AGP 8.11.1 | Candidate AGP 8.13.2 |
| --- | --- | --- |
| Build-tool components, including bundled R8 | 152 | 154 |
| Bundled R8 | 8.11.18 | 8.13.19 |
| Distinct advisory IDs / package-advisory matches | 45 / 46 | 45 / 46 |
| Release-runtime/desugaring components | 169 | 169, byte-identical inventory |

The candidate keeps the affected Kotlin, Netty, Commons Compress, jose4j,
Bouncy Castle and JDOM coordinates unchanged. It was reverted after resolution
and scanning because it does not remediate this advisory set. This comparison
is not a claim that candidate debug/release builds were validated. The retained
toolchain remains pinned; a future compatible vendor update needs fresh scans
and native build validation.

The current inactive-path assessment is now enforced instead of depending only
on prose: normal Gradle builds reject enabling Jetifier or adding KAPT plugins
or tasks, including unselected/lazily registered KAPT tasks. The checks run after
project evaluation and before task execution. Their errors point here for a
deliberate vendor fix / consumer reassessment before changing the policy. They
are specific to the two currently reviewed optional consumers; they do not
remove the underlying vulnerable libraries or isolate arbitrary build scripts.

Jetifier uses `ProviderFactory.gradleProperty`, matching AGP's actual
`ProjectOptions` implementation. Some Flutter plugins declare an extra property
with the same name; `project.findProperty` can report `true` while the effective
AGP provider is `false`. The guard and inventory use the actual provider, and a
benign regression prevents rejecting these unaffected plugin projects.

[Synthetic Gradle tests](../test/tooling/build_tool_policy_test.py) prove that
CLI/system overrides and KAPT additions stop before a task writes its marker,
while defaults, explicit disablement and harmless plugin extras still build.
Replacing the policy with an empty script makes the rejection tests fail.
The existing Android CI job runs these tests alongside resolver regressions.
The retained toolchain also produced a debug APK and release AAB with nonempty
R8 mapping and Dart AOT on the final policy. Those local builds used dummy
backend defines and a throwaway release keystore; they were not distributed or
installed on a user device.

The Gradle8.14 resolver vulnerabilities are different: the affected repository
fallback runs in ordinary builds. Gradle8.14.4 fixes them, and a synthetic
connection-failure/legitimate404 regression verifies fail-closed behavior.
These two manufacturer advisories were missing from OSV at review time, so an
empty scanner result cannot substitute for manufacturer advisories and tests:
[CVE-2026-22865](https://github.com/gradle/gradle/security/advisories/GHSA-mqwm-5m85-gmcv),
[CVE-2026-22816](https://github.com/gradle/gradle/security/advisories/GHSA-w78c-w6vf-rw82).

## Local reproduction

After the normal Flutter Android bootstrap, with Java21 and the pinned wrapper:

```sh
cd android
./gradlew -I build_tool_inventory.init.gradle writeBuildToolSbom --console=plain
cd ..
python3 test/tooling/build_tool_report_test.py
python3 test/tooling/build_tool_policy_test.py
python3 tool/build_tool_report.py --scanner /path/to/verified/osv-scanner
```

OSV2.3.8 is used in CI. Exit1 is accepted only with a valid, complete JSON report
containing actual advisory matches. Missing output, scanner errors, empty or
incomplete inventories and contradictory scanner statuses fail.
