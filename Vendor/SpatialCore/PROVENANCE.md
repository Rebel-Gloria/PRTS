# SpatialCore provenance

Selected pure-Swift spatial analysis files were copied from the adjacent validation project
`/Users/yuanyuan/Desktop/Prts/PRTSTEST/Core` on 2026-09-25. Recording, export, diagnostic UI,
and probe renderer code were intentionally not copied. The tiny `AppendFile` primitive is retained only to keep the
original 25-test package suite intact; the PRTS app does not call it.

Original SHA-256 values (from `PRTSTEST/Reports/source-sha256.json`):

- `Analysis.swift`: `f6b7fe6075d407e598600b9d11972d8de2526e90390d99ffbf9ff03edd5da8e7`
- `Depth.swift`: `fecff01ec16e3f76af65d2ce4d8a7a28d21c1156a51faf4d623aa4eae6d477f7`
- `Geometry.swift`: `8937c2acf906b3cc9aa50f72fb9ac04ad6ae5b242dccd9bbb9e99b896690f7ae`
- `Grid.swift`: `68091b1b23770273e5569988865d06f00bd0bcab3ea75e71f0dc4b28b04264c8`
- `Ground.swift`: `8deecf60b38fe15cecfa0014f01389989d894d29544991b99386651739120540`
- `AppendFile.swift`: `a447a4ef0a34eb2dab34594cd51083e4ee952e64728b057c79f29285c02f0a68`
- `SpatialCoreTests.swift`: `dad66e54b1348d7931664c9f3d046d80c4ad55d8d70609bf0d28441ba405344f`

PRTS adds `SceneContracts.swift` and `FeedbackPolicy.swift`. The copied algorithm behavior is kept unchanged; `Grid.swift` only adds synthesized `Hashable` conformances
for `CellState` and `Sector` so they can be stable contract identifiers. Original synthetic behavior remains directly comparable.
