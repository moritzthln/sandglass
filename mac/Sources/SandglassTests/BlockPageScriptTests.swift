import Foundation
import JavaScriptCore

// The one piece of the block page's script that is arithmetic: the address its password button
// links to. It is this page again with a fresh `ask` nonce, so every press is a new question —
// and a link that keeps the previous nonce beside the new one, or drops the leading `?`, is a
// press the app never sees.
//
// Run in JavaScriptCore against the function as it ships, cut out of `Resources/block.html` by its
// markers, so the test cannot pass against a copy that has drifted from the page.

func runBlockPageScriptTests() {
    guard let withAsk = loadWithAsk() else {
        failTest("the block page's withAsk function could not be loaded from block.html")
        return
    }
    expectEqual(
        withAsk.call(withArguments: ["?target=x&mode=password", "n2"])?.toString(),
        "?target=x&mode=password&ask=n2",
        "a first press adds the nonce at the end"
    )
    expectEqual(
        withAsk.call(withArguments: ["?target=x&mode=password&ask=n1", "n2"])?.toString(),
        "?target=x&mode=password&ask=n2",
        "a second press replaces the nonce rather than adding one"
    )
    expectEqual(
        withAsk.call(withArguments: ["?ask=n1&target=x", "n2"])?.toString(),
        "?target=x&ask=n2",
        "and so it does when the nonce is the first parameter, which the old pattern missed"
    )
    expectEqual(
        withAsk.call(withArguments: ["", "n2"])?.toString(),
        "?ask=n2",
        "an empty query still makes a well-formed one"
    )
    expectEqual(
        withAsk.call(withArguments: ["?target=x&task=keep", "n2"])?.toString(),
        "?target=x&task=keep&ask=n2",
        "a parameter that merely ends in \"ask\" is left alone"
    )
}

private func loadWithAsk() -> JSValue? {
    let html = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/block.html")
    guard let source = try? String(contentsOf: html, encoding: .utf8),
          let start = source.range(of: "/* withAsk:begin */"),
          let end = source.range(of: "/* withAsk:end */", range: start.upperBound..<source.endIndex),
          let context = JSContext()
    else { return nil }
    context.evaluateScript(String(source[start.upperBound..<end.lowerBound]))
    let function = context.objectForKeyedSubscript("withAsk")
    return function?.isUndefined == false ? function : nil
}
