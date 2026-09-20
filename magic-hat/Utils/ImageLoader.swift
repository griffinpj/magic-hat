//
//  ImageLoader.swift
//  magic-hat
//
//  Two-tier card-image cache: an in-memory NSCache for instant reuse and a
//  disk cache under Caches/ so images survive relaunches without bloating
//  the SwiftData store or iCloud backups. Downloads are deduplicated so a
//  card scrolling into view repeatedly only fetches once.
//

import Foundation
import UIKit
import CryptoKit

actor ImageLoader {
    static let shared = ImageLoader()

    private let memory = NSCache<NSString, UIImage>()
    private let http = HTTPClient()
    private let fm = FileManager.default
    private let cacheDir: URL

    /// In-flight downloads keyed by URL string, to coalesce duplicate requests.
    private var inFlight: [String: Task<UIImage, Error>] = [:]

    init() {
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDir = caches.appendingPathComponent("CardImages", isDirectory: true)
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        memory.countLimit = 400
    }

    /// Returns a cached image without touching the network, if present.
    func cachedImage(for urlString: String) -> UIImage? {
        if let img = memory.object(forKey: urlString as NSString) { return img }
        let file = fileURL(for: urlString)
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            memory.setObject(img, forKey: urlString as NSString)
            return img
        }
        return nil
    }

    /// Loads an image from memory, disk, or network (in that order).
    func image(for urlString: String) async throws -> UIImage {
        if let cached = cachedImage(for: urlString) { return cached }

        if let existing = inFlight[urlString] {
            return try await existing.value
        }

        let task = Task<UIImage, Error> { [http] in
            guard let url = URL(string: urlString) else { throw HTTPError.badURL }
            // Card images are on the general (10/sec) limit family.
            let data = try await http.requestData(url: url, rateLimit: .other)
            guard let img = UIImage(data: data) else { throw HTTPError.badURL }
            return img
        }
        inFlight[urlString] = task

        do {
            let img = try await task.value
            inFlight[urlString] = nil
            memory.setObject(img, forKey: urlString as NSString)
            persist(img, for: urlString)
            return img
        } catch {
            inFlight[urlString] = nil
            throw error
        }
    }

    private func persist(_ image: UIImage, for urlString: String) {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        try? data.write(to: fileURL(for: urlString), options: .atomic)
    }

    private func fileURL(for urlString: String) -> URL {
        // Stable (cross-launch), filesystem-safe name derived from the URL.
        let digest = SHA256.hash(data: Data(urlString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent("\(name).jpg")
    }
}
