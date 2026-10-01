import Foundation

nonisolated(unsafe) var testCount = 0
nonisolated(unsafe) var testFailures = 0

func expect(_ condition: Bool, _ name: String, file: String = #filePath, line: Int = #line) {
    testCount += 1
    if !condition { testFailures += 1; print("FAIL: \(name) (\(file):\(line))") }
}
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String, file: String = #filePath, line: Int = #line) {
    testCount += 1
    if actual != expected { testFailures += 1; print("FAIL: \(name) — got \(actual), expected \(expected) (\(file):\(line))") }
}
func expectNil<T>(_ value: T?, _ name: String, file: String = #filePath, line: Int = #line) {
    testCount += 1
    if let value { testFailures += 1; print("FAIL: \(name) — expected nil, got \(value) (\(file):\(line))") }
}
/// Compares multi-line text and reports the first line that differs.
///
/// `expectEqual` would print two whole documents on one line and leave the reader to diff
/// forty lines of JSON by eye, which is how a frozen-format failure gets skimmed past.
func expectEqualText(_ actual: String?, _ expected: String, _ name: String, file: String = #filePath, line: Int = #line) {
    testCount += 1
    guard let actual else {
        testFailures += 1
        print("FAIL: \(name) — no text produced (\(file):\(line))")
        return
    }
    guard actual != expected else { return }
    testFailures += 1
    let actualLines = actual.components(separatedBy: "\n")
    let expectedLines = expected.components(separatedBy: "\n")
    var index = 0
    while index < min(actualLines.count, expectedLines.count), actualLines[index] == expectedLines[index] {
        index += 1
    }
    let end = "<end of text>"
    print("FAIL: \(name) — first difference on line \(index + 1) of \(expectedLines.count) (\(file):\(line))")
    print("   expected: \(index < expectedLines.count ? expectedLines[index] : end)")
    print("   actual:   \(index < actualLines.count ? actualLines[index] : end)")
}

/// Changes a file's or directory's permissions, for the cases that are about what happens
/// when one cannot be read or written. Shared: two suites test that path.
func setPermissions(_ mode: Int, on url: URL) {
    try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

func failTest(_ name: String, file: String = #filePath, line: Int = #line) {
    testCount += 1; testFailures += 1; print("FAIL: \(name) (\(file):\(line))")
}
func expectThrows<E: Error & Equatable>(_ expected: E, _ name: String, file: String = #filePath, line: Int = #line, _ body: () throws -> Void) {
    testCount += 1
    do { try body(); testFailures += 1; print("FAIL: \(name) — expected \(expected), nothing thrown (\(file):\(line))") }
    catch let e as E where e == expected { }
    catch { testFailures += 1; print("FAIL: \(name) — expected \(expected), got \(error) (\(file):\(line))") }
}
func expectNoThrow(_ name: String, file: String = #filePath, line: Int = #line, _ body: () throws -> Void) {
    testCount += 1
    do { try body() } catch { testFailures += 1; print("FAIL: \(name) — threw \(error) (\(file):\(line))") }
}
/// Runs one area and prints how many checks it contributed, so a suite that silently
/// stops being called (or stops asserting) shows up as a shrinking number.
func runArea(_ name: String, _ body: () -> Void) {
    let before = testCount
    print("-- \(name) --")
    body()
    print("   \(testCount - before) checks")
}
func finishTests() -> Never {
    print("\(testCount) checks, \(testFailures) failures")
    exit(testFailures == 0 ? 0 : 1)
}
