import SandglassAppCore
import SandglassCore
import Foundation

/// A video a search engine plays inside its own results page is the video, not the search.
func runEmbeddedVideoTests() {
    testAGoogleVideoOverlayIsReadAsTheYouTubeVideo()
    testADuckDuckGoVideoOverlayIsReadAsItsSource()
    testAnOrdinarySearchStaysASearch()
    testTheYouTubeGroupClaimsTheOverlay()
    testTheBlockPageSendsTheTabBackToTheSearch()
}

private let googleOverlay =
    "https://www.google.com/search?q=nebelniek+mlg&udm=vids&biw=1512"
    + "#fpstate=ive&ip=1&vld=cid:666d58b5,vid:oweLRy_EvmM,st:0"

private func testAGoogleVideoOverlayIsReadAsTheYouTubeVideo() {
    expectEqual(
        EmbeddedVideo.source(of: googleOverlay), "https://www.youtube.com/watch?v=oweLRy_EvmM",
        "the vid in the fragment is the YouTube video, case kept"
    )
    expectEqual(
        BrowserAddress.page(from: googleOverlay), "youtube.com/watch",
        "and the browser reading becomes the page the rules know"
    )
    expectEqual(
        EmbeddedVideo.source(
            of: "https://www.google.de/search?q=x#fpstate=ive&vld=cid:1,vid:abcdefghijk"
        ),
        "https://www.youtube.com/watch?v=abcdefghijk",
        "on every country's Google, with the id last in the fragment"
    )
}

private func testADuckDuckGoVideoOverlayIsReadAsItsSource() {
    let address = "https://duckduckgo.com/?q=lofi&iax=videos&ia=videos"
        + "&iai=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3DjfKfPfyJRdk"
    expectEqual(
        EmbeddedVideo.source(of: address), "https://www.youtube.com/watch?v=jfKfPfyJRdk",
        "iai carries the video's own address"
    )
    expectEqual(BrowserAddress.page(from: address), "youtube.com/watch", "and is read as it")
}

private func testAnOrdinarySearchStaysASearch() {
    let unchanged = [
        "https://www.google.com/search?q=nebelniek+mlg&udm=vids": "the video results list itself",
        "https://www.google.com/search?q=x#vid:short": "an id that is not YouTube's shape",
        "https://www.google.com/maps#vid:oweLRy_EvmM": "a Google page that is not search",
        "https://notgoogle.com/search#vid:oweLRy_EvmM": "a host that only looks like Google",
        "https://duckduckgo.com/?q=x&iai=javascript:alert(1)": "an iai that is not a web address",
        "https://www.youtube.com/watch?v=abc": "an address that is already the video",
    ]
    for (address, name) in unchanged {
        expectNil(EmbeddedVideo.source(of: address), name)
    }
    expectEqual(
        BrowserAddress.page(from: "https://www.google.com/search?q=x&udm=vids"), "google.com/search",
        "so browsing results is not watching"
    )
}

private func testTheYouTubeGroupClaimsTheOverlay() {
    let target = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    let config = Config(version: 1, targets: [target], groupSettings: [target.groupID: .standard])
    let page = BrowserAddress.page(from: googleOverlay) ?? ""
    expectEqual(
        WebResolver.match(url: page, in: config)?.groupID, target.groupID, "the YouTube group owns it"
    )
    let search = BrowserAddress.page(from: "https://www.google.com/search?q=x") ?? ""
    expectNil(WebResolver.match(url: search, in: config), "and a plain search belongs to nobody")
}

private func testTheBlockPageSendsTheTabBackToTheSearch() {
    expectEqual(
        BlockPage.opening(from: googleOverlay, target: "youtube.com/watch"), googleOverlay,
        "after an unlock the tab comes home to the search, overlay and all"
    )
}
