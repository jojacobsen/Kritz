import AppKit
import Vision

/// On-device text and QR recognition. No network, no cloud – everything runs via Apple's
/// Vision / Core Image frameworks locally.
enum Recognition {

    /// OCR: recognises text in the image and returns it joined by newlines (empty if none).
    static func recognizeText(in cgImage: CGImage, completion: @escaping (String) -> Void) {
        let request = VNRecognizeTextRequest { request, _ in
            let observations = request.results as? [VNRecognizedTextObservation] ?? []
            let text = observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            DispatchQueue.main.async { completion(text) }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        DispatchQueue.global(qos: .userInitiated).async {
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                DispatchQueue.main.async { completion("") }
            }
        }
    }

    /// Decodes the first QR code found in the image, or nil.
    static func readQRCode(in cgImage: CGImage) -> String? {
        let ciImage = CIImage(cgImage: cgImage)
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        for feature in detector?.features(in: ciImage) ?? [] {
            if let qr = feature as? CIQRCodeFeature, let message = qr.messageString, !message.isEmpty {
                return message
            }
        }
        return nil
    }
}
