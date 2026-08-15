# PDFKit — annotations & forms (depth)

Companion to `pdfkit/SKILL.md`. All bounds are in **page coordinates** (bottom-left
origin). Annotations are in-memory until you `write(to:)` or `dataRepresentation()`.

## PDFAnnotation via properties dictionary

`init(bounds:forType:withProperties:)` accepts a `[AnyHashable: Any]?` keyed by
`PDFAnnotationKey` string constants, letting you set everything at construction:

```swift
let props: [PDFAnnotationKey: Any] = [
    .color: UIColor.systemYellow,
    .contents: "Flagged",
]
let a = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: props)
```

Common `PDFAnnotationKey`s: `.color`, `.interiorColor`, `.contents`, `.border`,
`.subtype`, `.rect`, `.widgetFieldType`, `.widgetValue`, `.widgetDefaultValue`,
`.action`, `.destination`, `.quadPoints`, `.inkList`. (Line width is not a key — set it
on the `PDFBorder`.)

## Markup annotations (highlight / underline / strikeOut)

These render over text and are keyed to the text's quadrilaterals. The reliable pattern is
one annotation per visual line from a `PDFSelection`:

```swift
func markup(_ selection: PDFSelection, type: PDFAnnotationSubtype, color: UIColor) {
    for line in selection.selectionsByLine() {
        guard let page = line.pages.first else { continue }
        let ann = PDFAnnotation(bounds: line.bounds(for: page), forType: type, withProperties: nil)
        ann.color = color
        page.addAnnotation(ann)
    }
}
```

- `type` is `.highlight`, `.underline`, or `.strikeOut`. The subtype sets the markup
  rendering; `.color` sets the tint.
- For precise multi-quad highlights on a single annotation, set `.quadPoints` (an array of
  the four corner points per glyph run) — usually unnecessary; per-line annotations suffice.

## Free text

```swift
let t = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
t.contents = "Sign here"
t.font = .boldSystemFont(ofSize: 14)
t.fontColor = .systemRed
t.color = .clear                 // fill behind the text; .clear = transparent
t.alignment = .center
page.addAnnotation(t)
```

## Ink (freehand drawing)

```swift
let ink = PDFAnnotation(bounds: page.bounds(for: .cropBox), forType: .ink, withProperties: nil)
ink.color = .systemBlue
ink.border = PDFBorder(); ink.border?.lineWidth = 2
for stroke in strokes { ink.add(stroke) }     // stroke: UIBezierPath in page space
page.addAnnotation(ink)
let paths = ink.paths                          // [UIBezierPath] back out
```

- Convert touch points from view space to page space with
  `pdfView.convert(point, to: page)` before building the `UIBezierPath`.
- The annotation's `bounds` must enclose the paths, or strokes clip. Recompute bounds from
  the union of path bounding boxes when the drawing grows.

## Stamps, shapes, links

- **Square / circle / line:** set `.color` (stroke), `.interiorColor` (fill), and a
  `PDFBorder` for line width/style.
- **Stamp** (`.stamp`): subclass `PDFAnnotation` and override `draw(with:in:)` to render a
  custom image/vector, since PDFKit has no built-in stamp appearances.
- **Link** (`.link`): set `.action` to a `PDFActionGoTo(destination:)`,
  `PDFActionURL(url:)`, or `PDFActionNamed(name:)`; or set the annotation's `.destination`.

## Reading & editing existing annotations

```swift
for page in (0..<doc.pageCount).compactMap({ doc.page(at: $0) }) {
    for ann in page.annotations {
        switch ann.type {                       // raw subtype string, e.g. "Highlight"
        case "Highlight", "Underline": ann.color = ann.color.withAlphaComponent(0.5)
        case "FreeText":               print(ann.contents ?? "")
        default: break
        }
    }
}
```

- Delete: `page.removeAnnotation(ann)`. Hit-test a tap: `page.annotation(at: pagePoint)`.
- `ann.shouldDisplay` / `ann.shouldPrint` toggle visibility and print inclusion.

## Forms — full field walk

```swift
struct FormField { let name: String; let type: PDFAnnotationWidgetSubtype; let value: String? }

func fields(in doc: PDFDocument) -> [FormField] {
    var out: [FormField] = []
    for i in 0..<doc.pageCount {
        guard let page = doc.page(at: i) else { continue }
        for a in page.annotations where a.type == "Widget" {
            guard let name = a.fieldName else { continue }
            out.append(.init(name: name, type: a.widgetFieldType, value: a.widgetStringValue))
        }
    }
    return out
}
```

- **Text:** `widgetStringValue` get/set. `maximumLength` and `hasComb` constrain input.
- **Checkbox / radio:** `buttonWidgetState` is `.onState` / `.offState`. The on-state name is
  `buttonWidgetStateString` — for a radio group, only the widget whose state string matches
  the selected value should be `.onState`; set the rest `.offState`.
- **Choice (list/combo):** `widgetStringValue` holds the current selection. The unified
  `PDFAnnotation` has no typed options accessor — read the option list via the
  `.widgetOptions` annotation key (`annotation.value(forAnnotationKey: .widgetOptions)`).
- **Signature** (`.signature`): a placeholder widget; PDFKit does not create the cryptographic
  signature — capture ink/CryptoKit separately (see `swift-security`).
- `isReadOnly` fields should be skipped when filling.

## Flattening (make fields/annotations non-editable)

Re-render every page into a new PDF so widgets and annotations bake into static content:

```swift
func flatten(_ doc: PDFDocument, to url: URL) throws {
    guard let first = doc.page(at: 0) else { return }
    let bounds = first.bounds(for: .mediaBox)
    let renderer = UIGraphicsPDFRenderer(bounds: bounds)
    try renderer.writePDF(to: url) { ctx in
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            ctx.beginPage(withBounds: box, pageInfo: [:])
            let cg = ctx.cgContext
            cg.saveGState()
            cg.translateBy(x: 0, y: box.height)     // flip to PDF origin
            cg.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: cg)       // content + annotations + widgets → pixels/vectors
            cg.restoreGState()
        }
    }
}
```

- After flattening there are no live annotations/fields to edit — good for issued receipts,
  signed contracts, or anything a counterparty must not alter.
- Per-page media boxes can differ; read `bounds(for:)` inside the loop rather than reusing
  page 0's size.
