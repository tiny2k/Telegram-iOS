import UIKit
import Accelerate
import Display
import TelegramCore

private func generateHistogram(cgImage: CGImage) -> ([[vImagePixelCount]], Int)? {
    var sourceBuffer = vImage_Buffer()
    defer {
        free(sourceBuffer.data)
    }
    
    var cgImageFormat = vImage_CGImageFormat(
        bitsPerComponent: UInt32(cgImage.bitsPerComponent),
        bitsPerPixel: UInt32(cgImage.bitsPerPixel),
        colorSpace: Unmanaged.passUnretained(cgImage.colorSpace!),
        bitmapInfo: cgImage.bitmapInfo,
        version: 0,
        decode: nil,
        renderingIntent: .defaultIntent
    )
    
    let noFlags = vImage_Flags(kvImageNoFlags)
    var error = vImageBuffer_InitWithCGImage(&sourceBuffer, &cgImageFormat, nil, cgImage, noFlags)
    assert(error == kvImageNoError)
    
    if cgImage.alphaInfo == .premultipliedLast {
        error = vImageUnpremultiplyData_RGBA8888(&sourceBuffer, &sourceBuffer, noFlags)
    } else if cgImage.alphaInfo == .premultipliedFirst {
        error = vImageUnpremultiplyData_ARGB8888(&sourceBuffer, &sourceBuffer, noFlags)
    }
    assert(error == kvImageNoError)
    
    let histogramBins = (0...3).map { _ in
        return [vImagePixelCount](repeating: 0, count: 256)
    }
    var mutableHistogram: [UnsafeMutablePointer<vImagePixelCount>?] = histogramBins.map {
        return UnsafeMutablePointer<vImagePixelCount>(mutating: $0)
    }
    error = vImageHistogramCalculation_ARGB8888(&sourceBuffer, &mutableHistogram, noFlags)
    assert(error == kvImageNoError)
    
    let alphaBinIndex = [.last, .premultipliedLast].contains(cgImage.alphaInfo) ? 3 : 0
    return (histogramBins, alphaBinIndex)
}

func imageHasTransparency(_ cgImage: CGImage) -> Bool {
    guard cgImage.bitsPerComponent == 8, cgImage.bitsPerPixel == 32 else {
        return false
    }
    guard [.first, .last, .premultipliedFirst, .premultipliedLast].contains(cgImage.alphaInfo) else {
        return false
    }
    if let (histogramBins, alphaBinIndex) = generateHistogram(cgImage: cgImage) {
        for i in 0 ..< 255 {
            if histogramBins[alphaBinIndex][i] > 0 {
                return true
            }
        }
    }
    return false
}

private func scaledContext(_ cgImage: CGImage, maxSize: CGSize) -> DrawingContext {
    var size = CGSize(width: cgImage.width, height: cgImage.height)
    if (size.width > maxSize.width && size.height > maxSize.height) {
        size = size.aspectFilled(maxSize)
    }
    let context = DrawingContext(size: size, scale: 1.0, clear: true)
    context.withFlippedContext { context in
        context.draw(cgImage, in: CGRect(origin: CGPoint(), size: size))
    }
    return context
}

func imageRequiresInversion(_ cgImage: CGImage) -> Bool {
    guard cgImage.bitsPerComponent == 8, cgImage.bitsPerPixel == 32 else {
        return false
    }
    guard [.first, .last, .premultipliedFirst, .premultipliedLast].contains(cgImage.alphaInfo) else {
        return false
    }
    
    let context = scaledContext(cgImage, maxSize: CGSize(width: 128.0, height: 128.0))
    if let cgImage = context.generateImage()?.cgImage, let (histogramBins, alphaBinIndex) = generateHistogram(cgImage: cgImage) {
        var hasAlpha = false
        for i in 0 ..< 255 {
            if histogramBins[alphaBinIndex][i] > 0 {
                hasAlpha = true
            }
        }
        guard hasAlpha else {
            return false
        }
        
        var matching: Int = 0
        var total: Int = 0
        for y in 0 ..< Int(context.size.height) {
            for x in 0 ..< Int(context.size.width) {
                var hue: CGFloat = 0.0
                var saturation: CGFloat = 0.0
                var brightness: CGFloat = 0.0
                var alpha: CGFloat = 0.0
                context.colorAt(CGPoint(x: x, y: y)).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
                
                if alpha > 0.0 {
                    total += 1
                    if saturation < 0.1 && brightness < 0.25 {
                        matching += 1
                    }
                }
            }
        }
        return CGFloat(matching) / CGFloat(total) > 0.85
    }
    return false
}
