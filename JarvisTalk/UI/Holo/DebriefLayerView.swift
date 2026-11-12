import SwiftUI
import JarvisCore
import JarvisModel

/// Stage debriefs on the phone (browser: js/debrief/stage.js). An agent walks the owner through what she found, one popup
/// card per scene, formed out of the core. The card just told fades to a faint ghost (tap it to bring it back), the one before
/// it dissolves, the next pops in; scenes the agent linked are joined by a light line while both are up; when the owner
/// speaks nothing closes under them; at the end everything melts back into the core.
struct DebriefLayerView: View {
    @EnvironmentObject var debrief: DebriefModel
    @Environment(\.calmFX) private var calm

    var body: some View {
        Group {
            if debrief.isOpen && debrief.isDebrief {
                VStack(spacing: 0) {
                    ghostRow
                    linkLine
                    Spacer(minLength: 0)
                    ForEach(debrief.cards.filter { !$0.ghost }) { c in
                        SceneCardView(card: c, reportId: debrief.report?.info.id ?? "", index: (debrief.report?.index(of: c.id) ?? 0) + 1, total: debrief.report?.blocks.count ?? 1)
                            .transition(.fromCore(CGSize(width: c.side == .right ? 40 : -40, height: -300), calm: calm))
                            .id(c.id)
                    }
                    if debrief.lingering { lingerBar }
                }
                .padding(.horizontal, 10)
                .transition(.opacity)
            }
        }
        .animation(calm ? .easeInOut(duration: 0.15) : .spring(response: 0.55, dampingFraction: 0.84), value: debrief.cards.map { "\($0.id)\($0.ghost)" })
        .animation(.easeInOut(duration: 0.25), value: debrief.isOpen)
        .allowsHitTesting(debrief.isOpen)
    }

    @ViewBuilder private var ghostRow: some View {
        ForEach(debrief.cards.filter { $0.ghost }) { g in
            Button { debrief.bringBack(g.id) } label: {
                HStack(spacing: 8) {
                    Circle().fill(SceneStyle.tone(g.block.tone)).frame(width: 7, height: 7)
                    Text(g.block.heading).font(.system(size: 12, weight: .medium)).lineLimit(1).foregroundColor(Theme.text)
                    Spacer(minLength: 0)
                    Text("told").font(.system(size: 9, design: .monospaced)).foregroundColor(Theme.dimText)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .holoPlate(SceneStyle.tone(g.block.tone), active: false, corner: 12)
                .opacity(0.38).scaleEffect(0.96)
                .frame(maxWidth: .infinity, alignment: g.side == .right ? .trailing : .leading)
                .padding(g.side == .right ? .leading : .trailing, 40)
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .accessibilityLabel("Earlier scene: \(g.block.heading). Tap to bring it back.")
        }
    }

    @ViewBuilder private var linkLine: some View {
        if let l = debrief.link {
            VStack(spacing: 2) {
                Rectangle().fill(LinearGradient(colors: [Theme.accent(.jarvis).opacity(0.1), Theme.accentLight(.jarvis)], startPoint: .top, endPoint: .bottom)).frame(width: 2, height: 22)
                    .shadow(color: Theme.accent(.jarvis), radius: 4)
                if !l.label.isEmpty { Text(l.label.uppercased()).font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(2).foregroundColor(Theme.accentLight(.jarvis)) }
            }.transition(.opacity).accessibilityLabel("Linked: \(l.label)")
        }
    }

    private var lingerBar: some View {
        Text("DEBRIEF COMPLETE").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(3).foregroundColor(Theme.ok)
            .padding(.vertical, 6).transition(.opacity)
    }
}

enum SceneStyle {
    static func tone(_ t: String) -> Color { t == "alert" ? Theme.bad : (t == "good" ? Theme.ok : Theme.accent(.jarvis)) }
}

struct SceneCardView: View {
    let card: DebriefModel.Card
    let reportId: String
    let index: Int
    let total: Int
    @EnvironmentObject var debrief: DebriefModel

    var body: some View {
        let b = card.block
        let tint = SceneStyle.tone(b.tone)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(String(format: "%02d / %02d", index, total)).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(tint)
                if !b.kicker.isEmpty { Text(b.kicker.uppercased()).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.5).foregroundColor(Theme.dimText).lineLimit(1) }
                Spacer()
                Button { debrief.close() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundColor(Theme.dimText).frame(width: 36, height: 30) }
                    .accessibilityLabel("Close the debrief")
            }.padding(.leading, 12).padding(.top, 4)
            Text(b.heading).font(.system(size: 17, weight: .semibold)).foregroundColor(Theme.text).padding(.horizontal, 12).padding(.bottom, 6)
            ScrollView {
                SceneBody(card: card, reportId: reportId).padding(.horizontal, 12).padding(.bottom, 12)
            }.frame(maxHeight: 330)
        }
        .holoPlate(tint, active: true, corner: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Scene \(index) of \(total): \(b.heading)")
    }
}
