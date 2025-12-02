import Foundation

/// Result of a successful match.
///
/// - `path`: the original path string matched.
/// - `params`: a dictionary of captured parameters. For named parameters the
///   captured value is a `String`. For splat (wildcard) captures the value is
///   an array of `String` segments.
public struct MatchResult {
	public let path: String
	public let params: [String: Any]

	/// Create a `MatchResult`.
	public init(path: String, params: [String: Any]) {
		self.path = path
		self.params = params
	}
}

// Internal representation of a pattern segment.
fileprivate enum SegmentKind {
	/// A literal path segment, e.g. `"users"`.
	case literal(String)
	/// A named parameter, e.g. `:id`.
	case param(String)
	/// A splat (wildcard) parameter that captures remaining segments, e.g. `*splat`.
	case splat(String)
}

fileprivate struct Segment {
	/// The kind of segment.
	let kind: SegmentKind
	/// Whether this segment is optional (from a `{...}` group).
	let optional: Bool
}

/// Parse a match pattern into an array of `Segment` values.
///
/// Supported syntax:
/// - Named parameters: `:name` (matches a single segment and captures its value)
/// - Optional segments: wrapped in braces with a leading slash, e.g. `{/:id}`
///   (the entire segment is optional)
/// - Splat/wildcard: `*name` (captures zero or more remaining segments into an array)
fileprivate func parsePattern(_ pattern: String) -> [Segment] {
	// Split segments by '/', but keep brace groups together so constructs like
	// "users{/:id}" are parsed as the literal "users" followed by an optional param.
	var segmentsRaw: [String] = []
	var curr = ""
	var inBraces = false
	for ch in pattern {
		if ch == "{" { inBraces = true; curr.append(ch); continue }
		if ch == "}" { inBraces = false; curr.append(ch); continue }
		if ch == "/" && !inBraces {
			if !curr.isEmpty { segmentsRaw.append(curr) }
			curr = ""
		} else {
			curr.append(ch)
		}
	}
	if !curr.isEmpty { segmentsRaw.append(curr) }

	var result: [Segment] = []
	for raw in segmentsRaw {
		// A raw segment may be one of:
		// - ":name"
		// - "*splat"
		// - "literal"
		// - "prefix{/:id}suffix" (we handle braces inside the raw string)
		if let open = raw.firstIndex(of: "{") , let close = raw.firstIndex(of: "}") {
			// Content before the brace is a literal segment.
			let prefix = String(raw[..<open])
			if !prefix.isEmpty {
				result.append(Segment(kind: .literal(prefix), optional: false))
			}
			// Extract the content inside braces and drop a leading '/'.
			let braceContent = String(raw[raw.index(after: open)..<close])
			var inner = braceContent
			if inner.hasPrefix("/") { inner.removeFirst() }
			// Inner content may be a param, splat or literal.
			if inner.hasPrefix(":") {
				let name = String(inner.dropFirst())
				result.append(Segment(kind: .param(name), optional: true))
			} else if inner.hasPrefix("*") {
				let name = String(inner.dropFirst())
				result.append(Segment(kind: .splat(name), optional: true))
			} else {
				result.append(Segment(kind: .literal(inner), optional: true))
			}
			// Anything after the brace is another literal.
			let after = String(raw[raw.index(after: close)...])
			if !after.isEmpty {
				result.append(Segment(kind: .literal(after), optional: false))
			}
		} else {
			// No braces — treat the entire raw segment.
			if raw.hasPrefix(":" ) {
				let name = String(raw.dropFirst())
				result.append(Segment(kind: .param(name), optional: false))
			} else if raw.hasPrefix("*") {
				let name = String(raw.dropFirst())
				result.append(Segment(kind: .splat(name), optional: false))
			} else {
				result.append(Segment(kind: .literal(raw), optional: false))
			}
		}
	}
	return result
}

/// Compile a pattern into a matcher closure.
///
/// The returned closure accepts a path `String` and returns a `MatchResult?`.
/// If the path matches the compiled pattern the function returns a `MatchResult`
/// containing the original `path` and a `params` dictionary with captured values.
///
/// Examples:
///
///     let fn = PathTo.match("/:foo/:bar")
///     fn("/test/route") // -> MatchResult with params["foo"] == "test"
///
///     let fn = PathTo.match("/*splat")
///     fn("/a/b") // -> params["splat"] == ["a", "b"]
///
/// Namespace for the path matcher. Use `PathTo.match(...)` to compile a pattern
/// into a matcher closure.
public enum PathTo {
	/// Compile a pattern into a matcher closure.
	///
	/// See `match(_:)` documentation above for examples and behavior.
	public static func match(_ pattern: String) -> (String) -> MatchResult? {
		let segments = parsePattern(pattern)
		func attemptMatch(path: String) -> MatchResult? {
			// Split the incoming path into segments (ignoring leading/trailing '/')
			let pathSegs = path.split(separator: "/", omittingEmptySubsequences: true).map { String($0) }

			// Recursive matcher with simple backtracking to support optional segments.
			func recurse(_ pi: Int, _ si: Int, _ params: [String: Any]) -> ([String: Any]?) {
				var params = params
				// If we've consumed all pattern segments, success only if path also consumed.
				if pi == segments.count {
					return (si == pathSegs.count) ? params : nil
				}

				let seg = segments[pi]
				switch seg.kind {
				case .splat(let name):
					// Splat captures the remainder of the path. For simplicity we require
					// splat to be the last pattern segment.
					if pi != segments.count - 1 {
						return nil
					}
					let rest = Array(pathSegs[si..<pathSegs.count])
					params[name] = rest
					return (pathSegs.count >= si) ? params : nil

				case .literal(let lit):
					// If there is no path segment available, only succeed if literal is optional.
					if si >= pathSegs.count {
						if seg.optional {
							return recurse(pi+1, si, params)
						}
						return nil
					}
					if pathSegs[si] == lit {
						return recurse(pi+1, si+1, params)
					} else {
						if seg.optional {
							return recurse(pi+1, si, params)
						}
						return nil
					}

				case .param(let name):
					if si >= pathSegs.count {
						if seg.optional {
							return recurse(pi+1, si, params)
						}
						return nil
					}
					// For optional params we try both consuming and skipping the segment.
					if seg.optional {
						var p2 = params
						p2[name] = pathSegs[si]
						if let res = recurse(pi+1, si+1, p2) { return res }
						return recurse(pi+1, si, params)
					} else {
						params[name] = pathSegs[si]
						return recurse(pi+1, si+1, params)
					}
				}
			}

			if let finalParams = recurse(0, 0, [:]) {
				return MatchResult(path: path, params: finalParams)
			}
			return nil
		}

		return attemptMatch
	}
}

