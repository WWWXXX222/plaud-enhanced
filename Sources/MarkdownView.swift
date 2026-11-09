import SwiftUI
import AppKit

/// A single native text document lets a mouse selection cross paragraphs, headings,
/// lists and table cells. Separate SwiftUI Text views cannot share a selection.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    let baseURL: URL?
    init(_ text: String, baseURL: URL? = nil) {
        blocks = MarkdownDocument.parse(text); self.baseURL = baseURL
    }
    init(blocks: [MarkdownBlock], baseURL: URL?) { self.blocks = blocks; self.baseURL = baseURL }
    var body: some View {
        SelectableMarkdownText(blocks: blocks, baseURL: baseURL)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor enum MarkdownRichText {
    static let ink = NSColor(white: 0.12, alpha: 1)

    static func inline(_ text: String, font: NSFont, baseURL: URL?) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: "")
        let value = MarkdownDocument.inline(text, baseURL: baseURL)
        for run in value.runs {
            var runFont = font
            let intent = run.inlinePresentationIntent
            if intent?.contains(.code) == true { runFont = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular) }
            if intent?.contains(.stronglyEmphasized) == true { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) }
            if intent?.contains(.emphasized) == true { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: ink]
            if intent?.contains(.strikethrough) == true { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if intent?.contains(.code) == true { attributes[.backgroundColor] = NSColor(white: 0.95, alpha: 1) }
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(value[run.range].characters), attributes: attributes))
        }
        return result
    }

    static func render(_ blocks: [MarkdownBlock], baseURL: URL?) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        func append(_ value: NSAttributedString, style: NSParagraphStyle, background: NSColor? = nil) {
            let paragraph = NSMutableAttributedString(attributedString: value)
            paragraph.append(NSAttributedString(string: "\n", attributes: value.length > 0 ? value.attributes(at: value.length - 1, effectiveRange: nil) : [.font: NSFont.systemFont(ofSize: 14)]))
            paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
            if let background { paragraph.addAttribute(.backgroundColor, value: background, range: NSRange(location: 0, length: paragraph.length)) }
            result.append(paragraph)
        }
        func style(_ indent: CGFloat = 0) -> NSMutableParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 5; p.paragraphSpacing = 16
            p.firstLineHeadIndent = indent; p.headIndent = indent
            return p
        }
        func renderBlocks(_ values: [MarkdownBlock], quoteDepth: Int = 0) {
            let indent = CGFloat(quoteDepth) * 18
            for block in values {
                let p = style(indent)
                let font = NSFont.systemFont(ofSize: 14)
                switch block {
                case .heading(let level, let text):
                    p.paragraphSpacingBefore = level <= 2 ? 16 : 8; p.lineSpacing = 3
                    append(inline(text, font: .systemFont(ofSize: level == 1 ? 26 : level == 2 ? 21 : level == 3 ? 17 : 15, weight: .semibold), baseURL: baseURL), style: p)
                case .paragraph(let text):
                    append(inline(text, font: font, baseURL: baseURL), style: p)
                case .listItem(let depth, let marker, let text, let checked):
                    let prefix = checked.map { $0 ? "☑" : "☐" } ?? (["-", "*", "+"].contains(marker) ? "•" : marker)
                    p.firstLineHeadIndent = indent + CGFloat(min(depth, 12)) * 18
                    p.headIndent = p.firstLineHeadIndent + 24
                    p.tabStops = [NSTextTab(textAlignment: .left, location: p.headIndent)]
                    let item = NSMutableAttributedString(string: prefix + "\t", attributes: [.font: font, .foregroundColor: ink])
                    item.append(inline(text, font: font, baseURL: baseURL))
                    append(item, style: p)
                case .quote(let children):
                    let start = result.length
                    renderBlocks(children, quoteDepth: quoteDepth + 1)
                    result.addAttribute(.backgroundColor, value: NSColor(white: 0.97, alpha: 1), range: NSRange(location: start, length: result.length - start))
                case .code(let language, let text):
                    if !language.isEmpty {
                        let labelStyle = style(indent); labelStyle.paragraphSpacing = 6
                        append(NSAttributedString(string: language, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]), style: labelStyle)
                    }
                    p.headIndent += 12; p.firstLineHeadIndent += 12; p.lineSpacing = 4
                    append(NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: ink]), style: p, background: NSColor(white: 0.96, alpha: 1))
                case .rule:
                    append(NSAttributedString(string: "────────────────────────", attributes: [.font: font, .foregroundColor: NSColor(white: 0.8, alpha: 1)]), style: p)
                case .image(let alt, let path):
                    let text = alt.isEmpty ? "查看图片" : alt
                    var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
                    if let url = URL(string: path, relativeTo: baseURL)?.absoluteURL, MarkdownDocument.permittedLink(url) { attributes[.link] = url }
                    append(NSAttributedString(string: text, attributes: attributes), style: p)
                case .table(let headers, let rows, let alignments):
                    guard !headers.isEmpty else { continue }
                    let table = NSTextTable()
                    table.numberOfColumns = headers.count; table.layoutAlgorithm = .fixedLayoutAlgorithm
                    table.collapsesBorders = true; table.setContentWidth(100, type: .percentageValueType)
                    for (rowIndex, cells) in ([headers] + rows).enumerated() {
                        for column in headers.indices {
                            let cell = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                            cell.setContentWidth(100 / CGFloat(headers.count), type: .percentageValueType)
                            cell.setWidth(10, type: .absoluteValueType, for: .padding)
                            cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                            cell.setBorderColor(NSColor(white: 0.86, alpha: 1))
                            cell.backgroundColor = NSColor(white: rowIndex == 0 ? 0.93 : rowIndex % 2 == 0 ? 0.98 : 1, alpha: 1)
                            cell.verticalAlignment = .topAlignment
                            let cellStyle = style(); cellStyle.paragraphSpacing = 0; cellStyle.lineSpacing = 4; cellStyle.textBlocks = [cell]
                            if column < alignments.count {
                                switch alignments[column] { case .leading: cellStyle.alignment = .left; case .center: cellStyle.alignment = .center; case .trailing: cellStyle.alignment = .right }
                            }
                            append(inline(column < cells.count ? cells[column] : "", font: .systemFont(ofSize: 13, weight: rowIndex == 0 ? .semibold : .regular), baseURL: baseURL), style: cellStyle)
                        }
                    }
                    // End the table before the next paragraph, keeping all cells in
                    // this same text storage for normal selection and rich-text copy.
                    let gap = style(); gap.paragraphSpacing = 8
                    append(NSAttributedString(string: "", attributes: [.font: font]), style: gap)
                }
            }
        }
        renderBlocks(blocks)
        return result
    }
}

@MainActor final class MarkdownTextView: NSTextView {
    private var documentStorage: NSTextStorage?
    private var renderedBlocks: [MarkdownBlock]?
    private var renderedBaseURL: URL?
    private let measurementStorage = NSTextStorage()
    private let measurementLayout = NSLayoutManager()
    private let measurementContainer = NSTextContainer(containerSize: NSSize(width: 650, height: CGFloat.greatestFiniteMagnitude))
    private var measuredSizes: [CGFloat: NSSize] = [:]

    convenience init() {
        // TextKit 1 supplies native table layout and cross-cell selection.
        let storage = NSTextStorage(), layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 650, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
        documentStorage = storage
        measurementStorage.addLayoutManager(measurementLayout)
        measurementLayout.addTextContainer(measurementContainer)
        measurementContainer.lineFragmentPadding = 0
        measurementContainer.widthTracksTextView = false
        measurementContainer.heightTracksTextView = false
        isEditable = false; isSelectable = true; isRichText = true
        importsGraphics = false; allowsImageEditing = false
        drawsBackground = false; textContainerInset = .zero; container.lineFragmentPadding = 0
        container.widthTracksTextView = false; container.heightTracksTextView = false
        // SwiftUI owns the frame and outer scrolling. AppKit must not resize
        // this view while laying out text for a proposed SwiftUI size.
        isHorizontallyResizable = false; isVerticallyResizable = false
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        isAutomaticLinkDetectionEnabled = false
        linkTextAttributes = [.foregroundColor: MarkdownRichText.ink, .underlineStyle: NSUnderlineStyle.single.rawValue]
        setAccessibilityLabel("会议分析正文")
    }

    func display(blocks: [MarkdownBlock], baseURL: URL?) {
        // Store refreshes every two seconds. Replacing unchanged text would destroy
        // the user's in-progress selection, even with a single text view.
        guard renderedBlocks != blocks || renderedBaseURL != baseURL else { return }
        renderedBlocks = blocks; renderedBaseURL = baseURL
        let document = MarkdownRichText.render(blocks, baseURL: baseURL)
        textStorage?.setAttributedString(document)
        measurementStorage.setAttributedString(document)
        measuredSizes.removeAll()
        setSelectedRange(NSRange(location: 0, length: 0))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Only the committed view frame sets the visible document's width.
        // A later ideal/minimum/maximum measurement may never overwrite it.
        guard newSize.width.isFinite, newSize.width > 0, let textContainer,
              textContainer.containerSize.width != newSize.width else { return }
        textContainer.containerSize = NSSize(width: newSize.width, height: .greatestFiniteMagnitude)
        needsDisplay = true
    }

    func fittedSize(width: CGFloat) -> NSSize {
        // SwiftUI can probe 650 (ideal), zero, infinity and the final width in
        // any order, even after placing the view. Measure a separate TextKit
        // document so those queries cannot change visible wrapping/selection.
        let width = width.isFinite && width > 0 ? width : 650
        if let cached = measuredSizes[width] { return cached }
        measurementContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        measurementLayout.ensureLayout(for: measurementContainer)
        let height = max(measurementLayout.usedRect(for: measurementContainer).maxY, measurementLayout.extraLineFragmentRect.maxY)
        let size = NSSize(width: width, height: max(ceil(height), 1))
        if measuredSizes.count >= 8 { measuredSizes.removeAll() }
        measuredSizes[width] = size
        return size
    }
}

private struct SelectableMarkdownText: NSViewRepresentable {
    let blocks: [MarkdownBlock]
    let baseURL: URL?
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> MarkdownTextView {
        let view = MarkdownTextView(); view.delegate = context.coordinator
        view.display(blocks: blocks, baseURL: baseURL)
        return view
    }
    func updateNSView(_ view: MarkdownTextView, context: Context) { view.display(blocks: blocks, baseURL: baseURL) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownTextView, context: Context) -> CGSize? {
        nsView.fittedSize(width: proposal.width ?? 650)
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)), MarkdownDocument.permittedLink(url) else { return true }
            if url.isFileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            else { NSWorkspace.shared.open(url) }
            return true
        }
    }
}
