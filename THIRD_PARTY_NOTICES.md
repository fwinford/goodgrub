# Third-party notices

This file identifies material in this repository, or used by it, that carries
terms separate from the project's [MIT License](LICENSE). It is informational.
It is not legal advice, and it does not clear any item that it lists as not
yet cleared.

## Scope of the MIT License

The [MIT License](LICENSE) applies only to original source code that Faith
Winford is authorized to license. It does not grant rights to the official
GoodGrub name, logo, or brand identity, and it does not grant rights in
third-party material. The MIT License is not a statement that
every file in this repository is original or MIT-licensed.

## Bundled third-party material with verified terms

### Fraunces font

| | |
|---|---|
| Files | `ios/CommonPlateios/CommonPlateios/Resources/Fonts/Fraunces-Variable.ttf` |
| License text | `ios/CommonPlateios/CommonPlateios/Resources/Licenses/Fraunces-OFL.txt` |
| License | SIL Open Font License, Version 1.1 |
| Use | Display typography in the iOS app (declared in the iOS `Info.plist`) |

The font file's embedded copyright notice reads "Copyright 2020 The Fraunces
Project Authors (github.com/undercasetype/Fraunces)". The bundled license text
begins "Copyright 2018 The Fraunces Project Authors
(https://github.com/undercasetype/Fraunces)". Both notices are preserved as
found. The license text declares no Reserved Font Name. The OFL requires that
the copyright notice and license accompany any redistribution of the font and
that the font not be sold by itself. This notice has not byte-compared the
bundled file with the upstream release.

## Referenced but not bundled

### Web fonts (not loaded)

The legacy web pages `public/home.html` and `public/new-request.html` no
longer load any remote fonts; they declare Cabin and Plus Jakarta Sans first in
`public/css/base.css` and `public/css/layout.css` but fall back to `-apple-system, system-ui, sans-serif`,
and no font files for them are in this repository. The names resolve only if a
visitor already has those fonts installed. The legacy website is deprecated and
unsupported.

### Apple platform frameworks and SF Symbols

The iOS app uses Apple system frameworks and refers to SF Symbols by name
(`Image(systemName:)`). No SF Symbols artwork or Apple font files are in this
repository. Their use is governed by Apple's developer agreements and license
terms, not by the MIT License. The iOS project has no Swift Package, CocoaPods,
or Carthage dependencies.

### npm dependencies

`package-lock.json` pins 509 dependency packages (excluding the root package).
This repository does not contain `node_modules`; `npm ci` installs each package
with its own license file. Declared licenses in the lockfile:

| License | Packages |
|---|---|
| MIT | 426 |
| ISC | 36 |
| Apache-2.0 | 12 |
| BSD-2-Clause | 12 |
| MPL-2.0 | 12 |
| BSD-3-Clause | 5 |
| Python-2.0 | 2 |
| 0BSD | 1 |
| Unlicense | 1 |
| MIT OR CC0-1.0 | 1 |
| No declared license | 1 |

103 of these packages are production (non-development) dependencies: 90 MIT, 5
ISC, 4 Apache-2.0 (`bson`, `kareem`, `mongodb`, `mongodb-connection-string-url`),
2 BSD-2-Clause, 1 BSD-3-Clause, and 1 Unlicense (`fast-sha256`). Every
MPL-2.0 package is `lightningcss` or one of its optional platform builds, and
both Python-2.0 entries are `argparse` copies; all are development-only. The one
package with no declared license, `callsite` 1.0.0, is a development-only
dependency of `depcheck`; its README states "MIT", but its package metadata
declares no license. Anyone who redistributes installed packages, a bundled
build, or a container image must include each package's own license and notice
files. The browser bundles in `public/js` are built from this repository's own
source and do not include npm package code.

## Retained visual assets with unverified provenance

The following assets are distributed in this repository. The maintainer
recalls creating them through Figma, including its AI features, and does not
recall importing third-party artwork. That is the maintainer's recollection;
independent verification is incomplete. In particular, no Figma source survives
for the ticket illustration or for the other illustrations. The maintainer has
chosen to retain them with this uncertainty documented. That choice is not a
determination of copyright ownership. Their authorship, copyright status, and
redistribution terms are not established by repository evidence, and this
notice makes no statement that they are verified original human artwork,
copyright-protected, MIT-licensed, conclusively cleared for redistribution, or
free of third-party rights. They are not covered by any grant in this file, and
this file makes no determination of rights in the icon files or in the GoodGrub
brand.

| Path | Use |
|---|---|
| `ios/CommonPlateios/CommonPlateios/Assets.xcassets/GoodGrubAppIcon.appiconset/AppIcon-*.png` (8 sizes) | iOS app icon |
| `ios/CommonPlateios/CommonPlateios/Assets.xcassets/HelperSuccessMeal.imageset/HelperSuccessMeal.svg` | Illustration |
| `ios/CommonPlateios/CommonPlateios/Assets.xcassets/HelperSuccessTicket.imageset/HelperSuccessTicket.svg` | Illustration |
| `ios/CommonPlateios/CommonPlateios/Assets.xcassets/TicketToMealMotif.imageset/Group 1.svg` | Illustration |
| `ios/CommonPlateios/CommonPlateios/Assets.xcassets/UnsupportedSchoolPlate.imageset/UnsupportedSchoolPlate.svg` | Illustration |

The external-link arrow beside "Open Grubhub" is the Apple SF Symbol
`arrow.up.right`, not a repository asset.
The project's records trace the app icon and some illustrations to Figma
design files; that is not by itself proof of who created every element or of
the rights to redistribute it. The icon's Figma source consists of editable
vector paths with no identified imported component instances; the file
subscribes only to Apple's iOS and iPadOS design kits.

## Excluded material

`public/images/thankyou.gif` was removed from the intended public source
because its original source and license are unknown. It is not cleared for
redistribution. This repository's history begins with a snapshot that does not
include the file; copies may still exist in the maintainer's separate private
historical repository.

## Trademarks and third-party names

Grubhub, NYU, and vendor names in the app and its data are used only to
identify the services and places they refer to. This project is not
affiliated with or endorsed by them. Apple, iOS, and SF Symbols are trademarks
of Apple Inc. All other names belong to their owners.
