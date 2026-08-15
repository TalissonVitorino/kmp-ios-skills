---
name: pdfkit
description: "Display, render, annotate, search, and fill PDFs on iOS with Apple's PDFKit. Covers wrapping PDFView in SwiftUI (UIViewRepresentable), PDFDocument (init(url:)/init(data:), page(at:), write(to:), encryption/permissions, unlock), PDFPage (bounds(for:), thumbnail(of:for:), draw(with:to:)), PDFAnnotation (highlight/freeText/ink/widget via init(bounds:forType:withProperties:), subtype), PDFSelection text extraction + findString search, PDFThumbnailView, AcroForm form filling via widget annotations + fieldName, PDFOutline, and PDFDocumentDelegate. Use when showing statements/receipts/contracts, generating or exporting a PDF, highlighting or marking up pages, or filling a form. For the SwiftUI↔UIKit bridge see swiftui-uikit-interop; for encrypting exported files at rest / password handling see swift-security; for OCR of scanned/image PDFs see vision-framework; for locale-aware amounts rendered into a PDF see swift-formatstyle."
---

# PDFKit (iOS)

Render, navigate, annotate, search, and fill PDFs. `import PDFKit`. iOS 11+;
this skill targets the iOS 26 era. PDFKit is UIKit-based — there is **no native
SwiftUI `PDFView`**, so wrap it with `UIViewRepresentable` (see `swiftui-uikit-interop`).

- **Threading:** `PDFView` and all UI live on the **main thread**. Loading a large
  `PDFDocument`, rendering thumbnails, and `write(to:)` are expensive — run them off
  the main actor and hand the finished object back to the view.
- **Fintech note:** never write account statements/receipts to a world-readable path.
  Export to an app-sandbox URL and, if it leaves the device or persists, encrypt at
  rest — see `swift-security`. PDFKit's own owner/user passwords (below) are AcroForm
  encryption, not a substitute for file-level protection.

## Contents

- [Display in SwiftUI](#display)
- [PDFDocument — load, save, encrypt](#document)
- [PDFPage — bounds, thumbnail, render](#page)
- [Navigate, select, search](#navsearch)
- [Annotations](#annotations)
- [Forms (AcroForm widgets)](#forms)
- [Thumbnails & outline](#thumbnails-outline)
- [PDFDocumentDelegate](#delegate)
- [Correctness checklist](#checklist)
- References: `references/annotations-forms.md`, `references/display-search.md`

<a id="display"></a>
## Display in SwiftUI

`PDFView` is a `UIView`. Bridge it once and drive it through the document.

```swift
import SwiftUI
import PDFKit

struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true                    // fit-to-width, tracks rotation/resize
        view.displayMode = .singlePageContinuous   // .singlePage | .twoUp | .twoUpContinuous
        view.displayDirection = .vertical          // or .horizontal
        view.usePageViewController(false)          // true = page-curl (iBooks-style)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
```

- Load off-main, then assign on main:

```swift
func loadDocument(at url: URL) async -> PDFDocument? {
    await Task.detached(priority: .userInitiated) { PDFDocument(url: url) }.value
}
```

- Key `PDFView` knobs: `autoScales`, `scaleFactor` / `minScaleFactor` / `maxScaleFactor`,
  `scaleFactorForSizeToFit`, `pageBreakMargins`, `backgroundColor`, `pageShadowsEnabled`.
- `PDFView.document` is optional; setting it re-lays-out. `currentPage`, `go(to:)`,
  `goToNextPage(_:)` / `goToPreviousPage(_:)` for programmatic navigation.
- Observe `.PDFViewPageChanged`, `.PDFViewScaleChanged`, `.PDFViewSelectionChanged`
  (post from `NotificationCenter`) to reflect state in SwiftUI.

<a id="document"></a>
## PDFDocument — load, save, encrypt

```swift
let doc = PDFDocument(url: fileURL)        // returns nil if unreadable/corrupt
let doc2 = PDFDocument(data: pdfData)      // from a network/blob payload

let count = doc?.pageCount ?? 0
let page  = doc?.page(at: 0)               // 0-based; nil out of range
let index = page.map { doc?.index(for: $0) }
doc?.insert(newPage, at: count)            // also removePage(at:), exchangePage(at:withPageAt:)
```

- **Save:** `write(to:)` / `write(to:withOptions:)` return `Bool`; `dataRepresentation()`
  returns `Data`. Both flatten in-memory edits (added pages, annotations) into the output.

```swift
let ok = doc.write(to: outURL)             // Bool — check it
let data = doc.dataRepresentation()        // for upload / Keychain-adjacent storage
```

- **Encryption / permissions** — supply passwords as write options (AcroForm-level):

```swift
let opts: [PDFDocumentWriteOption: Any] = [
    .userPasswordOption: userPassword,      // required to open
    .ownerPasswordOption: ownerPassword,    // required to change permissions
]
doc.write(to: outURL, withOptions: opts)
```

- **Reading a locked doc:** `isEncrypted` / `isLocked` are `true` until you call
  `unlock(withPassword:)` (returns `Bool`). `allowsCopying`, `allowsPrinting`,
  `allowsCommenting`, `allowsFormFieldEntry` report the permission flags.
- **Metadata:** `documentAttributes` (`[AnyHashable: Any]`) keyed by
  `PDFDocumentAttribute` (`.titleAttribute`, `.authorAttribute`, `.creationDateAttribute`, …).
- Do **not** hardcode passwords; source them from the user or Keychain (`swift-security`).

<a id="page"></a>
## PDFPage — bounds, thumbnail, render

A `PDFPage` exposes geometry, a bitmap, and raw drawing. `PDFDisplayBox` selects the
box: `.mediaBox` (full sheet), `.cropBox` (visible, PDFKit's default), `.bleedBox`,
`.trimBox`, `.artBox`.

```swift
let bounds = page.bounds(for: .cropBox)     // CGRect in PDF (Core Graphics) space
let rotation = page.rotation                 // 0/90/180/270
let text = page.string                       // full page text, or nil
let n = page.numberOfCharacters
```

- **Thumbnail** (returns a `UIImage`, cheap for list cells):

```swift
let thumb = page.thumbnail(of: CGSize(width: 120, height: 160), for: .cropBox)
```

- **Custom render** into your own context (export, share sheet, watermark):

```swift
let box = PDFDisplayBox.cropBox
let pageRect = page.bounds(for: box)
let renderer = UIGraphicsImageRenderer(size: pageRect.size)
let image = renderer.image { ctx in
    UIColor.white.set(); ctx.fill(pageRect)
    let cg = ctx.cgContext
    cg.translateBy(x: 0, y: pageRect.height)   // flip: PDF origin is bottom-left
    cg.scaleBy(x: 1, y: -1)
    page.draw(with: box, to: cg)               // renders page content + annotations
}
```

- PDF coordinate space is **bottom-left origin**; UIKit is top-left. Flip the CTM (as
  above) whenever you draw a page into a UIKit/`CGContext` target, and when converting
  view points use `page.convert(_:to:)` / `PDFView.convert(_:to:)`.

<a id="navsearch"></a>
## Navigate, select, search

**Text extraction** via `PDFSelection`:

```swift
let whole = page.string                                  // per page
let range = page.selection(for: NSRange(location: 0, length: 20))  // chars → selection
let sel = doc.selection(from: startPos, to: endPos)      // across pages (PDFDestination)
let picked = sel?.string                                 // extracted text
```

**Search** — synchronous returns `[PDFSelection]`; options are `NSString.CompareOptions`
(`.caseInsensitive`, `.backwards`, `.literal`). PDFKit does **not** honor
`.regularExpression`.

```swift
let hits = doc.findString("overdue", withOptions: [.caseInsensitive])
if let first = hits.first {
    first.color = .yellow
    pdfView.setCurrentSelection(first, animate: true)
    pdfView.go(to: first)                                // scroll into view
}
pdfView.highlightedSelections = hits                     // persistent highlight overlay
```

- Incremental search: `findString(_:fromSelection:withOptions:)` (one next hit), or the
  async `beginFindString(_:withOptions:)` which posts `.PDFDocumentDidBeginFind` /
  `.PDFDocumentDidFindMatch` / `.PDFDocumentDidEndFind` — use it for large docs so the
  UI never blocks.
- `PDFSelection`: `.pages`, `.string`, `.attributedString`, `.bounds(for:)`,
  `.selectionsByLine()` (split multi-line selections into per-line rects — needed to lay
  down accurate highlight annotations). Combine with `.add(_:)` / `extend(...)`.

<a id="annotations"></a>
## Annotations

Create with the modern initializer `init(bounds:forType:withProperties:)` — `bounds` is
in **page** coordinates, `forType` is a `PDFAnnotationSubtype`. Then `page.addAnnotation(_:)`.

```swift
// Free-text note
let note = PDFAnnotation(bounds: CGRect(x: 40, y: 700, width: 200, height: 24),
                         forType: .freeText, withProperties: nil)
note.contents = "Reviewed 2026-08-03"
note.font = .systemFont(ofSize: 12)
note.fontColor = .label
note.color = .clear                              // background fill
page.addAnnotation(note)
```

```swift
// Highlight the current search/text selection (one annotation per visual line)
for lineSel in selection.selectionsByLine() {
    guard let p = lineSel.pages.first else { continue }
    let h = PDFAnnotation(bounds: lineSel.bounds(for: p),
                          forType: .highlight, withProperties: nil)
    h.color = .systemYellow                       // .markupType is .highlight by subtype
    p.addAnnotation(h)
}
```

```swift
// Ink (freehand) — attach one or more UIBezierPaths in page space
let ink = PDFAnnotation(bounds: page.bounds(for: .cropBox),
                        forType: .ink, withProperties: nil)
ink.color = .systemBlue
ink.add(bezierPath)                               // repeat for multiple strokes; .paths reads them back
page.addAnnotation(ink)
```

- Subtypes: `.highlight`, `.underline`, `.strikeOut`, `.freeText`, `.ink`, `.square`,
  `.circle`, `.line`, `.stamp`, `.text` (note icon), `.link`, `.widget` (forms, below).
- Read `annotation.type` (raw subtype string) and `.bounds`; enumerate `page.annotations`.
- Remove with `page.removeAnnotation(_:)`. Edits are in-memory until you `write(to:)` /
  `dataRepresentation()`.
- Deep dive (markup colors, `PDFBorder`, stamps, links, `PDFAnnotationKey` properties) in
  `references/annotations-forms.md`.

<a id="forms"></a>
## Forms (AcroForm widgets)

Form fields are `.widget` annotations. Locate them by `fieldName`, set the value, and
save. Never guess field names — enumerate them first.

```swift
func setField(_ name: String, to value: String, in doc: PDFDocument) {
    for i in 0..<doc.pageCount {
        guard let page = doc.page(at: i) else { continue }
        for a in page.annotations where a.fieldName == name {
            switch a.widgetFieldType {
            case .text:
                a.widgetStringValue = value
            case .button:
                // checkbox / radio: match the field's on-state string
                a.buttonWidgetState = (value == a.buttonWidgetStateString) ? .onState : .offState
            case .choice:
                a.widgetStringValue = value          // list/combo selection
            default:
                break
            }
        }
    }
}
```

- Field metadata: `widgetFieldType` (`.text`, `.button`, `.choice`, `.signature`),
  `widgetControlType` (`.pushButtonControl`, `.radioButtonControl`, `.checkBoxControl`),
  `fieldName`, `isReadOnly`, `maximumLength`, `hasComb`; choice options via the
  `.widgetOptions` annotation key.
- Text value ↔ `widgetStringValue`; checkbox/radio state ↔ `buttonWidgetState`
  (`.onState` / `.offState`), whose "on" name is `buttonWidgetStateString`.
- **Flatten before sharing** if the recipient shouldn't edit fields: render each page with
  `page.draw(with:to:)` into a fresh `UIGraphicsPDFRenderer` context (widgets become static
  pixels). Full flattening recipe in `references/annotations-forms.md`.
- Respect `allowsFormFieldEntry`; a locked/encrypted doc may reject edits until unlocked.

<a id="thumbnails-outline"></a>
## Thumbnails & outline

**`PDFThumbnailView`** — a ready-made page navigator; bind it to the same `PDFView`.

```swift
let thumbs = PDFThumbnailView()
thumbs.pdfView = pdfView                 // shares selection/navigation with the main view
thumbs.thumbnailSize = CGSize(width: 80, height: 100)
thumbs.layoutMode = .vertical            // or .horizontal
```

**`PDFOutline`** — the document's table of contents (bookmarks):

```swift
if let root = doc.outlineRoot {
    for i in 0..<root.numberOfChildren {
        let item = root.child(at: i)!
        let title = item.label                 // section title
        if let dest = item.destination {       // PDFDestination: page + point
            // dest.page, dest.point — go(to:) it on tap
        }
    }
}
```

- Outline is a tree — recurse via `numberOfChildren` / `child(at:)`. `doc.outlineItem(for:)`
  maps a selection back to its outline node.

<a id="delegate"></a>
## PDFDocumentDelegate

Set `doc.delegate` to customize page behavior or observe unlock/find events.

- `classForPage()` — return a `PDFPage` subclass so every page uses your custom `draw(with:to:)`
  (e.g. stamp a "COPY" / account-number watermark on render without mutating the file):

```swift
final class WatermarkPage: PDFPage {
    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        super.draw(with: box, to: context)           // draw the real page first
        context.saveGState()
        // …draw watermark text into `context` (page space, bottom-left origin)…
        context.restoreGState()
    }
}

final class DocDelegate: NSObject, PDFDocumentDelegate {
    func classForPage() -> AnyClass { WatermarkPage.self }
    func documentDidUnlock(_ notification: Notification) { /* re-enable UI */ }
}
```

- Also: `classForAnnotationType(_:)` to substitute a custom annotation class, and the
  find-delegate callbacks (`didMatchString(_:)`) for async search results.

<a id="checklist"></a>
## Correctness checklist

- [ ] `PDFView` created/mutated only on the main thread; `PDFDocument(url:)`, thumbnails,
      and `write(to:)` run off-main, result handed back on main.
- [ ] SwiftUI integration goes through `UIViewRepresentable` (no native SwiftUI PDFView);
      `updateUIView` swaps `document` only when it actually changed (`!==`).
- [ ] Return values checked: `PDFDocument(url:)` and `page(at:)` are optional;
      `write(to:)` and `unlock(withPassword:)` return `Bool`.
- [ ] Page drawing into a `CGContext` flips the CTM (PDF is bottom-left origin);
      point conversions use `convert(_:to:)`, not manual math.
- [ ] Correct `PDFDisplayBox` chosen (`.cropBox` for what the user sees, `.mediaBox` for
      the full sheet) consistently across bounds/thumbnail/draw.
- [ ] Annotation `bounds` are in page coordinates; highlights use `selectionsByLine()` rects;
      annotations added with `addAnnotation` and persisted via `write(to:)`/`dataRepresentation()`.
- [ ] Form fields located by `fieldName` (enumerated, not guessed); text→`widgetStringValue`,
      button→`buttonWidgetState` vs `buttonWidgetStateString`; flatten before sharing read-only.
- [ ] Search treats `findString` as synchronous/blocking on large docs — use
      `beginFindString` + notifications instead; `.regularExpression` is unsupported.
- [ ] Exported financial PDFs written to the app sandbox and protected at rest
      (`swift-security`); passwords never hardcoded.
