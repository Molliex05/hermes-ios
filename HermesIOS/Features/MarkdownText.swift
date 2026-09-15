import SwiftUI

struct MarkdownText: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(ChatMarkdown.parse(text).enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block).equatable()
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MarkdownBlockView: View, Equatable {
    let block: ChatMarkdown.Block
    var body: some View {
        switch block {
        case .paragraph(let text): inline(text).font(.body).lineSpacing(5)
        case .heading(let level, let text):
            inline(text).font(level == 1 ? .title2.weight(.semibold) : level == 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, 5).accessibilityAddTraits(.isHeader)
        case .quote(let text):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(AppTheme.accent.opacity(0.45)).frame(width: 3)
                inline(text).foregroundStyle(.secondary).lineSpacing(4)
            }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 3)
        case .item(let depth, let marker, let text, let checked):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                if let checked {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle").foregroundStyle(AppTheme.accent)
                        .accessibilityLabel(checked ? "Terminé" : "À faire")
                } else { Text(marker).foregroundStyle(.secondary).monospacedDigit() }
                inline(text).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.leading, CGFloat(depth) * 14)
        case .code(let language, let text): CodeBlock(language: language, text: text)
        case .table(let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                inline(cell).font(.subheadline).fontWeight(index == 0 ? .semibold : .regular)
                                    .frame(minWidth: 95, maxWidth: 230, alignment: .leading).padding(12)
                                    .frame(maxHeight: .infinity, alignment: .topLeading)
                                    .background(index == 0 ? AppTheme.line : Color.clear)
                                    .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.line).frame(height: 1) }
                            }
                        }
                    }
                }.fixedSize(horizontal: false, vertical: true)
            }.background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                .clipShape(RoundedRectangle(cornerRadius: 14)).accessibilityIdentifier("markdown-table")
        case .rule: Divider().padding(.vertical, 5)
        }
    }

    private func inline(_ source: String) -> Text {
        var parsed = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        // No remote images or executable/custom-scheme links from generated Markdown.
        for run in parsed.runs {
            if let url = run.link, !["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { parsed[run.range].link = nil }
            if run.inlinePresentationIntent?.contains(.code) == true { parsed[run.range].font = .system(.callout, design: .monospaced) }
        }
        return Text(parsed)
    }
}

private struct CodeBlock: View {
    let language: String
    let text: String
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "Code" : language).font(.caption.weight(.medium)).lineLimit(1)
                Spacer(minLength: 12)
                Button {
                    UIPasteboard.general.string = text; copied = true
                } label: {
                    Label(copied ? "Copié" : "Copier", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption).frame(minHeight: 44)
                }.buttonStyle(.plain).accessibilityLabel("Copier le code")
            }.foregroundStyle(.secondary).padding(.horizontal, 14)
            Divider()
            ScrollView(.horizontal) {
                Text(verbatim: text).font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: false).padding(14)
            }
        }.background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(AppTheme.line))
            .onChange(of: text) { _, _ in copied = false }
            .task(id: copied) { if copied { try? await Task.sleep(for: .seconds(2)); if !Task.isCancelled { copied = false } } }
            .accessibilityIdentifier("markdown-code")
    }
}
