/// Windows command-line rules, as `CommandLineToArgvW` and `ShellExecute` apply them.
public enum WindowsCommandLine {
    /// Splits a command line into arguments.
    ///
    /// The program name (first argument) is special: a quoted name runs to the next
    /// quote with no escapes. Later arguments follow the MSVC rules: 2n backslashes
    /// before a quote give n backslashes and toggle quoting, 2n+1 give n backslashes
    /// and a literal quote, `""` inside quotes is a literal quote, and other
    /// backslashes are literal.
    public static func split(_ commandLine: String) -> [String] {
        let chars = Array(commandLine)
        var args: [String] = []
        var i = 0
        func skipSpaces() { while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 } }

        skipSpaces()
        guard i < chars.count else { return [] }
        var program = ""
        if chars[i] == "\"" {
            i += 1
            while i < chars.count, chars[i] != "\"" { program.append(chars[i]); i += 1 }
            if i < chars.count { i += 1 }
        } else {
            while i < chars.count, chars[i] != " ", chars[i] != "\t" { program.append(chars[i]); i += 1 }
        }
        args.append(program)

        while true {
            skipSpaces()
            guard i < chars.count else { break }
            var arg = ""
            var quoted = false
            while i < chars.count {
                let c = chars[i]
                if !quoted, c == " " || c == "\t" { break }
                if c == "\\" {
                    var count = 0
                    while i < chars.count, chars[i] == "\\" { count += 1; i += 1 }
                    if i < chars.count, chars[i] == "\"" {
                        arg += String(repeating: "\\", count: count / 2)
                        if count % 2 == 1 { arg.append("\""); i += 1 }
                    } else {
                        arg += String(repeating: "\\", count: count)
                    }
                    continue
                }
                if c == "\"" {
                    if quoted, i + 1 < chars.count, chars[i + 1] == "\"" {
                        arg.append("\""); i += 2; continue
                    }
                    quoted.toggle(); i += 1; continue
                }
                arg.append(c); i += 1
            }
            args.append(arg)
        }
        return args
    }

    /// Expands a registered `shell\open\command` template for `argument` (a URL or
    /// a document path), the way Wine's ShellExecute does.
    ///
    /// The template is split first and placeholders are replaced inside each
    /// argument, so the URL always stays a single argument. `%1`, `%L` and `%l` are
    /// the argument, `%*` (the remaining parameters) is empty, `%%` is `%`. With no
    /// `%1`/`%L`/`%*` in the template the argument is appended, as Wine does.
    /// With `argument` nil (opening the program itself), placeholder-only
    /// arguments are dropped.
    public static func expand(template: String, argument: String?) -> [String] {
        var found = false
        var result: [String] = []
        for (index, part) in split(template).enumerated() {
            if index == 0 { result.append(part); continue }
            var out = ""
            var onlyPlaceholders = true
            var chars = part.makeIterator()
            while let c = chars.next() {
                guard c == "%" else { out.append(c); onlyPlaceholders = false; continue }
                guard let n = chars.next() else { out.append("%"); onlyPlaceholders = false; break }
                switch n {
                case "1", "L", "l":
                    found = true
                    if let argument { out += argument }
                case "*":
                    found = true
                case "%":
                    out.append("%"); onlyPlaceholders = false
                default:
                    out.append("%"); out.append(n); onlyPlaceholders = false
                }
            }
            if onlyPlaceholders && out.isEmpty { continue }
            result.append(out)
        }
        if !found, let argument { result.append(argument) }
        return result
    }
}
