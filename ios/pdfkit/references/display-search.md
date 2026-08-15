# PDFKit — display, navigation, search, generation (depth)

Companion to `pdfkit/SKILL.md`. Covers `PDFView` configuration, coordinate conversion,
search UX, outline navigation, and generating a PDF from scratch.

## PDFView configuration reference

| Property | Purpose |
|---|---|
| `document` | the `PDFDocument` to show (optional) |
| `displayMode` | `.singlePage`, `.singlePageContinuous`, `.twoUp`, `.twoUpContinuous` |
| `displayDirection` | `.vertical` / `.horizontal` scrolling |
| `displaysAsBook` | first page as a right-hand page in two-up |
| `autoScales` | fit content to the view; re-fits on rotate/resize |
| `scaleFactor` / `minScaleFactor` / `maxScaleFactor` | zoom control |
| `scaleFactorForSizeToFit` | the scale that fits a page exactly (read-only) |
| `pageBreakMargins` | inter-page spacing (`UIEdgeInsets`) |
| `pageShadowsEnabled` | drop shadow around pages |
| `interpolationQuality` | `.low`/`.high` bitmap smoothing |
| `currentPage` / `currentDestination` | where the view is (read-only-ish) |
| `currentSelection` | user/programmatic text selection |
| `highlightedSelections` | overlay highlights (e.g. all search hits) |

- `usePageViewController(true, withViewOptions:)` switches to a `UIPageViewController`-backed
  page-curl presentation; call `usePageViewController(false)` to return to scrolling.
- Navigation: `go(to: PDFDestination)`, `go(to: PDFPage)`, `go(to: CGRect, on: PDFPage)`,
  `goToNextPage(_:)`, `goToPreviousPage(_:)`, `goToFirstPage(_:)`, `goToLastPage(_:)`,
  `canGoToNextPage`, plus history: `goBack(_:)` / `goForward(_:)`.

## Notifications (bridge state into SwiftUI)

```swift
NotificationCenter.default.addObserver(
    forName: .PDFViewPageChanged, object: pdfView, queue: .main) { _ in
    // update a @State page index, page label, etc.
}
```

Names: `.PDFViewDocumentChanged`, `.PDFViewPageChanged`, `.PDFViewScaleChanged`,
`.PDFViewSelectionChanged`, `.PDFViewAnnotationHit`, `.PDFViewVisiblePagesChanged`.

## Coordinate conversion

PDF pages are bottom-left origin; UIKit views are top-left. Never hand-roll the flip —
use the built-ins:

```swift
let pagePoint = pdfView.convert(viewPoint, to: page)     // view → page space
let viewRect  = pdfView.convert(page.bounds(for: .cropBox), from: page)
let hit = page.annotation(at: pagePoint)                 // annotation hit-testing
let lineSel = page.selectionForLine(at: pagePoint)       // word/line/char selection at a point
```

Related: `page.selectionForWord(at:)`, `page.selectionForRange(_:)`,
`page.characterIndex(at:)`.

## Search UX

- **Blocking, whole-doc:** `doc.findString(_:withOptions:) -> [PDFSelection]`. Fine for small
  docs; blocks the calling thread otherwise.
- **Incremental:** `doc.findString(_:fromSelection:withOptions:) -> PDFSelection?` returns the
  next single match — drive a "find next" button.
- **Async (preferred for large docs):**

```swift
doc.delegate = self
doc.beginFindString("balance", withOptions: [.caseInsensitive])
// observe .PDFDocumentDidFindMatch (userInfo["PDFDocumentFoundSelection"]) and
// .PDFDocumentDidEndFind; cancel with doc.cancelFindString()
```

- Options are `NSString.CompareOptions`: `.caseInsensitive`, `.backwards`, `.literal`,
  `.diacriticInsensitive`, `.widthInsensitive`. `.regularExpression` is **not** applied by
  PDFKit — pre-filter text yourself if you need regex.
- To show results: set `pdfView.highlightedSelections = hits`, and on tap
  `pdfView.setCurrentSelection(hit, animate: true)` + `pdfView.go(to: hit)`.

## Outline navigation

```swift
func flatten(_ node: PDFOutline, depth: Int = 0, into rows: inout [(String, Int, PDFDestination?)]) {
    for i in 0..<node.numberOfChildren {
        guard let child = node.child(at: i) else { continue }
        rows.append((child.label ?? "", depth, child.destination))
        flatten(child, depth: depth + 1, into: &rows)   // recurse the tree
    }
}
// let root = doc.outlineRoot; flatten(root, into: &rows) — then go(to: row.destination)
```

- `doc.outlineRoot` is nil when the PDF has no bookmarks.
- Build an outline programmatically by constructing `PDFOutline` nodes, setting `label` and
  `destination`, and inserting children with `insertChild(_:at:)`.

## Generating a PDF from scratch

`UIGraphicsPDFRenderer` (UIKit) is the simplest path; wrap the result in a `PDFDocument`.

```swift
func makeReceipt(lines: [String]) -> PDFDocument? {
    let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)   // US Letter, 72 dpi
    let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
    let data = renderer.pdfData { ctx in
        ctx.beginPage()
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12)]
        var y: CGFloat = 40
        for line in lines {
            line.draw(at: CGPoint(x: 40, y: y), withAttributes: attrs)
            y += 20
        }
    }
    return PDFDocument(data: data)
}
```

- `UIGraphicsPDFRenderer` uses **top-left** origin (UIKit), unlike `PDFPage.draw(with:to:)`.
  Don't flip here.
- Render currency/dates with `FormatStyle` (`swift-formatstyle`) so amounts are locale-correct
  before drawing them.
- To assemble from existing pages instead, create an empty `PDFDocument()` and
  `insert(page, at:)` copied `PDFPage`s.
