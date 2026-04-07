//
//  ThumbnailController.swift
//
//
//  Created by kintan on 12/27/23.
//

import AVFoundation
import CoreGraphics
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Libswscale
#if canImport(UIKit)
import UIKit
#endif
public struct FFThumbnail {
    public let image: UIImage
    public let time: TimeInterval
}

public protocol ThumbnailControllerDelegate: AnyObject {
    func didUpdate(thumbnails: [FFThumbnail], forFile file: URL, withProgress: Int)
}

public class ThumbnailController {
    public weak var delegate: ThumbnailControllerDelegate?
    private let thumbnailCount: Int
    private let formatContextOptions: [String: Any]?
    public private(set) var debugLogs: [String] = []
    public init(thumbnailCount: Int = 100, formatContextOptions: [String: Any]? = nil) {
        self.thumbnailCount = thumbnailCount
        self.formatContextOptions = formatContextOptions
    }

    public func generateThumbnail(for url: URL, thumbWidth: Int32 = 240) async throws -> [FFThumbnail] {
        try await Task {
            try getPeeks(for: url, thumbWidth: thumbWidth)
        }.value
    }

    // MARK: - Fallback formats for MIME/extension mismatch
    // FFmpeg HTTP MIME bonus (+30) can override content-based probing (e.g., server
    // returns video/x-matroska for MPEG-TS data). No flag to disable it — retry with forced format.
    private static let fallbackFormats = ["mpegts", "matroska,webm", "avi", "mov,mp4,m4a,3gp,3g2,mj2"]

    private func getPeeks(for url: URL, thumbWidth: Int32 = 240) throws -> [FFThumbnail] {
        let urlString: String
        if url.isFileURL {
            urlString = url.path
        } else {
            urlString = url.absoluteString
        }
        var thumbnails = [FFThumbnail]()
        var formatCtx = avformat_alloc_context()
        defer {
            avformat_close_input(&formatCtx)
        }
        var avOptions = formatContextOptions?.avOptions

        var result = avformat_open_input(&formatCtx, urlString, nil, &avOptions)
        av_dict_free(&avOptions)

        if result != 0 {
            for fmtName in ThumbnailController.fallbackFormats {
                let forcedFmt = av_find_input_format(fmtName)
                guard forcedFmt != nil else { continue }
                avformat_close_input(&formatCtx)
                formatCtx = avformat_alloc_context()
                var retryOptions = formatContextOptions?.avOptions
                result = avformat_open_input(&formatCtx, urlString, forcedFmt, &retryOptions)
                av_dict_free(&retryOptions)
                if result == 0 {
                    debugLogs = ["Fallback format '\(fmtName)' succeeded"]
                    break
                }
            }
        }

        guard result == 0, let formatCtx else {
            throw NSError(errorCode: .formatOpenInput, avErrorCode: result)
        }
        formatCtx.pointee.flags |= AVFMT_FLAG_GENPTS
        result = avformat_find_stream_info(formatCtx, nil)
        guard result == 0 else {
            throw NSError(errorCode: .formatFindStreamInfo, avErrorCode: result)
        }
        var videoStreamIndex = -1
        for i in 0 ..< Int32(formatCtx.pointee.nb_streams) {
            if formatCtx.pointee.streams[Int(i)]?.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                videoStreamIndex = Int(i)
                break
            }
        }
        guard videoStreamIndex >= 0, let videoStream = formatCtx.pointee.streams[videoStreamIndex] else {
            throw NSError(description: "No video stream")
        }

        let videoAvgFrameRate = videoStream.pointee.avg_frame_rate
        if videoAvgFrameRate.den == 0 || av_q2d(videoAvgFrameRate) == 0 {
            throw NSError(description: "Avg frame rate = 0, ignore")
        }
        var codecContext = try videoStream.pointee.codecpar.pointee.createContext(options: nil)
        defer {
            avcodec_close(codecContext)
            var codecContext: UnsafeMutablePointer<AVCodecContext>? = codecContext
            avcodec_free_context(&codecContext)
        }
        let thumbHeight = thumbWidth * codecContext.pointee.height / codecContext.pointee.width
        // sws_scale: any format (including 10-bit HDR) → RGB24 for CGImage
        var swsCtx: OpaquePointer?
        var rgbFrame = av_frame_alloc()
        defer {
            sws_freeContext(swsCtx)
            av_frame_free(&rgbFrame)
        }
        // 因为是针对视频流来进行seek。所以不能直接取formatCtx的duration
        let duration = av_rescale_q(formatCtx.pointee.duration,
                                    AVRational(num: 1, den: AV_TIME_BASE), videoStream.pointee.time_base)
        let interval = duration / Int64(thumbnailCount)
        var packet = AVPacket()
        let timeBase = Timebase(videoStream.pointee.time_base)
        var frame = av_frame_alloc()
        defer {
            av_frame_free(&frame)
        }
        guard let frame else {
            throw NSError(description: "can not av_frame_alloc")
        }
        for i in 0 ..< thumbnailCount {
            let seek_pos = interval * Int64(i) + videoStream.pointee.start_time
            avcodec_flush_buffers(codecContext)
            result = av_seek_frame(formatCtx, Int32(videoStreamIndex), seek_pos, AVSEEK_FLAG_BACKWARD)
            guard result == 0 else {
                return thumbnails
            }
            avcodec_flush_buffers(codecContext)
            while av_read_frame(formatCtx, &packet) >= 0 {
                if packet.stream_index == Int32(videoStreamIndex) {
                    if avcodec_send_packet(codecContext, &packet) < 0 {
                        break
                    }
                    let ret = avcodec_receive_frame(codecContext, frame)
                    if ret < 0 {
                        if ret == -EAGAIN {
                            continue
                        } else {
                            break
                        }
                    }
                    let srcFormat = AVPixelFormat(rawValue: frame.pointee.format)
                    let srcW = frame.pointee.width
                    let srcH = frame.pointee.height
                    if swsCtx == nil {
                        swsCtx = sws_getContext(srcW, srcH, srcFormat,
                                                thumbWidth, thumbHeight, AV_PIX_FMT_RGB24,
                                                SWS_FAST_BILINEAR, nil, nil, nil)
                    }
                    guard let swsCtx else { break }
                    if rgbFrame == nil { rgbFrame = av_frame_alloc() }
                    guard let rgbFrame else { break }
                    rgbFrame.pointee.format = AV_PIX_FMT_RGB24.rawValue
                    rgbFrame.pointee.width = thumbWidth
                    rgbFrame.pointee.height = thumbHeight
                    if rgbFrame.pointee.data.0 == nil {
                        av_frame_get_buffer(rgbFrame, 0)
                    }
                    var srcData = Array(tuple: frame.pointee.data).map { UnsafePointer<UInt8>($0) }
                    var srcLinesize = Array(tuple: frame.pointee.linesize)
                    var dstData = Array(tuple: rgbFrame.pointee.data).map { UnsafeMutablePointer<UInt8>($0) }
                    var dstLinesize = Array(tuple: rgbFrame.pointee.linesize)
                    sws_scale(swsCtx, &srcData, &srcLinesize, 0, srcH, &dstData, &dstLinesize)
                    let image: UIImage? = rgbFrame.pointee.data.0.flatMap { ptr in
                        CGImage.make(rgbData: ptr, linesize: Int(rgbFrame.pointee.linesize.0),
                                     width: Int(thumbWidth), height: Int(thumbHeight))
                            .map { UIImage(cgImage: $0) }
                    }
                    let currentTimeStamp = frame.pointee.best_effort_timestamp
                    if let image {
                        let thumbnail = FFThumbnail(image: image, time: timeBase.cmtime(for: currentTimeStamp).seconds)
                        thumbnails.append(thumbnail)
                        delegate?.didUpdate(thumbnails: thumbnails, forFile: url, withProgress: i)
                    }
                    break
                }
            }
        }
        av_packet_unref(&packet)
        return thumbnails
    }
}
