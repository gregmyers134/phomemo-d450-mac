/// Calibration page: shows which print-head dots and which rows land on the label.
///
/// It is drawn on the full 864-dot head width and is not shifted by `leftDot`.
/// Every bar is numbered with the head dot (or row) where it starts or ends:
///
/// - left block: each bar STARTS at the head dot printed beside it;
/// - right block: each bar's last dot is the head dot printed beside it;
/// - top block: each bar STARTS at the row printed under it;
/// - bottom block: each bar's last row is the row printed above it.
///
/// A bar that begins or ends on the label shows a white gap between its end
/// and the label's edge. A bar that begins or ends beyond the label runs right
/// up to the edge. The step from one bar to the next is 4 dots (0.5 mm).
/// The bar in the middle is exactly 80 dots (10 mm) long, as a scale.
public enum Ruler {
    /// 5 x 7 digits, one string per row, "1" = ink.
    private static let digits: [[String]] = [
        ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
        ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
        ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
        ["11110", "00001", "00001", "01110", "00001", "00001", "11110"],
        ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
        ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
        ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
        ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
        ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
        ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
    ]

    static let scale = 3                     // each font dot is 3 x 3 printer dots
    static let digitWidth = 5 * scale        // 15
    static let digitHeight = 7 * scale       // 21

    private static func draw(_ digit: Int, on page: inout MonoBitmap, x: Int, y: Int) {
        for (row, bits) in digits[digit].enumerated() {
            for (col, bit) in bits.enumerated() where bit == "1" {
                page.fill(x: x + col * scale, y: y + row * scale, width: scale, height: scale)
            }
        }
    }

    /// Digits side by side with their top-left corner at (`x`, `y`). Returns the width used.
    @discardableResult
    private static func number(_ value: Int, on page: inout MonoBitmap, x: Int, y: Int) -> Int {
        let text = String(value)
        for (i, ch) in text.enumerated() {
            draw(Int(String(ch))!, on: &page, x: x + i * (digitWidth + scale), y: y)
        }
        return text.count * (digitWidth + scale) - scale
    }

    public static let step = 4
    /// Head dots at which the left bars start, and at which the right bars end.
    public static func leftMarks() -> [Int] { Array(stride(from: 0, through: 60, by: step)) }
    public static func rightMarks(width: Int) -> [Int] { Array(stride(from: width - 1, through: width - 105, by: -step)) }
    /// Rows at which the top bars start, and at which the bottom bars end.
    public static func topMarks() -> [Int] { Array(stride(from: 0, through: 60, by: step)) }
    public static func bottomMarks(height: Int) -> [Int] { Array(stride(from: height - 1, through: height - 33, by: -step)) }

    public static func page(width: Int = 864, height: Int = 1218) -> MonoBitmap {
        var p = MonoBitmap(width: width, height: height)
        let pitch = 24                       // rows per bar in the side blocks
        let sideTop = 150

        // Left block: bar k starts at head dot leftMarks[k] and runs to column 250.
        for (k, dot) in leftMarks().enumerated() {
            let y = sideTop + k * pitch
            p.fill(x: dot, y: y + 6, width: 251 - dot, height: 10)
            number(dot, on: &p, x: 262, y: y)
        }
        // Right block: bar k runs from column 600 and its last dot is rightMarks[k].
        for (k, dot) in rightMarks(width: width).enumerated() {
            let y = sideTop + k * pitch
            p.fill(x: 600, y: y + 6, width: dot - 600 + 1, height: 10)
            number(dot, on: &p, x: 530, y: y)
        }
        // Top block: bar k starts at row topMarks[k] and runs to row 85. Its number is below it.
        for (k, row) in topMarks().enumerated() {
            let x = 40 + k * 48
            p.fill(x: x + 12, y: row, width: 10, height: 86 - row)
            number(row, on: &p, x: x, y: 94)
        }
        // Bottom block: bar k starts at row height - 100 and its last row is bottomMarks[k].
        let bottomTop = height - 100
        for (k, row) in bottomMarks(height: height).enumerated() {
            let x = 40 + k * 86
            p.fill(x: x + 30, y: bottomTop, width: 10, height: row - bottomTop + 1)
            number(row, on: &p, x: x, y: bottomTop - 30)
        }
        // Scale: exactly 80 dots (10 mm) long.
        p.fill(x: 392, y: 900, width: 80, height: 10)
        number(80, on: &p, x: 414, y: 918)
        return p
    }
}
