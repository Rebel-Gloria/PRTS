import Foundation

struct PRTSBinaryMask {
    let width: Int
    let height: Int
    var values: [UInt8]
    init(width: Int, height: Int, values: [UInt8]? = nil) {
        precondition(width > 0 && height > 0)
        self.width = width; self.height = height
        self.values = values ?? Array(repeating: 0, count: width * height)
        precondition(self.values.count == width * height)
    }
    subscript(x: Int, y: Int) -> UInt8 { get { values[y * width + x] } set { values[y * width + x] = newValue } }
}
