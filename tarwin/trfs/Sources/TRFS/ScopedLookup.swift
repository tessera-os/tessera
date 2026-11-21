// IDs are local to the volume bound to the lookup callback, never kernel
// handles. The namespace read lock (or a stable snapshot) spans the walk.
public enum Entry: Equatable {
  case directory(UInt64)
  case file(UInt64)
  case symlink([UInt8])
  case missing
  case damaged
}
public enum Walk: Equatable {
  case found(UInt64)
  case notFound
  case notDirectory
  case invalid
  case escape
  case loop
  case damaged
}
public func scopedLookup(
  _ root: UInt64, _ relative: [UInt8], _ followLinks: Bool, _ lookup: (UInt64, [UInt8]) -> Entry
) -> Walk {
  if relative.count == 0 { return .found(root) }
  if relative.count > 4096 || relative[0] == 47 { return .invalid }
  // The public LibTessera path grammar is stricter than link contents.
  var component: Int = 0
  for i in 0..<(relative.count + 1) {
    if i == relative.count || relative[i] == 47 {
      let n = i - component
      if n <= 0 || n > 255 { return .invalid }
      if relative[component] == 46 && (n == 1 || (n == 2 && relative[component + 1] == 46)) {
        return .invalid
      }
      component = Int(i) + 1
    } else if relative[i] < 32 {
      return .invalid
    }
  }
  var path = relative
  var parents = [root]
  var depth: Int = 1
  var links: Int = 0
  var at: Int = 0
  while at < path.count {
    let start = at
    while at < path.count && path[at] != 47 { at += 1 }
    let last = at == path.count
    let n = at - start
    at += 1
    if n < 1 || n > 255 { return .invalid }
    if n == 1 && path[start] == 46 { continue }
    if n == 2 && path[start] == 46 && path[start + 1] == 46 {
      if depth == 1 { return .escape }
      depth -= 1
      continue
    }
    var name: [UInt8] = []
    for i in start..<(start + n) {
      if path[i] < 32 { return .invalid }
      name.append(path[i])
    }
    switch lookup(parents[depth - 1], name) {
    case .damaged: return .damaged
    case .missing: return .notFound
    case .file(let id):
      if !last { return .notDirectory }
      return .found(id)
    case .directory(let id):
      if depth == parents.count { parents.append(id) } else { parents[depth] = id }
      depth += 1
    case .symlink(let target):
      if !followLinks { return .notDirectory }
      if links >= 40 { return .loop }
      links += 1
      if target.count == 0 || target.count > 4096 { return .invalid }
      if target[0] == 47 { return .escape }
      if target[target.count - 1] == 47 { return .invalid }
      var expanded = target
      if !last {
        if expanded.count + 1 + path.count - at > 4096 { return .invalid }
        expanded.append(47)
        for i in at..<path.count { expanded.append(path[i]) }
      }
      path = expanded
      at = 0
    }
  }
  return .found(parents[depth - 1])
}
