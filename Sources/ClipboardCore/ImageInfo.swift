import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Size and format of a copied image, for its row label.
public struct ImageInfo: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var format: String

    public init(width: Int, height: Int, format: String) {
        self.width = width
        self.height = height
        self.format = format
    }

    private static func imageSource(_ content: ClipContent) -> CGImageSource? {
        for type in [TypeName.png, TypeName.tiff] {
            if let data = content.data(for: type),
               let source = CGImageSourceCreateWithData(data as CFData, nil),
               CGImageSourceGetCount(source) > 0 {
                return source
            }
        }
        return nil
    }

    /// Nil when the content has no image data or the data is not a
    /// readable image.
    public static func inspect(_ content: ClipContent) -> ImageInfo? {
        guard let source = imageSource(content),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        var format = "Image"
        if let identifier = CGImageSourceGetType(source) as String? {
            switch identifier {
            case UTType.png.identifier: format = "PNG"
            case UTType.tiff.identifier: format = "TIFF"
            default: format = UTType(identifier)?.preferredFilenameExtension?.uppercased() ?? "Image"
            }
        }
        return ImageInfo(width: width, height: height, format: format)
    }

    public static func thumbnailPNG(_ content: ClipContent, maxPixel: Int = 56) -> Data? {
        guard let source = imageSource(content) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
