//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO

/// Errors that may be raised by the `HTTPServerProtocolUpgrader`.
public enum HTTPServerUpgradeErrors: Error {
    case invalidHTTPOrdering
}

/// User events that may be fired by the `HTTPServerProtocolUpgrader`.
public enum HTTPServerUpgradeEvents {
    /// Fired when HTTP upgrade has completed and the
    /// `HTTPServerProtocolUpgrader` is about to remove itself from the
    /// `ChannelPipeline`.
    case upgradeComplete(toProtocol: String, upgradeRequest: HTTPRequestHead)
}


/// An object that implements `ProtocolUpgrader` knows how to handle HTTP upgrade to
/// a protocol.
public protocol HTTPServerProtocolUpgrader {
    /// The protocol this upgrader knows how to support.
    var supportedProtocol: String { get }

    /// All the header fields the protocol needs in the request to successfully upgrade. These header fields
    /// will be provided to the handler when it is asked to handle the upgrade. They will also be validated
    ///  against the inbound request's Connection header field.
    var requiredUpgradeHeaders: [String] { get }

    /// Builds the upgrade response headers. Should return any headers that need to be supplied to the client
    /// in the 101 Switching Protocols response. If upgrade cannot proceed for any reason, this function should
    /// throw.
    func buildUpgradeResponse(upgradeRequest: HTTPRequestHead, initialResponseHeaders: HTTPHeaders) throws -> HTTPHeaders

    /// Called when the upgrade response has been flushed. At this time it is safe to mutate the channel pipeline
    /// to add whatever channel handlers are required. Until the returned `EventLoopFuture` succeeds, all received
    /// data will be buffered.
    func upgrade(context: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void>
}

/// A server-side channel handler that receives HTTP requests and optionally performs a HTTP-upgrade.
/// Removes itself from the channel pipeline after the first inbound request on the connection, regardless of
/// whether the upgrade succeeded or not.
///
/// This handler behaves a bit differently from its Netty counterpart because it does not allow upgrade
/// on any request but the first on a connection. This is primarily to handle clients that pipeline: it's
/// sufficiently difficult to ensure that the upgrade happens at a safe time while dealing with pipelined
/// requests that we choose to punt on it entirely and not allow it. As it happens this is mostly fine:
/// the odds of someone needing to upgrade midway through the lifetime of a connection are very low.
public class HTTPServerUpgradeHandler: ChannelInboundHandler, RemovableChannelHandler {
    public typealias InboundIn = HTTPServerRequestPart
    public typealias InboundOut = HTTPServerRequestPart
    public typealias OutboundOut = HTTPServerResponsePart

    private let upgraders: [String: HTTPServerProtocolUpgrader]
    private let upgradeCompletionHandler: (ChannelHandlerContext) -> Void

    private let httpEncoder: HTTPResponseEncoder?
    private let extraHTTPHandlers: [RemovableChannelHandler]

    /// Whether we've already seen the first request.
    private var seenFirstRequest = false

    /// The closure that should be invoked when the end of the upgrade request is received if any.
    private var upgrade: (() -> Void)?
    private var receivedMessages: [NIOAny] = []

    /// Create a `HTTPServerUpgradeHandler`.
    ///
    /// - Parameter upgraders: All `HTTPServerProtocolUpgrader` objects that this pipeline will be able
    ///     to use to handle HTTP upgrade.
    /// - Parameter httpEncoder: The `HTTPResponseEncoder` encoding responses from this handler and which will
    ///     be removed from the pipeline once the upgrade response is sent. This is used to ensure
    ///     that the pipeline will be in a clean state after upgrade.
    /// - Parameter extraHTTPHandlers: Any other handlers that are directly related to handling HTTP. At the very least
    ///     this should include the `HTTPDecoder`, but should also include any other handler that cannot tolerate
    ///     receiving non-HTTP data.
    /// - Parameter upgradeCompletionHandler: A block that will be fired when HTTP upgrade is complete.
    public init(upgraders: [HTTPServerProtocolUpgrader], httpEncoder: HTTPResponseEncoder, extraHTTPHandlers: [RemovableChannelHandler], upgradeCompletionHandler: @escaping (ChannelHandlerContext) -> Void) {
        var upgraderMap = [String: HTTPServerProtocolUpgrader]()
        for upgrader in upgraders {
            upgraderMap[upgrader.supportedProtocol.lowercased()] = upgrader
        }
        self.upgraders = upgraderMap
        self.upgradeCompletionHandler = upgradeCompletionHandler
        self.httpEncoder = httpEncoder
        self.extraHTTPHandlers = extraHTTPHandlers
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !self.seenFirstRequest else {
            // We're waiting for upgrade to complete: buffer this data.
            self.receivedMessages.append(data)
            return
        }

        let requestPart = unwrapInboundIn(data)

        if let upgrade = self.upgrade {
            switch requestPart {
            case .head:
                context.fireErrorCaught(HTTPServerUpgradeErrors.invalidHTTPOrdering)
                notUpgrading(context: context, data: data)
                return
            case .body:
                // TODO: In the future way may want to add some API to also allow special handling of the body during the
                //       upgrade. For now just ignore it.
                break
            case .end:
                self.seenFirstRequest = true

                // The request is complete now trigger the upgrade.
                upgrade()
            }
        } else {
            // We should decide if we're going to upgrade based on the first request header: if we aren't upgrading,
            // by the time the body comes in we should be out of the pipeline. That means that if we don't think we're
            // upgrading, the only thing we should see is a request head. Anything else in an error.
            guard case .head(let request) = requestPart else {
                context.fireErrorCaught(HTTPServerUpgradeErrors.invalidHTTPOrdering)
                notUpgrading(context: context, data: data)
                return
            }
            
            // Ok, we have a HTTP request. Check if it's an upgrade. If it's not, we want to pass it on and remove ourselves
            // from the channel pipeline.
            let requestedProtocols = request.headers[canonicalForm: "upgrade"]
            guard requestedProtocols.count > 0 else {
                notUpgrading(context: context, data: data)
                return
            }
            
            // Cool, this is an upgrade! Let's go.
            if let upgrade = handleUpgrade(context: context, request: request, requestedProtocols: requestedProtocols) {
                self.upgrade = upgrade
            } else {
                notUpgrading(context: context, data: data)
            }
        }
    }

    /// The core of the upgrade handling logic.
    private func handleUpgrade(context: ChannelHandlerContext, request: HTTPRequestHead, requestedProtocols: [String]) -> (() -> Void)? {
        let connectionHeader = Set(request.headers[canonicalForm: "connection"].map { $0.lowercased() })
        let allHeaderNames = Set(request.headers.map { $0.name.lowercased() })

        for proto in requestedProtocols {
            guard let upgrader = upgraders[proto.lowercased()] else {
                continue
            }

            let requiredHeaders = Set(upgrader.requiredUpgradeHeaders.map { $0.lowercased() })
            guard requiredHeaders.isSubset(of: allHeaderNames) && requiredHeaders.isSubset(of: connectionHeader) else {
                continue
            }

            var responseHeaders = buildUpgradeHeaders(protocol: proto)
            do {
                responseHeaders = try upgrader.buildUpgradeResponse(upgradeRequest: request, initialResponseHeaders: responseHeaders)
            } catch {
                // We should fire this error so the user can log it, but keep going.
                context.fireErrorCaught(error)
                continue
            }
           
            return {
                // Before we finish the upgrade we have to remove the HTTPDecoder and any other non-Encoder HTTP
                // handlers from the pipeline, to prevent them parsing any more data. We'll buffer the data until
                // that completes.
                // While there are a lot of Futures involved here it's quite possible that all of this code will
                // actually complete synchronously: we just want to program for the possibility that it won't.
                // Once that's done, we send the upgrade response, then remove the HTTP encoder, then call the
                // internal handler, then call the user code, and then finally when the user code is done we do
                // our final cleanup steps, namely we replay the received data we buffered in the meantime and
                // then remove ourselves from the pipeline.
                self.removeExtraHandlers(context: context).flatMap {
                    self.sendUpgradeResponse(context: context, upgradeRequest: request, responseHeaders: responseHeaders)
                }.flatMap {
                    self.removeHandler(context: context, handler: self.httpEncoder)
                }.map {
                    self.upgradeCompletionHandler(context)
                }.flatMap {
                    upgrader.upgrade(context: context, upgradeRequest: request)
                }.map {
                    context.fireUserInboundEventTriggered(HTTPServerUpgradeEvents.upgradeComplete(toProtocol: proto, upgradeRequest: request))
                        
                    self.upgrade = nil
                        
                    // We unbuffer any buffered data here and, if we sent any,
                    // we also fire readComplete.
                    let bufferedMessages = self.receivedMessages
                    self.receivedMessages = []
                    bufferedMessages.forEach { context.fireChannelRead($0) }
                    if bufferedMessages.count > 0 {
                        context.fireChannelReadComplete()
                    }
                }.whenComplete { (_: Result<Void, Error>) in
                    context.pipeline.removeHandler(context: context, promise: nil)
                }
            }
        }

        return nil
    }

    /// Sends the 101 Switching Protocols response for the pipeline.
    private func sendUpgradeResponse(context: ChannelHandlerContext, upgradeRequest: HTTPRequestHead, responseHeaders: HTTPHeaders) -> EventLoopFuture<Void> {
        var response = HTTPResponseHead(version: HTTPVersion(major: 1, minor: 1), status: .switchingProtocols)
        response.headers = responseHeaders
        return context.writeAndFlush(wrapOutboundOut(HTTPServerResponsePart.head(response)))
    }

    /// Called when we know we're not upgrading. Passes the data on and then removes this object from the pipeline.
    private func notUpgrading(context: ChannelHandlerContext, data: NIOAny) {
        assert(self.receivedMessages.count == 0)
        context.fireChannelRead(data)
        context.pipeline.removeHandler(context: context, promise: nil)
    }

    /// Builds the initial mandatory HTTP headers for HTTP ugprade responses.
    private func buildUpgradeHeaders(`protocol`: String) -> HTTPHeaders {
        return HTTPHeaders([("connection", "upgrade"), ("upgrade", `protocol`)])
    }

    /// Removes the given channel handler from the channel pipeline.
    private func removeHandler(context: ChannelHandlerContext, handler: RemovableChannelHandler?) -> EventLoopFuture<Void> {
        if let handler = handler {
            return context.pipeline.removeHandler(handler)
        } else {
            return context.eventLoop.makeSucceededFuture(())
        }
    }

    /// Removes any extra HTTP-related handlers from the channel pipeline.
    private func removeExtraHandlers(context: ChannelHandlerContext) -> EventLoopFuture<Void> {
        guard self.extraHTTPHandlers.count > 0 else {
            return context.eventLoop.makeSucceededFuture(())
        }

        return .andAllSucceed(self.extraHTTPHandlers.map { context.pipeline.removeHandler($0) },
                              on: context.eventLoop)
    }
}
