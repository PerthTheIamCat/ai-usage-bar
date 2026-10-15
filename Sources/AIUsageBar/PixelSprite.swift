import SwiftUI
import AppKit

/// Supported 8-bit desktop companion characters.
enum CompanionCharacter: String, CaseIterable, Identifiable, Codable {
    case farmer   // Stardew Valley-inspired farmer
    case junimo   // Stardew Valley forest spirit
    case cat      // Cozy farm cat

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .farmer: return "Stardew Farmer"
        case .junimo: return "Junimo"
        case .cat: return "Farm Cat"
        }
    }
}

/// An 8-bit pixel matrix where each character in the string rows maps to a Color.
struct PixelFrame {
    let rows: [String]
    let palette: [Character: Color]
    let width: Int
    let height: Int

    init(rows: [String], palette: [Character: Color]) {
        self.rows = rows
        self.palette = palette
        self.height = rows.count
        self.width = rows.first?.count ?? 0
    }
}

/// 8-bit sprite library providing animation frames for each companion archetype.
enum PixelSpriteLibrary {
    // Transparent token
    static let transparent: Character = " "

    // MARK: - Stardew Farmer Palette
    // H = Hat top, h = Hat brim, S = Skin, E = Eyes, B = Beard/Cheek
    // R = Red shirt, r = Red shirt shadow, O = Overalls, o = Overalls shadow
    // Y = Brass button, F = Boots, f = Boot shadow
    static let farmerPalette: [Character: Color] = [
        "H": Color(red: 0.92, green: 0.74, blue: 0.32),
        "h": Color(red: 0.72, green: 0.52, blue: 0.18),
        "S": Color(red: 1.00, green: 0.81, blue: 0.64),
        "s": Color(red: 0.88, green: 0.67, blue: 0.51),
        "E": Color(red: 0.22, green: 0.14, blue: 0.11),
        "R": Color(red: 0.76, green: 0.25, blue: 0.22),
        "r": Color(red: 0.55, green: 0.15, blue: 0.13),
        "O": Color(red: 0.21, green: 0.39, blue: 0.65),
        "o": Color(red: 0.14, green: 0.26, blue: 0.46),
        "Y": Color(red: 0.98, green: 0.85, blue: 0.30),
        "F": Color(red: 0.33, green: 0.21, blue: 0.15),
        "f": Color(red: 0.21, green: 0.13, blue: 0.09),
        "M": Color(red: 0.65, green: 0.72, blue: 0.78),
        "W": Color(red: 0.35, green: 0.65, blue: 0.95),
        "P": Color(red: 0.98, green: 0.82, blue: 0.20)
    ]

    // 14 wide x 18 tall
    static let farmerIdle1 = PixelFrame(
        rows: [
            "    HHHHHH    ",
            "   HHHHHHHH   ",
            "  hhhhhhhhhhhh",
            "    SSSSSS    ",
            "    SEssES    ",
            "    SSSSSS    ",
            "   RRSSSSRR   ",
            "  RRROOORRR   ",
            "  RRROOORRR   ",
            "   RrOYOrR    ",
            "    OOOOOO    ",
            "    OOOOOO    ",
            "    OO  OO    ",
            "    OO  OO    ",
            "    oo  oo    ",
            "    FF  FF    ",
            "    ff  ff    "
        ],
        palette: farmerPalette
    )

    static let farmerIdle2 = PixelFrame(
        rows: [
            "    HHHHHH    ",
            "   HHHHHHHH   ",
            "  hhhhhhhhhhhh",
            "    SSSSSS    ",
            "    SEssES    ",
            "    SSSSSS    ",
            "   RRSSSSRR   ",
            "  RRROOORRR   ",
            "  RRROOORRR   ",
            "   RrOYOrR    ",
            "    OOOOOO    ",
            "    OOOOOO    ",
            "    OO  OO    ",
            "    OO  OO    ",
            "    oo  oo    ",
            "    FF  FF    ",
            "    ff  ff    "
        ],
        palette: farmerPalette
    )

    static let farmerWalk1 = PixelFrame(
        rows: [
            "    HHHHHH    ",
            "   HHHHHHHH   ",
            "  hhhhhhhhhhhh",
            "    SSSSSS    ",
            "    SEssES    ",
            "    SSSSSS    ",
            "  RR RSSS  RR ",
            "  RRROOOR  RR ",
            "   RrOOOr   R ",
            "    OOOOOO    ",
            "    OOOOOO    ",
            "   OOO  OO    ",
            "   OO   OO    ",
            "   oo    oo   ",
            "  FFF     FF  ",
            "  ff      ff  "
        ],
        palette: farmerPalette
    )

    static let farmerWalk2 = PixelFrame(
        rows: [
            "    HHHHHH    ",
            "   HHHHHHHH   ",
            "  hhhhhhhhhhhh",
            "    SSSSSS    ",
            "    SEssES    ",
            "    SSSSSS    ",
            "   RRSSSSRR   ",
            "  RRROOORRR   ",
            "   RrOOOrR    ",
            "    OOOOOO    ",
            "    OOOOOO    ",
            "    OO  OO    ",
            "    OO  OO    ",
            "    oo  oo    ",
            "    FF  FF    ",
            "    ff  ff    "
        ],
        palette: farmerPalette
    )

    static let farmerWalk3 = PixelFrame(
        rows: [
            "    HHHHHH    ",
            "   HHHHHHHH   ",
            "  hhhhhhhhhhhh",
            "    SSSSSS    ",
            "    SEssES    ",
            "    SSSSSS    ",
            " RR  SSSS RR  ",
            " RR  ROOORRR  ",
            " R   rOOOrR   ",
            "    OOOOOO    ",
            "    OOOOOO    ",
            "    OO  OOO   ",
            "    OO   OO   ",
            "   oo    oo   ",
            "  FF     FFF  ",
            "  ff      ff  "
        ],
        palette: farmerPalette
    )

    static let farmerSleep = PixelFrame(
        rows: [
            "              ",
            "              ",
            "    HHHHHH    ",
            "   HHHHHHHH   ",
            "  hhhhhhhhhhhh",
            "    SSSSSS    ",
            "    SEE EES   ",
            "   RRSSSSRR   ",
            "  RRROOORRR   ",
            "   OOOOOOOO   ",
            "   OOOOOOOO   ",
            "    FF  FF    ",
            "    ff  ff    "
        ],
        palette: farmerPalette
    )

    static let farmerWater1 = PixelFrame(
        rows: [
            "    HHHHHH    ",
            "   HHHHHHHH   ",
            "  hhhhhhhhhhhh",
            "    SSSSSS    ",
            "    SEssES    ",
            "    SSSSSS    ",
            "   RRSSSSRR   ",
            "  RRROOORRMMM ",
            "   RrOYOrRMMM ",
            "    OOOOOOMMM ",
            "    OOOOOO    ",
            "    OO  OO    ",
            "    OO  OO    ",
            "    oo  oo    ",
            "    FF  FF    ",
            "    ff  ff    "
        ],
        palette: farmerPalette
    )

    static let farmerWater2 = PixelFrame(
        rows: [
            "    HHHHHH    ",
            "   HHHHHHHH   ",
            "  hhhhhhhhhhhh",
            "    SSSSSS    ",
            "    SEssES    ",
            "    SSSSSS    ",
            "   RRSSSSRR   ",
            "  RRROOORR    ",
            "   RrOYOrRMMM ",
            "    OOOOOOMMMW",
            "    OOOOOO MMM",
            "    OO  OO  WW",
            "    OO  OO   W",
            "    oo  oo  W ",
            "    FF  FF    ",
            "    ff  ff    "
        ],
        palette: farmerPalette
    )

    static let farmerCelebrate1 = PixelFrame(
        rows: [
            "      PPP     ",
            "     PPPPP    ",
            "      PPP     ",
            "  S HHHHHH S  ",
            "  SRHHHHHHRS  ",
            "  RhhhhhhhhR  ",
            "    SSSSSS    ",
            "    SEssES    ",
            "    SSSSSS    ",
            "   RRSSSSRR   ",
            "  RRROOORRR   ",
            "   RrOYOrR    ",
            "    OOOOOO    ",
            "    OOOOOO    ",
            "    OO  OO    ",
            "    oo  oo    ",
            "    FF  FF    ",
            "    ff  ff    "
        ],
        palette: farmerPalette
    )

    static let farmerCelebrate2 = PixelFrame(
        rows: [
            "    P PPP P   ",
            "     PPPPP    ",
            "    P PPP P   ",
            "  S HHHHHH S  ",
            "  SRHHHHHHRS  ",
            "  RhhhhhhhhR  ",
            "    SSSSSS    ",
            "    SEssES    ",
            "    SSSSSS    ",
            "   RRSSSSRR   ",
            "  RRROOORRR   ",
            "   RrOYOrR    ",
            "    OOOOOO    ",
            "    OOOOOO    ",
            "    OO  OO    ",
            "    oo  oo    ",
            "    FF  FF    ",
            "    ff  ff    "
        ],
        palette: farmerPalette
    )

    static let farmerStretch1 = PixelFrame(
        rows: [
            "  S HHHHHH S  ",
            "  ShHHHHHHhS  ",
            "  hhhhhhhhhhhh",
            "    SSSSSS    ",
            "    SEssES    ",
            "    SSSSSS    ",
            "   RRSSSSRR   ",
            "  RRROOORRR   ",
            "   RrOYOrR    ",
            "    OOOOOO    ",
            "    OOOOOO    ",
            "    OO  OO    ",
            "    OO  OO    ",
            "    oo  oo    ",
            "    FF  FF    ",
            "    ff  ff    "
        ],
        palette: farmerPalette
    )

    static let farmerStretch2 = PixelFrame(
        rows: [
            "   SHHHHHHS   ",
            "   ShHHHHhS   ",
            "  hhhhhhhhhhhh",
            "    SSSSSS    ",
            "    SEssES    ",
            "    SSSSSS    ",
            "   RRSSSSRR   ",
            "  RRROOORRR   ",
            "   RrOYOrR    ",
            "    OOOOOO    ",
            "    OOOOOO    ",
            "    OO  OO    ",
            "    OO  OO    ",
            "    oo  oo    ",
            "    FF  FF    ",
            "    ff  ff    "
        ],
        palette: farmerPalette
    )

    // MARK: - Junimo Palette & Frames
    // G = Main Green, g = Shadow Green, L = Leaf, E = Eyes, C = Cheeks, W = White highlight
    // P = Apple red, Y = Star gold
    static let junimoPalette: [Character: Color] = [
        "L": Color(red: 0.18, green: 0.52, blue: 0.20),
        "G": Color(red: 0.35, green: 0.82, blue: 0.33),
        "g": Color(red: 0.22, green: 0.62, blue: 0.22),
        "W": Color(red: 0.80, green: 1.00, blue: 0.78),
        "E": Color(red: 0.12, green: 0.18, blue: 0.12),
        "C": Color(red: 1.00, green: 0.58, blue: 0.68),
        "P": Color(red: 0.95, green: 0.28, blue: 0.24),
        "Y": Color(red: 0.98, green: 0.85, blue: 0.25)
    ]

    static let junimoIdle1 = PixelFrame(
        rows: [
            "      LL      ",
            "     L        ",
            "    GGGGGG    ",
            "  GGWWGGGGGG  ",
            " GGGWGGGGGGGG ",
            " GGEGGGGGEGGG ",
            " GGGGGGGGGGGG ",
            " GGCGGGGGCGGG ",
            " GGGGGGGGGGGG ",
            "  gggggggggg  ",
            "   gg    gg   "
        ],
        palette: junimoPalette
    )

    static let junimoIdle2 = PixelFrame(
        rows: [
            "      LL      ",
            "     L        ",
            "              ",
            "    GGGGGG    ",
            "  GGWWGGGGGG  ",
            " GGGWGGGGGGGG ",
            " GGEGGGGGEGGG ",
            " GGCGGGGGCGGG ",
            " GGGGGGGGGGGG ",
            "  gggggggggg  ",
            "   gg    gg   "
        ],
        palette: junimoPalette
    )

    static let junimoHop1 = PixelFrame(
        rows: [
            "      LL      ",
            "     L        ",
            "    GGGGGG    ",
            "  GGWWGGGGGG  ",
            " GGGWGGGGGGGG ",
            " GGEGGGGGEGGG ",
            " GGCGGGGGCGGG ",
            " GGGGGGGGGGGG ",
            "  gggggggggg  ",
            "    g    g    ",
            "              "
        ],
        palette: junimoPalette
    )

    static let junimoHop2 = PixelFrame(
        rows: [
            "     LL       ",
            "      L       ",
            "    GGGGGG    ",
            "  GGWWGGGGGG  ",
            " GGGWGGGGGGGG ",
            " GGEGGGGGEGGG ",
            " GGCGGGGGCGGG ",
            " GGGGGGGGGGGG ",
            "  gggggggggg  ",
            "   gg    gg   ",
            "              "
        ],
        palette: junimoPalette
    )

    static let junimoCarry1 = PixelFrame(
        rows: [
            "     PPPP     ",
            "    PPPPPP    ",
            "     PPPP     ",
            "      LL      ",
            "    GGGGGG    ",
            "  GGWWGGGGGG  ",
            " GGGWGGGGGGGG ",
            " GGEGGGGGEGGG ",
            " GGCGGGGGCGGG ",
            "  gggggggggg  ",
            "   gg    gg   "
        ],
        palette: junimoPalette
    )

    static let junimoCarry2 = PixelFrame(
        rows: [
            "     PPPP     ",
            "    PPPPPP    ",
            "     PPPP     ",
            "     LL       ",
            "    GGGGGG    ",
            "  GGWWGGGGGG  ",
            " GGGWGGGGGGGG ",
            " GGEGGGGGEGGG ",
            " GGCGGGGGCGGG ",
            "  gggggggggg  ",
            "    g    g    "
        ],
        palette: junimoPalette
    )

    static let junimoSpin1 = PixelFrame(
        rows: [
            "      LL      ",
            "     L        ",
            "    GGGGGG    ",
            "  GGWWGGGGGG  ",
            " GGGWGGGGGGGG ",
            " GGEGGGGGEGGG ",
            " GGCGGGGGCGGG ",
            " GGGGGGGGGGGG ",
            "  gggggggggg  ",
            "   gg    gg   "
        ],
        palette: junimoPalette
    )

    static let junimoSpin2 = PixelFrame(
        rows: [
            "      LL      ",
            "     L        ",
            "    GGGGGG    ",
            "  GGWWGGGGGG  ",
            " GGGWGGGGGGGG ",
            " GGGGGGGGEGGG ",
            " GGGGGGGGCGGG ",
            " GGGGGGGGGGGG ",
            "  gggggggggg  ",
            "   gg    gg   "
        ],
        palette: junimoPalette
    )

    static let junimoSpin3 = PixelFrame(
        rows: [
            "      LL      ",
            "     L        ",
            "    GGGGGG    ",
            "  GGGGGGGGGG  ",
            " GGGGGGGGGGGG ",
            " GGGGGGGGGGGG ",
            " GGGGGGGGGGGG ",
            " GGGGGGGGGGGG ",
            "  gggggggggg  ",
            "   gg    gg   "
        ],
        palette: junimoPalette
    )

    static let junimoSpin4 = PixelFrame(
        rows: [
            "      LL      ",
            "     L        ",
            "    GGGGGG    ",
            "  GGWWGGGGGG  ",
            " GGGWGGGGGGGG ",
            " GGGEGGGGGGGG ",
            " GGGCGGGGGGGG ",
            " GGGGGGGGGGGG ",
            "  gggggggggg  ",
            "   gg    gg   "
        ],
        palette: junimoPalette
    )

    // MARK: - Farm Cat Palette & Frames
    // O = Orange fur, o = Dark orange, W = White fur, E = Green eyes, N = Pink nose
    static let catPalette: [Character: Color] = [
        "O": Color(red: 0.94, green: 0.56, blue: 0.22),
        "o": Color(red: 0.74, green: 0.38, blue: 0.12),
        "W": Color(red: 0.98, green: 0.95, blue: 0.90),
        "E": Color(red: 0.30, green: 0.75, blue: 0.40),
        "N": Color(red: 0.95, green: 0.55, blue: 0.65)
    ]

    static let catWalk1 = PixelFrame(
        rows: [
            " O   O        ",
            " OOO O        ",
            " OEO O        ",
            " ONW OOOOO    ",
            "  WWWWWWWW O  ",
            "  WWWWWWWW O  ",
            "   OO  OO  O  ",
            "   OO   OO    ",
            "   WW   WW    "
        ],
        palette: catPalette
    )

    static let catWalk2 = PixelFrame(
        rows: [
            " O   O        ",
            " OOO O        ",
            " OEO O        ",
            " ONW OOOOO    ",
            "  WWWWWWWW  O ",
            "  WWWWWWWW  O ",
            "    OO  OO O  ",
            "   OO    OO   ",
            "   WW    WW   "
        ],
        palette: catPalette
    )

    static let catSleep = PixelFrame(
        rows: [
            "              ",
            "              ",
            "   O   O      ",
            "  OOOOOOO     ",
            "  OE   EO     ",
            "  ONWWWWWOOO  ",
            "  WWWWWWWWWWo ",
            "  ooooooooooo "
        ],
        palette: catPalette
    )

    static let catStretch1 = PixelFrame(
        rows: [
            "              ",
            "              ",
            "           O  ",
            "         OOOO ",
            "       OOOOOO ",
            " O   OOOOOOOO ",
            " OOOOOOOOOO   ",
            " WWWWWWWWWW   ",
            "  WW    WW    "
        ],
        palette: catPalette
    )

    static let catStretch2 = PixelFrame(
        rows: [
            "              ",
            "              ",
            " O   O        ",
            " OOOOO        ",
            " OEOOO        ",
            " ONWWWW       ",
            "  WWWWWWWW    ",
            "  WWWWWWWWWO  ",
            "  WW    WW O  "
        ],
        palette: catPalette
    )

    static let catGroom1 = PixelFrame(
        rows: [
            "   O   O      ",
            "   OOOOO      ",
            "   OEOEO      ",
            "   ONWNO      ",
            "    WWWW      ",
            "   WWWWWW O   ",
            "   OO  OO O   ",
            "   WW  WW     "
        ],
        palette: catPalette
    )

    static let catGroom2 = PixelFrame(
        rows: [
            "   O   O      ",
            "   OOOOOW     ",
            "   OEOEOW     ",
            "   ONWNOW     ",
            "    WWWW      ",
            "   WWWWWW O   ",
            "   OO  OO O   ",
            "   WW  WW     "
        ],
        palette: catPalette
    )

    static let catPounce1 = PixelFrame(
        rows: [
            "              ",
            "              ",
            "  O   O       ",
            "  OOOOO       ",
            "  OEOEO       ",
            "  ONWNO       ",
            "   WWWWWW O   ",
            "  WWWWWWWW    ",
            "  oooooooo    "
        ],
        palette: catPalette
    )

    static let catPounce2 = PixelFrame(
        rows: [
            "  O   O       ",
            "  OOOOO       ",
            "  OEOEO       ",
            "  ONWNO       ",
            "   WWWWWW     ",
            "  WWWWWWWW    ",
            "   WW   WW O  ",
            "   OO   OO O  ",
            "              "
        ],
        palette: catPalette
    )

    // MARK: - Helper to retrieve animation frames
    static func frames(for character: CompanionCharacter, state: CompanionState, stage: EvolutionStage = .seedling) -> [PixelFrame] {
        switch character {
        case .farmer:
            switch state {
            case .idle:
                return stage >= .legend ? [farmerCelebrate1, farmerCelebrate2] : [farmerIdle1, farmerIdle2]
            case .walking:
                return [farmerWalk1, farmerWalk2, farmerWalk3, farmerWalk2]
            case .sprinting:
                return [farmerWalk1, farmerWalk3]
            case .working:
                return [farmerWater1, farmerWater2]
            case .celebrating:
                return [farmerCelebrate1, farmerCelebrate2]
            case .stretching:
                return [farmerStretch1, farmerStretch2]
            case .sleeping:
                return [farmerSleep]
            case .petting:
                return [farmerCelebrate1, farmerCelebrate2]
            case .poked:
                return [farmerCelebrate2, farmerCelebrate1]
            case .dangling:
                return [farmerCelebrate2, farmerStretch1]
            case .falling:
                return [farmerWalk3, farmerCelebrate1]
            case .landing:
                return [farmerStretch2]
            }
        case .junimo:
            switch state {
            case .idle:
                return stage >= .legend ? [junimoCarry1, junimoCarry2] : [junimoIdle1, junimoIdle2]
            case .walking:
                return [junimoHop1, junimoHop2]
            case .sprinting:
                return [junimoCarry1, junimoCarry2]
            case .working:
                return [junimoCarry1, junimoCarry2]
            case .celebrating:
                return [junimoSpin1, junimoSpin2, junimoSpin3, junimoSpin4]
            case .stretching:
                return [junimoHop1, junimoIdle1]
            case .sleeping:
                return [junimoIdle2]
            case .petting:
                return [junimoSpin1, junimoHop1, junimoSpin2, junimoHop2]
            case .poked:
                return [junimoSpin1, junimoSpin2, junimoSpin3, junimoSpin4]
            case .dangling:
                return [junimoSpin2, junimoSpin4]
            case .falling:
                return [junimoHop1, junimoHop2]
            case .landing:
                return [junimoIdle2]
            }
        case .cat:
            switch state {
            case .idle:
                return [catWalk1]
            case .walking:
                return [catWalk1, catWalk2]
            case .sprinting:
                return [catPounce1, catPounce2]
            case .working:
                return [catPounce1, catPounce2]
            case .celebrating:
                return [catGroom1, catGroom2]
            case .stretching:
                return [catStretch1, catStretch2]
            case .sleeping:
                return [catSleep]
            case .petting:
                return [catGroom1, catGroom2]
            case .poked:
                return [catPounce1, catPounce2]
            case .dangling:
                return [catStretch2, catGroom2]
            case .falling:
                return [catPounce2, catPounce1]
            case .landing:
                return [catWalk1]
            }
        }
    }
}

/// SwiftUI view that renders a single `PixelFrame` crisply with custom pixel size.
struct PixelFrameView: View {
    let frame: PixelFrame
    let pixelSize: CGFloat
    let flipHorizontal: Bool

    init(frame: PixelFrame, pixelSize: CGFloat = 3.0, flipHorizontal: Bool = false) {
        self.frame = frame
        self.pixelSize = pixelSize
        self.flipHorizontal = flipHorizontal
    }

    var body: some View {
        Canvas { context, size in
            let rows = frame.rows
            let pSize = CGSize(width: pixelSize, height: pixelSize)

            for (rowIndex, row) in rows.enumerated() {
                let y = CGFloat(rowIndex) * pixelSize
                for (colIndex, char) in row.enumerated() {
                    guard let color = frame.palette[char] else { continue }
                    let actualCol = flipHorizontal ? (frame.width - 1 - colIndex) : colIndex
                    let x = CGFloat(actualCol) * pixelSize
                    let rect = CGRect(origin: CGPoint(x: x, y: y), size: pSize)
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(width: CGFloat(frame.width) * pixelSize, height: CGFloat(frame.height) * pixelSize)
    }
}
