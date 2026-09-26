# xDrip buildlager, revision 26. september 2026

Målingen før fase 2 var 29,23 GiB i workspacet; build 4275 havde yderligere 1,50 GiB i den eksterne signeringsmappe. Fase 2 sluttede med 27,00 GiB i workspacet. Størrelserne nedenfor er allokerede filblokke og er ikke et mål for unikke APFS-blokke.

## Fordeling ved start af fase 2

| Gruppe | GiB, inklusive ekstern 4275-mappe |
|---|---:|
| DerivedData/intermediates | 13,55 |
| Øvrige buildprodukter og eksterne verifikationskopier | 5,03 |
| DerivedData/Products | 3,46 |
| XCResult | 2,50 |
| dSYM | 2,18 |
| XCArchive, eksklusive dSYM | 1,51 |
| IPA | 1,10 |
| Kildekode, dokumentation og konfiguration | 0,43 |
| Logs og DerivedData-logs | 0,26 |
| JSON/status | 0,16 |
| Git | 0,12 |
| DerivedData, øvrigt | <0,01 |

Kategorierne er en fil-for-fil-optælling af workspacet plus den eksterne 4275-mappe; mappeblokke og symlinkmetadata indgår i workspacets `du`-total, men ikke i kategoritabellen. Ingen betydelige Swift Package-checkouts blev fundet.

## Særligt undersøgte builds før fase 2

| Build | Workspace GiB | Ekstern GiB | Største bestanddele | Status |
|---|---:|---:|---|---|
| 4264 | 4,61 | 0 | 3,43 intermediates; 0,63 produkter; IPA/arkiv/resultat findes | `tagged`, ingen Internal/Testing-kvittering; bevaret |
| 4265 | 2,23 | 0 | 0,72 intermediates; 0,63 produkter; IPA/arkiv/resultat findes | `superseded`, ikke afsluttet release; bevaret |
| 4274 | 3,87 | 0 | 3,05 intermediates; 0,64 produkter; ingen færdig IPA/arkiv | `tagged`, arkivering uafsluttet; bevaret |
| 4275 | 3,70 | 1,50 | 2,83 test-intermediates; 0,64 testprodukter; ekstern IPA/arkiv/dSYM | Internal / Testing; komplet bevaret |

Artefakttyper for de fire builds, GiB ved start af fase 2 (4275 inkluderer
den eksterne signing-mappe):

| Type | 4264 | 4265 | 4274 | 4275 |
|---|---:|---:|---:|---:|
| DerivedData/intermediates | 3,43 | 0,72 | 3,05 | 3,51 |
| DerivedData/Products | 0,63 | 0,63 | 0,64 | 0,64 |
| Øvrige buildprodukter/kopier | 0,11 | 0,43 | 0,11 | 0,59 |
| XCArchive uden dSYM | 0,12 | 0,12 | 0 | 0,12 |
| dSYM | 0,17 | 0,17 | <0,01 | 0,17 |
| IPA | 0,09 | 0,09 | 0 | 0,09 |
| XCResult | 0,06 | 0,06 | 0,06 | 0,06 |
| Logs | 0,01 | 0,02 | 0,01 | 0,01 |
| JSON/status | <0,01 | <0,01 | <0,01 | <0,01 |

Seneste tidligere verificerede build er 4273. Dets IPA, arkiv/dSYM, XCResult, logs og status er bevaret. Checkpoint 4263, alle worktrees, SafetyBackups og alle Git-referencer er urørte.

## Hvorfor logisk og fysisk frigivelse afveg i første oprydning

Første runde fjernede 12,17 GiB målt som summen af filernes `st_blocks`, mens `df` viste 3,85 GiB flere frie blokke. De slettede filer var ikke sparse (`logicalBytes` 12,07 GiB), og deres linkantal var 1; `tmutil` viste ingen lokale snapshots på datavolumen. Volumen er APFS. Bevarede 98,9 MB diagnostikfiler har identisk SHA-256, men forskellige inodes og linkantal 1. Det er foreneligt med APFS-kloner/delte extents og File Provider-kopier, som kan få summeret filstørrelse til at overstige unikt frigivne blokke. De slettede extents kan ikke længere inspiceres, så den præcise andel fra kloner kontra andre APFS-allokeringsforhold kan ikke fastslås retrospektivt.

## 30 største enkeltfiler ved slutaudit

| Nr. | GiB | Sti relativt til workspace |
|---:|---:|---|
| 1 | 0.111 | `xdripswift-upstream-7.1.1/build/testflight-7.1.1-4275/test/DerivedData/iphone-build/Build/Products/Debug-iphonesimulator/xdrip.app/xdrip.debug.dylib` |
| 2 | 0.111 | `xdripswift-upstream-7.1.1/build/testflight-7.1.1-4274/test/DerivedData/iphone-build/Build/Products/Debug-iphonesimulator/xdrip.app/xdrip.debug.dylib` |
| 3 | 0.108 | `xdripswift-upstream-7.1.1/build/testflight-7.1.1-4265/test/DerivedData/iphone-build/Build/Products/Debug-iphonesimulator/xdrip.app/xdrip.debug.dylib` |
| 4 | 0.108 | `xdripswift-upstream-7.1.1/build/testflight-7.1.1-4264/test/DerivedData/iphone-build/Build/Products/Debug-iphonesimulator/xdrip.app/xdrip.debug.dylib` |
| 5 | 0.096 | `xdripswift-watch-reading-integration/build/release-process-smoke-escalated/DerivedData/iphone-build/Build/Products/Debug-iphonesimulator/xdrip.app/xdrip.debug.dylib` |
| 6 | 0.096 | `xdripswift-watch-reading-integration/build/integration-20260924/DerivedData/iphone-build/Build/Products/Debug-iphonesimulator/xdrip.app/xdrip.debug.dylib` |
| 7 | 0.092 | `ekstern-4275/export/xdrip.ipa` |
| 8 | 0.092 | `xdripswift-upstream-7.1.1/build/testflight-7.1.1-4273/build/export/xdrip.ipa` |
| 9 | 0.092 | `xdripswift-upstream-7.1.1/build/testflight-7.1.1-4272/build/export/xdrip.ipa` |
| 10 | 0.092 | `xdripswift-upstream-7.1.1/build/testflight-7.1.1-4271/build/export/xdrip.ipa` |
| 11 | 0.092 | `xdripswift-upstream-7.1.1/build/testflight-7.1.1-4270/build/export/xdrip.ipa` |
| 12 | 0.092 | `xdripswift-upstream-7.1.1/build/testflight-7.1.1-4269/build/export/xdrip.ipa` |
| 13 | 0.092 | `xdripswift-upstream-7.1.1/build/testflight-7.1.1-4268/build/export/xdrip.ipa` |
| 14 | 0.092 | `xdripswift-healthkit-therapy-import/build/testflight-7.1.1-4267/build/export/xdrip.ipa` |
| 15 | 0.092 | `xdripswift/build/local-setup-20260923/results/Verification-parallel-incomplete.xcresult/Staging/1_Test/Diagnostics/simctl_diagnostics/FBDB65FC-4C70-48F1-A5A1-FB352D4FACB1/system.logarchive/dsc/5827BB5652E13D0BAC027A3201246563` |
| 16 | 0.092 | `xdripswift/build/local-setup-20260923/results/Verification-parallel-incomplete.xcresult/Staging/1_Test/Diagnostics/simctl_diagnostics/D99EA33A-7DA1-44F8-975D-AC4050BE5015/system.logarchive/dsc/5827BB5652E13D0BAC027A3201246563` |
| 17 | 0.092 | `xdripswift/build/local-setup-20260923/results/Verification-parallel-incomplete.xcresult/Staging/1_Test/Diagnostics/simctl_diagnostics/7944BEBD-D180-46BC-B83F-3B792508C5DA/system.logarchive/dsc/5827BB5652E13D0BAC027A3201246563` |
| 18 | 0.092 | `xdripswift/build/local-setup-20260923/results/Verification-parallel-incomplete.xcresult/Staging/1_Test/Diagnostics/simctl_diagnostics/65DB3172-58B9-4C9E-89A9-83704C8F612B/system.logarchive/dsc/5827BB5652E13D0BAC027A3201246563` |
| 19 | 0.092 | `xdripswift/build/local-setup-20260923/results/Verification-parallel-incomplete.xcresult/Staging/1_Test/Diagnostics/simctl_diagnostics/23A54D95-467F-4363-8428-63608F7D2EA7/system.logarchive/dsc/5827BB5652E13D0BAC027A3201246563` |
| 20 | 0.092 | `xdripswift/build/local-setup-20260923/results/AllTests-iphone18-launch-failed.xcresult/Staging/1_Test/Diagnostics/simctl_diagnostics/65A70D4C-E16F-4C0E-B105-7B9A8C7EE2C8/system.logarchive/dsc/5827BB5652E13D0BAC027A3201246563` |
| 21 | 0.092 | `xdripswift/build/local-setup-20260923/results/AllTests-iphone17-incomplete.xcresult/Staging/1_Test/Diagnostics/simctl_diagnostics/669A0B1D-1022-4D05-8167-1FE173D9EB60/system.logarchive/dsc/5827BB5652E13D0BAC027A3201246563` |
| 22 | 0.092 | `xdripswift-healthkit-therapy-import/build/local/healthkit-targeted/HealthKitTherapyImportTests.xcresult/Staging/1_Test/Diagnostics/simctl_diagnostics/65A70D4C-E16F-4C0E-B105-7B9A8C7EE2C8/system.logarchive/dsc/5827BB5652E13D0BAC027A3201246563` |
| 23 | 0.092 | `xdripswift-upstream-7.1.1/build/testflight-7.1.1-4266/build/export/xdrip.ipa` |
| 24 | 0.092 | `xdripswift-upstream-7.1.1/build/testflight-7.1.1-4265/build/export/xdrip.ipa` |
| 25 | 0.092 | `xdripswift-upstream-7.1.1/build/testflight-7.1.1-4264/build/export-admin-test/xdrip.ipa` |
| 26 | 0.090 | `xdripswift-watch-reading-integration/build/release-upload-20260924/export/xdrip.ipa` |
| 27 | 0.076 | `xdripswift/.git/objects/pack/pack-337c0678702c4c47a3de1854e6f0391d13a0898f.pack` |
| 28 | 0.066 | `xdripswift-upstream-7.1.1/build/testflight-7.1.1-4265/build/DerivedData/archive/Build/Intermediates.noindex/ArchiveIntermediates/xdrip/IntermediateBuildFilesPath/xdrip.build/Release-iphoneos/xdrip.build/Objects-normal/arm64/xdrip-primary.d` |
| 29 | 0.066 | `xdripswift-upstream-7.1.1/build/testflight-7.1.1-4264/build/DerivedData/archive/Build/Intermediates.noindex/ArchiveIntermediates/xdrip/IntermediateBuildFilesPath/xdrip.build/Release-iphoneos/xdrip.build/Objects-normal/arm64/xdrip-primary.d` |
| 30 | 0.056 | `xdripswift-upstream-7.1.1/build/testflight-7.1.1-4275/test/DerivedData/iphone-build/Build/Intermediates.noindex/xdrip.build/Debug-iphonesimulator/xdrip.build/Objects-normal/x86_64/Binary/xdrip.debug.dylib` |

Ekstern-4275-stier ovenfor er relative til `~/Library/Application Support/xDrip4iOS/TestFlight/testflight-7.1.1-4275/`. Ingen af de 30 filer blev slettet i fase 2.

## Resultat af fase 2

Kun 9.590 filer i byteidentiske, udvidede IPA-kopier fra verificerede 4266 og 4268–4273 blev fjernet: 2,24 GiB allokeret; oprydningens `df`-måling viste 2,25 GiB ekstra ledig plads. Workspace gik fra 29,23 til 27,00 GiB. Ingen hele release- eller DerivedData-mapper blev slettet. Den gentagne oprydning slettede 0 filer.

Målet 5–10 GiB kan ikke nås under de nuværende beskyttelseskrav: 4275 optager ca. 5,20 GiB inklusive ekstern signing; 4264, 4265 og 4274 optager tilsammen ca. 10,71 GiB og må ikke slettes automatisk; 4263-checkpoint fylder ca. 2,76 GiB; ældre IPA/arkiver/dSYM/XCResult samt kildekode og Git bevares.
