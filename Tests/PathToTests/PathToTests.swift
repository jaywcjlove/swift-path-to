import Testing
@testable import PathTo

@Test func testWildcardExamples() {
    let fn = PathTo.match("/*splat")
    let r2 = fn("/bar/baz")
    #expect(r2 != nil)
    #expect(r2?.params["splat"] as? [String] == ["bar", "baz"])
}

@Test func testParametersExamples() {
    let fn = PathTo.match("/:foo/:bar")
    let r1 = fn("/test/route")
    #expect(r1 != nil)
    #expect(r1?.path == "/test/route")
    #expect(r1?.params["foo"] as? String == "test")
    #expect(r1?.params["bar"] as? String == "route")
    
    
    let fn2 = PathTo.match("/:\"foo\"/:bar")
    let r2 = fn2("/test/route")
    #expect(r2?.params["\"foo\""] as? String == "test")
}

@Test func testOptionalExamples() {
    let fn = PathTo.match("/users{/:id}/delete")
    let r3 = fn("/users/delete")
    #expect(r3 != nil)
    #expect(r3?.path == "/users/delete")
    #expect(r3?.params["id"] == nil)

    let r4 = fn("/users/123/delete")
    #expect(r4 != nil)
    #expect(r4?.params["id"] as? String == "123")
}

@Test func invalidTestExample() {
    let fn3 = PathTo.match("/users{/:id/delete")
    let r3 = fn3("/users/delete")
    #expect(r3 == nil)
}
