import Foundation

/// Builds the JavaScript wrapper injected into attached webviews at document start.
///
/// The wrapper defines `window.<bridgeObjectName>` with `track`/`page` methods, wraps
/// each call in an envelope — minting `messageId` and stamping the point-in-time page
/// facts at call time — and posts it as a JSON string through the native channel object
/// under `nativeChannelName`. `messageId` must be minted here, on the producer side: an
/// ID assigned at receipt would give two deliveries of the same message two different
/// IDs, defeating dedup.
///
/// On Android the platform injects the channel object (`postMessage` out, `onmessage`
/// in); WebKit has no equivalent, so the wrapper defines the shim itself — posting via
/// `webkit.messageHandlers` and exposing a settable `onmessage` — keeping the
/// page-visible surface identical across platforms. Native replies are delivered by
/// evaluating a call that fires `onmessage`.
///
/// - The wrapper self-checks `location.origin` against the allowlist and defines nothing
///   on non-allowlisted pages. Unlike Android there is no platform-side origin scoping on
///   the message handler, so this check plus the native frame-origin check carry the
///   security model together.
/// - `properties` may be an object or a JSON string (parsed by the wrapper). A string
///   that fails to parse is forwarded as-is so the native validator rejects it with
///   `malformed_payload` and the producer gets an error reply rather than silence.
/// - Calls made before the native channel exists (or with a blank name) are dropped.
internal enum BridgeWrapperScript {

    static let defaultBridgeObjectName = "metarouterBridge"

    /// Name of the `WKScriptMessageHandler` channel the wrapper posts through
    /// (`webkit.messageHandlers.<name>.postMessage`), and of the `window` shim object
    /// whose `onmessage` receives native replies.
    static let nativeChannelName = "__metaRouterNativeChannel"

    static let wrapperVersion = "1.0.0"

    enum BuildError: Error, Equatable {
        case emptyAllowedOrigins
        case invalidBridgeObjectName
    }

    static func build(
        allowedOrigins: [String],
        bridgeObjectName: String = defaultBridgeObjectName
    ) throws -> String {
        guard !allowedOrigins.isEmpty else {
            throw BuildError.emptyAllowedOrigins
        }
        guard bridgeObjectName.range(
            of: "^[A-Za-z_$][A-Za-z0-9_$]*$",
            options: .regularExpression
        ) != nil else {
            throw BuildError.invalidBridgeObjectName
        }

        // JSON-encoding the allowlist is what keeps a hostile origin string from breaking
        // out of the script — quotes arrive escaped. withoutEscapingSlashes matches the
        // other platforms' wire form so the embedded array is byte-identical.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let originsData = try encoder.encode(allowedOrigins)
        let originsJsArray = String(decoding: originsData, as: UTF8.self)

        return """
        (function() {
          'use strict';
          var ALLOWED_ORIGINS = \(originsJsArray);
          if (ALLOWED_ORIGINS.indexOf(location.origin) === -1) { return; }
          if (window.\(bridgeObjectName)) { return; }

          if (!window.\(nativeChannelName)) {
            window.\(nativeChannelName) = {
              onmessage: null,
              postMessage: function(data) {
                if (window.webkit && window.webkit.messageHandlers &&
                    window.webkit.messageHandlers.\(nativeChannelName)) {
                  window.webkit.messageHandlers.\(nativeChannelName).postMessage(data);
                }
              }
            };
          }

          function uuidv4() {
            if (window.crypto && window.crypto.getRandomValues) {
              var b = new Uint8Array(16);
              window.crypto.getRandomValues(b);
              b[6] = (b[6] & 0x0f) | 0x40;
              b[8] = (b[8] & 0x3f) | 0x80;
              var h = [];
              for (var i = 0; i < 16; i++) { h.push((b[i] + 0x100).toString(16).slice(1)); }
              return h.slice(0, 4).join('') + '-' + h.slice(4, 6).join('') + '-' +
                     h.slice(6, 8).join('') + '-' + h.slice(8, 10).join('') + '-' +
                     h.slice(10, 16).join('');
            }
            return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
              var r = Math.random() * 16 | 0;
              return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
            });
          }

          function post(type, name, properties) {
            if (typeof name !== 'string' || name.length === 0) { return; }
            var props = properties;
            if (typeof props === 'string') {
              try { props = JSON.parse(props); } catch (e) { /* forward as-is; native rejects */ }
            }
            if (props === undefined || props === null) { props = {}; }
            var envelope = {
              version: 1,
              messageId: uuidv4(),
              type: type,
              name: name,
              properties: props,
              sentAt: new Date().toISOString(),
              page: {
                url: location.href,
                path: location.pathname,
                search: location.search,
                title: document.title,
                referrer: document.referrer
              },
              source: { producer: 'wrapper', wrapperVersion: '\(wrapperVersion)' }
            };
            var channel = window.\(nativeChannelName);
            if (channel && typeof channel.postMessage === 'function') {
              channel.postMessage(JSON.stringify(envelope));
            }
          }

          window.\(bridgeObjectName) = {
            track: function(name, properties) { post('track', name, properties); },
            page: function(name, properties) { post('page', name, properties); }
          };
        })();
        """
    }
}
