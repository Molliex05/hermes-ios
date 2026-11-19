import QuickLook
import SwiftUI

/// Fetches a payslip's PDF for the conversation's agent (by pay date). Set by the chat.
struct PaystubFiles {
    let load: @MainActor (String) async throws -> Data
}

extension EnvironmentValues {
    @Entry var paystubFiles: PaystubFiles? = nil
}

/// A payslip Jarvis checked against the calendar: the week it pays, whether it balances, the figures that matter (the
/// calendar's next to the paid ones), the older weeks it adjusts, and the PDF itself in the native preview.
struct PaystubCard: View {
    let stub: ChatCard.Paystub
    @Environment(\.paystubFiles) private var files
    @State private var preview: URL?
    @State private var loading = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !stub.lines.isEmpty || !stub.net.isEmpty { figures }
            if !stub.adjustments.isEmpty { adjustments }
            if !stub.note.isEmpty {
                Text(stub.note).font(.callout).foregroundStyle(stub.verdict == .balance ? Color.secondary : Self.color(stub.verdict))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if files != nil { pdfButton }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        }
        .padding(16).cardSurface()
        .quickLookPreview($preview)
        .onChange(of: preview) { old, new in
            // The PDF holds personal data: the temporary copy goes as soon as the preview closes.
            if new == nil, let old { try? FileManager.default.removeItem(at: old) }
        }
        .accessibilityIdentifier("card-paystub")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "dollarsign.circle.fill").font(.title2).foregroundStyle(Self.color(stub.verdict))
                .frame(width: 44, height: 44)
                .background(Self.color(stub.verdict).opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1).minimumScaleFactor(0.85)
                if !stub.week.isEmpty { Text("Semaine \(stub.week)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 6)
            Label(Self.label(stub.verdict), systemImage: Self.symbol(stub.verdict))
                .labelStyle(.titleAndIcon).font(.caption.weight(.semibold)).foregroundStyle(Self.color(stub.verdict))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Self.color(stub.verdict).opacity(0.12), in: Capsule())
        }
        .accessibilityElement(children: .combine)
    }

    private var figures: some View {
        VStack(spacing: 0) {
            ForEach(Array(stub.lines.enumerated()), id: \.element.id) { index, line in
                if index > 0 { Divider() }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if line.gap { Image(systemName: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.orange) }
                    Text(line.label).font(.subheadline).lineLimit(1)
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(line.paid).font(.subheadline.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(line.gap ? Color.orange : Color.primary)
                        if !line.calendar.isEmpty {
                            Text("agenda \(line.calendar)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }
            if !stub.net.isEmpty {
                if !stub.lines.isEmpty { Divider() }
                HStack(alignment: .firstTextBaseline) {
                    Text("Net déposé").font(.subheadline.weight(.medium))
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(stub.net).font(.title3.weight(.bold)).monospacedDigit()
                        if !stub.gross.isEmpty { Text("brut \(stub.gross)").font(.caption2).foregroundStyle(.secondary).monospacedDigit() }
                    }
                }
                .padding(.top, 10)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var adjustments: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(stub.adjustments.enumerated()), id: \.offset) { _, text in
                Label { Text(text).font(.caption).fixedSize(horizontal: false, vertical: true) } icon: {
                    Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(.blue)
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ajustements : " + stub.adjustments.joined(separator: ". "))
    }

    private var pdfButton: some View {
        Button { Task { await openPDF() } } label: {
            HStack(spacing: 8) {
                if loading { ProgressView().controlSize(.small) } else { Image(systemName: "doc.text.magnifyingglass") }
                Text(loading ? "Ouverture…" : "Voir le talon")
            }
            .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 11)
            .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(AppTheme.accent)
        }
        .buttonStyle(.plain).disabled(loading)
        .accessibilityHint("Ouvre le PDF du talon")
    }

    private var title: String {
        guard let day = stub.day else { return "Paie" }
        return "Paie du " + day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "fr_CA")))
    }

    private func openPDF() async {
        guard let files, !loading else { return }
        loading = true; failure = nil
        defer { loading = false }
        do {
            let data = try await files.load(stub.payDate)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Paye (\(stub.payDate)).pdf")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            preview = url
            Haptics.select()
        } catch {
            failure = (error as? RPCFailure)?.message ?? "Le talon n’a pas pu être ouvert."
        }
    }

    static func color(_ verdict: ChatCard.Verdict) -> Color {
        switch verdict { case .balance: .green; case .gap: .orange; case .check: .secondary }
    }
    static func label(_ verdict: ChatCard.Verdict) -> String {
        switch verdict { case .balance: "Balance"; case .gap: "Écart"; case .check: "À vérifier" }
    }
    static func symbol(_ verdict: ChatCard.Verdict) -> String {
        switch verdict { case .balance: "checkmark.circle.fill"; case .gap: "exclamationmark.triangle.fill"; case .check: "questionmark.circle.fill" }
    }
}
