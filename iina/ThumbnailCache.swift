//
//  ThumbnailCache.swift
//  iina
//
//  Created by lhc on 14/6/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

fileprivate let subsystem = Logger.makeSubsystem("thumbcache")

extension URL {
    var isDirectory: Bool {
       (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}

class ThumbnailCache: NSObject {
  private typealias CacheVersion = UInt8
  private typealias FileSize = UInt64
  private typealias FileTimestamp = Int64

  private static let version: CacheVersion = 2
  
  private static let sizeofMetadata = MemoryLayout<CacheVersion>.size + MemoryLayout<FileSize>.size + MemoryLayout<FileTimestamp>.size

  private static let imageProperties: [NSBitmapImageRep.PropertyKey: Any] = [
    .compressionFactor: 0.75
  ]
  
  private static func log(_ message: String, level: Logger.Level = .debug) {
    Logger.log(message, level: level, subsystem: subsystem)
  }

  static func fileExists(forName name: String) -> Bool {
    return FileManager.default.fileExists(atPath: urlFor(name).path)
  }
  
  static func get_cache_file_from_server(video_url: URL) async -> URL? {
    if #available(macOS 12.0, *) {
      
      let video_components = URLComponents(url: video_url, resolvingAgainstBaseURL: false)!
      
      if let video_host = video_components.host, video_host.starts(with: "files."), video_components.scheme == "https" {
        var thumb_components = URLComponents()
        thumb_components.scheme = "https"
        thumb_components.host = video_host.replacingOccurrences(of: "files.", with: "thumbs.")
        thumb_components.user = video_components.user
        thumb_components.password = video_components.password
        thumb_components.path = "/"
        thumb_components.queryItems = [
          URLQueryItem(name: "file_path", value: video_components.path),
          URLQueryItem(name: "thumb_width", value: String(Preference.integer(for: .thumbnailWidth)))
        ]
        thumb_components.percentEncodedQuery = thumb_components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        let url = thumb_components.url!
        log("Querrying '\(url)' ...")
        
        let request = URLRequest(url: url)
        do {
          let (downloadedURL, urlResponse) = try await URLSession.shared.download(for: request) as! (URL, HTTPURLResponse)
          if urlResponse.statusCode == 200 {
            log("Got HTTP response 200")
            return downloadedURL
          }
          else {
            log("Got HTTP response \(urlResponse.statusCode)", level: .error)
            return nil
          }
        }
        catch let error {
          log("HTTP client error: "  + error.localizedDescription, level: .error)
          return nil
        }
      }
      else {
        log("HTTP host '\(video_components.host ?? "ERROR")' not supported for thumbnails")
        return nil
      }
    }
    else {
      log("macOS too old for HTTP requests", level: .warning)
      return nil
    }
  }
  
  static let MD5_SIZE = 1000000; // 1MB
  
  static func MD5(data: Data) -> String {
    let digestLength = Int(CC_MD5_DIGEST_LENGTH)
    let md5Buffer = UnsafeMutablePointer<CUnsignedChar>.allocate(capacity: digestLength)
    
    _ = data.withUnsafeBytes {
      CC_MD5($0.baseAddress, CC_LONG(data.count), md5Buffer)
    }
    
    let output = NSMutableString(capacity: Int(CC_MD5_DIGEST_LENGTH * 2))
    for i in 0..<digestLength {
        output.appendFormat("%02x", md5Buffer[i])
    }
    let hash = NSString(format: output) as String
    log("File hash = \(hash)")
    
    return hash
  }
  
  static func MD5_1MB(forVideo videoPath: URL) -> String {
    let fh = try! FileHandle(forReadingFrom: videoPath)
    let bytes = fh.readData(ofLength: MD5_SIZE)
    
    return MD5(data: bytes)
  }

  static func MD5_1MB_http(forVideo videoPath: URL) async -> String? {
    let urlSession = URLSession.shared
    var request = URLRequest(url: videoPath)
    request.setValue("bytes=0-\(MD5_SIZE - 1)", forHTTPHeaderField: "Range")
    
    if #available(macOS 12.0, *) {
      let (downloadedURL, _) = try! await urlSession.download(for: request) as (URL, URLResponse)
      
      let fh = try! FileHandle(forReadingFrom: downloadedURL)
      let bytes = fh.readData(ofLength: MD5_SIZE)
      
      return MD5(data: bytes)
    }
    else {
      log("macOS too old for HTTP requests", level: .warning)
      return nil
    }
  }
  
  static func fileIsCached(forVideo videoPath: URL?) -> Bool {
    let md5 = MD5_1MB(forVideo: videoPath!)
    
    // Check in the cache
    if self.fileExists(forName: md5) {
      guard (try? FileHandle(forReadingFrom: urlFor(md5))) != nil else {
        log("Cannot open cache file.", level: .error)
        return false
      }
      return true
    }
    return false
  }

  /// Write thumbnail cache to file.
  /// This method is expected to be called when the file doesn't exist.
  static func write(_ thumbnails: [FFThumbnail], forVideo videoPath: URL?) {
    log("Writing thumbnail cache...")
    
    let md5 = MD5_1MB(forVideo: videoPath!)
    //log("write(): MD5 = \(md5)")

    let maxCacheSize = Preference.integer(for: .maxThumbnailPreviewCacheSize) * FloatingPointByteCountFormatter.PrefixFactor.mi.rawValue
    if maxCacheSize == 0 {
      return
    } else if CacheManager.shared.getCacheSize() > maxCacheSize {
      CacheManager.shared.clearOldCache()
    }

    let pathURL = urlFor(md5)
    guard FileManager.default.createFile(atPath: pathURL.path, contents: nil, attributes: nil) else {
      log("Cannot create file.", level: .error)
      return
    }
    guard let file = try? FileHandle(forWritingTo: pathURL) else {
      log("Cannot write to file.", level: .error)
      return
    }

    // version
    let versionData = Data(bytesOf: version)
    file.write(versionData)

    guard let fileAttr = try? FileManager.default.attributesOfItem(atPath: videoPath!.path) else {
      log("Cannot get video file attributes", level: .error)
      return
    }

    // file size
    guard let fileSize = fileAttr[.size] as? FileSize else {
      log("Cannot get video file size", level: .error)
      return
    }
    let fileSizeData = Data(bytesOf: fileSize)
    file.write(fileSizeData)

    // modified date
    guard let fileModifiedDate = fileAttr[.modificationDate] as? Date else {
      log("Cannot get video file modification date", level: .error)
      return
    }
    let fileTimestamp = FileTimestamp(fileModifiedDate.timeIntervalSince1970)
    let fileModificationDateData = Data(bytesOf: fileTimestamp)
    file.write(fileModificationDateData)

    // data blocks
    for tb in thumbnails {
      let timestampData = Data(bytesOf: tb.realTime)
      guard let tiffData = tb.image?.tiffRepresentation else {
        log("Cannot generate tiff data.", level: .error)
        return
      }
      guard let jpegData = NSBitmapImageRep(data: tiffData)?.representation(using: .jpeg, properties: imageProperties) else {
        log("Cannot generate jpeg data.", level: .error)
        return
      }
      let blockLength = Int64(timestampData.count + jpegData.count)
      let blockLengthData = Data(bytesOf: blockLength)
      file.write(blockLengthData)
      file.write(timestampData)
      file.write(jpegData)
    }

    CacheManager.shared.needsRefresh = true
    log("Finished writing thumbnail cache.")
  }
  
  static func read_cache_file(pathURL: URL) -> [FFThumbnail]? {
    guard let file = try? FileHandle(forReadingFrom: pathURL) else {
      log("Cannot open file.", level: .error)
      return nil
    }
    log("Reading from \(pathURL.path)")

    var result: [FFThumbnail] = []

    // get file length
    file.seekToEndOfFile()
    let eof = file.offsetInFile

    // skip metadata
    file.seek(toFileOffset: UInt64(sizeofMetadata))

    // data blocks
    while file.offsetInFile != eof {
      // length and timestamp
      guard let blockLength = file.read(type: Int64.self),
            let timestamp = file.read(type: Double.self) else {
        log("Cannot read image header. Cache file will be deleted.", level: .warning)
        file.closeFile()
        deleteCacheFile(at: pathURL)
        return nil
      }
      // jpeg
      let jpegData = file.readData(ofLength: Int(blockLength) - MemoryLayout.size(ofValue: timestamp))
      guard let image = NSImage(data: jpegData) else {
        log("Cannot read image. Cache file will be deleted.", level: .warning)
        file.closeFile()
        deleteCacheFile(at: pathURL)
        return nil
      }
      // construct
      let tb = FFThumbnail()
      tb.realTime = timestamp
      tb.image = image
      result.append(tb)
    }

    file.closeFile()
    log("Finished reading thumbnail cache, \(result.count) in total")
    return result
  }

  /// Read thumbnail cache to file.
  /// This method is expected to be called when the file exists.
  static func read(forVideo videoPath: URL?) -> [FFThumbnail]? {
    log("Reading thumbnail cache...")
    
    let md5 = MD5_1MB(forVideo: videoPath!)
    let pathURL = urlFor(md5)
    return read_cache_file(pathURL: pathURL)
  }

  private static func deleteCacheFile(at pathURL: URL) {
    // try deleting corrupted cache
    do {
      try FileManager.default.removeItem(at: pathURL)
    } catch {
      log("Cannot delete corrupted cache.", level: .error)
    }
  }

  private static func urlFor(_ name: String) -> URL {
    return Utility.thumbnailCacheURL.appendingPathComponent(name)
  }

  private var thumbnails: [FFThumbnail] = []
  private var currentPath : URL? = nil
  
  func generateOnly(path basePath: URL) {
    if basePath.isDirectory {
      let fileManager = FileManager.default
      let contents = try? fileManager.contentsOfDirectory(at: basePath, includingPropertiesForKeys: nil)
      for path in contents! {
        generateOnly(path: path)
      }
    }
    else {
      if !Utility.playableFileExt.contains(basePath.pathExtension.lowercased()) {
        Logger.log("Skipping unplayable file: '\(basePath.lastPathComponent)'", subsystem: subsystem)
        return
      }
      if ThumbnailCache.fileIsCached(forVideo: basePath) {
        Logger.log("Thumbnail cache already exists: '\(basePath.lastPathComponent)'", subsystem: subsystem)
        return
      }
      Logger.log("Generating thumbnail cache: '\(basePath.lastPathComponent)' ...", subsystem: subsystem)
      currentPath = basePath
      let ffmpegController = FFmpegController()
      ffmpegController.delegate = self
      ffmpegController.generateThumbnail(forFile: basePath.path,
                                         thumbWidth:Int32(Preference.integer(for: .thumbnailWidth)))
      while currentPath != nil {
        usleep(1000)
      }
    }
  }
}

extension ThumbnailCache: FFmpegControllerDelegate {
  func didUpdate(_ thumbnails: [FFThumbnail]?, forFile filename: String, withProgress progress: Int) {
    Logger.log("Got new thumbnails, progress \(progress)", subsystem: subsystem)
  }

  func didGenerate(_ thumbnails: [FFThumbnail], forFile filename: String, succeeded: Bool) {
    Logger.log("Got all thumbnails, succeeded=\(succeeded)", subsystem: subsystem)
    if succeeded {
      ThumbnailCache.write(thumbnails, forVideo: currentPath!)
    }
    currentPath = nil
  }
}
