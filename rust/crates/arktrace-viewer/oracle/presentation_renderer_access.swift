// Cache-only access seam; uses real private paint/cache and style methods.
extension TimelineNSView {
    package static func presentationStyle(_ category: String?) -> String { String(describing: visualStyle(for: category)) }
    package func presentationDensityFacts(_ snapshot: TimelineSnapshot) throws -> [String: Any] {
        let context = try XCTContextForPresentation()
        drawDensityOverlay(snapshot, backingScale: 1, dirtyRect: CGRect(x:0,y:0,width:200,height:80), context:context)
        guard let paths=densityPathCache?.bands[0],let key=paths.keys.sorted().first,let path=paths[key] else {throw CocoaError(.coderInvalidValue)}
        let frame=path.boundingBox
        return ["intensity":key.intensity,"heightFraction":Double(Self.densityHeightFraction(key.intensity)),
            "frame":["x":frame.minX,"y":frame.minY,"width":frame.width,"height":frame.height],
            "rgba":key.color.cgColor.components!]
    }
}
private func XCTContextForPresentation() throws -> CGContext {
    guard let context=CGContext(data:nil,width:200,height:80,bitsPerComponent:8,bytesPerRow:0,
        space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw CocoaError(.coderInvalidValue)}
    return context
}
