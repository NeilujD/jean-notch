import JeanNotchCore
import SwiftUI

/// Experimental: a Claude tool use that waits for the user's answer. **Deny** answers at once.
/// **Allow** needs a second click ("Allow?"), because the notch can open under the pointer.
struct PermissionCard: View {
    let request: PermissionRequest
    let panel: PanelState
    let sending: Bool
    let failure: String?
    let answer: (_ approved: Bool) -> Void

    private var confirming: Bool { panel.confirmingAllow == request.rpcId }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            (Text("Claude wants to run ") + Text(request.toolName).font(.system(size: 11, weight: .semibold, design: .monospaced)))
                .font(.system(size: 11, weight: .semibold))
            if !request.input.isEmpty {
                ScrollView {
                    Text(request.input)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: inputHeight)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.35)))
            }
            HStack(spacing: 6) {
                Text(failure ?? "Experimental · Supervised mode")
                    .font(.system(size: 9))
                    .foregroundStyle(failure == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.red))
                    .lineLimit(2)
                Spacer(minLength: 4)
                button("Deny", highlighted: false) { answer(false) }
                button(confirming ? "Allow?" : "Allow", highlighted: confirming) {
                    if confirming { answer(true) } else { panel.confirmingAllow = request.rpcId }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.07)))
        .foregroundStyle(.white)
        .padding(.bottom, 2)
    }

    /// Up to 3 lines; a longer input scrolls. Long lines wrap, so count about 60 characters a line.
    private var inputHeight: CGFloat {
        let lines = request.input.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, ($1.count + 59) / 60) }
        return CGFloat(min(lines, 3)) * 13
    }

    private func button(_ title: String, highlighted: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(Capsule().fill(highlighted ? Urgency.waiting.color : .white.opacity(0.12)))
            .foregroundStyle(highlighted ? .black : .white)
            .disabled(sending || failure != nil)
            .opacity(sending ? 0.5 : 1)
    }
}
