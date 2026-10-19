import Foundation
import CoreGraphics

enum OverlayShortcut: String, CaseIterable, Identifiable {
    case optionCommandT, controlOptionT, controlShiftT
    var id: String { rawValue }
    var title: String {
        switch self {
        case .optionCommandT: return "⌥⌘T"
        case .controlOptionT: return "⌃⌥T"
        case .controlShiftT: return "⌃⇧T"
        }
    }
}

struct OverlayDisplay: Identifiable {
    let id: String
    let title: String
}

struct OverlayLayout {
    static let width: CGFloat = 400
    static let compactHeight: CGFloat = 184
    static let expandedHeight: CGFloat = 460
    let contentFrame: CGRect
    let controlFrame: CGRect

    /// Reserve the expanded bounds so the operation point never moves on expansion.
    static func make(in area: CGRect, expanded: Bool, horizontal: Double, vertical: Double) -> OverlayLayout {
        let margin: CGFloat = min(12, max(0, min(area.width, area.height) / 4))
        let width = min(Self.width, max(1, area.width - margin * 2))
        let maximumHeight = min(expandedHeight, max(1, area.height - margin * 2))
        let height = expanded ? maximumHeight : min(compactHeight, maximumHeight)
        let x = area.minX + margin + max(0, area.width - margin * 2 - width) * CGFloat(unit(horizontal))
        let top = area.maxY - margin - max(0, area.height - margin * 2 - maximumHeight) * CGFloat(unit(vertical))
        let frame = CGRect(x: x, y: top - height, width: width, height: height)
        let buttonSize = min(36, width, height)
        let button = CGRect(x: frame.maxX - buttonSize - min(10, max(0, width - buttonSize)),
                            y: top - buttonSize - min(6, max(0, height - buttonSize)), width: buttonSize, height: buttonSize)
        return OverlayLayout(contentFrame: frame, controlFrame: button)
    }

    static func unit(_ value: Double, fallback: Double = 0.5) -> Double {
        value.isFinite ? min(1, max(0, value)) : fallback
    }

    static func opacity(_ value: Double) -> Double { max(0.2, unit(value, fallback: 0.85)) }
}

enum OverlayText {
    /// Bounded blocks let the isolated operation point scroll long, read-only text.
    static func blocks(_ text: String, limit: Int = 180) -> [String] {
        guard !text.isEmpty else { return [""] }
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: max(1, limit), limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[start..<end]))
            start = end
        }
        return result
    }
}
