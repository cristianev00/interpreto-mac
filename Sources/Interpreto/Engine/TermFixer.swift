import Foundation

/// Corrects glossary terms that the speech engine heard as something that sounds the same:
/// English by spelling similarity of the sound-alike words ("a ray" → "array", "Malik" →
/// "malloc"); Chinese by identical pinyin ("指真" → "指针"). Works with every engine.
enum TermFixer {
    static func fix(_ text: String, terms: [String], chinese: Bool) -> String {
        guard !terms.isEmpty, !text.isEmpty else { return text }
        return chinese ? fixChinese(text, terms) : fixEnglish(text, terms)
    }

    // MARK: Chinese: same pinyin, different characters

    private static func pinyin(_ s: String) -> [String] {
        s.map { ch -> String in
            let m = NSMutableString(string: String(ch))
            CFStringTransform(m, nil, kCFStringTransformMandarinLatin, false)
            CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
            return (m as String).lowercased()
        }
    }

    private static func isHan(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { (0x3400...0x9FFF).contains($0.value) }
    }

    /// Grammar characters that are never part of a term (and whose pinyin varies, e.g. 的).
    private static let grammarChars = Set("的了是在和有个这那我你他她它们吗呢吧着过把被就也都很")

    /// Positions covered by a term that already appears exactly: never rewritten.
    private static func protected<T: Equatable>(_ items: [T], _ terms: [[T]]) -> Set<Int> {
        var out = Set<Int>()
        for t in terms where !t.isEmpty && t.count <= items.count {
            for i in 0...(items.count - t.count) where Array(items[i..<(i + t.count)]) == t {
                out.formUnion(i..<(i + t.count))
            }
        }
        return out
    }

    private static func fixChinese(_ text: String, _ terms: [String]) -> String {
        var chars = Array(text)
        for term in terms.sorted(by: { $0.count > $1.count }) {
            let t = Array(term)
            guard t.count >= 2, t.allSatisfy(isHan) else { continue }
            let target = pinyin(term)
            let locked = protected(chars, terms.map { Array($0) })
            var i = 0
            while i + t.count <= chars.count {
                let window = Array(chars[i..<(i + t.count)])
                if window != t, window.allSatisfy(isHan),
                   !window.contains(where: grammarChars.contains) || t.contains(where: grammarChars.contains),
                   !(i..<(i + t.count)).contains(where: locked.contains),
                   pinyin(String(window)) == target {
                    chars.replaceSubrange(i..<(i + t.count), with: t)
                    i += t.count
                } else {
                    i += 1
                }
            }
        }
        return String(chars)
    }

    // MARK: English: words that sound like the term

    /// A rough sound key: lowercase letters, common sound-alike spellings merged.
    private static func soundKey(_ s: String) -> String {
        var k = s.lowercased().filter { $0.isLetter }
        for (a, b) in [("ph", "f"), ("ck", "k"), ("c", "k"), ("q", "k"), ("x", "ks"), ("z", "s"),
                       ("y", "i"), ("ee", "i"), ("ea", "i"), ("oo", "u"), ("ou", "u"), ("w", "u")] {
            k = k.replacingOccurrences(of: a, with: b)
        }
        var out = ""                                    // collapse doubled letters
        for c in k where out.last != c { out.append(c) }
        return out
    }

    private static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var d = Array(0...y.count)
        for i in 1...x.count {
            var prev = d[0]; d[0] = i
            for j in 1...y.count {
                let cur = d[j]
                d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (x[i - 1] == y[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return 1 - Double(d[y.count]) / Double(max(x.count, y.count))
    }

    private static let functionWords: Set<String> = ["a", "an", "the", "of", "to", "in", "on", "at", "and", "or",
                                                     "is", "it", "this", "that", "for", "with", "my", "your", "our"]

    private static func fixEnglish(_ text: String, _ terms: [String]) -> String {
        // Tokens keep their trailing punctuation so the sentence is rebuilt unchanged elsewhere.
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        func core(_ w: String) -> String { w.trimmingCharacters(in: .punctuationCharacters) }
        // Short terms must be heard exactly (too many ordinary words sound alike).
        let candidates = terms.filter { $0.unicodeScalars.allSatisfy(\.isASCII) && soundKey($0).count >= 5 }
            .map { (term: $0, key: soundKey($0), words: $0.split(separator: " ").count) }
        guard !candidates.isEmpty else { return text }
        let locked = protected(words.map { core($0).lowercased() }, terms.map { $0.lowercased().split(separator: " ").map(String.init) })
        var i = 0
        while i < words.count {
            if locked.contains(i) { i += 1; continue }     // already a correct glossary term
            // The best-sounding term at this position (not just the first one that's close).
            var best: (term: String, len: Int, score: Double)?
            for c in candidates {
                for len in max(1, c.words - 1)...(c.words + 1) where i + len <= words.count
                    && !(i..<(i + len)).contains(where: locked.contains) {
                    let window = words[i..<(i + len)].map(core).joined(separator: " ").lowercased()
                    let term = c.term.lowercased()
                    // Don't swallow a little word in front ("a bugger overflow" → "a buffer overflow").
                    let firstWord = window.split(separator: " ").first.map(String.init) ?? ""
                    if len > 1, Self.functionWords.contains(firstWord), !term.hasPrefix(firstWord + " ") { continue }
                    // Already the term, or a form of it (plural, "-ed"…): leave it.
                    if window == term || window.hasPrefix(term) || term.hasPrefix(window) { continue }
                    let key = soundKey(window)
                    // Same first sound, and stricter when the words are split differently
                    // ("bus in" must not become "boolean").
                    guard key.first == c.key.first else { continue }
                    let score = similarity(key, c.key)
                    if score >= (len == c.words ? 0.8 : 0.9), score > (best?.score ?? 0) || (score == best?.score && c.term.count > best!.term.count) {
                        best = (c.term, len, score)
                    }
                }
            }
            if let b = best {
                let last = words[i + b.len - 1]
                let tail = String(last.reversed().prefix { $0.isPunctuation }.reversed())
                let capital = i == 0 && words[i].first?.isUppercase == true
                words.replaceSubrange(i..<(i + b.len), with: [(capital ? b.term.prefix(1).uppercased() + b.term.dropFirst() : b.term) + tail])
            }
            i += 1
        }
        return words.joined(separator: " ")
    }
}

/// Ready-made bilingual glossaries.
enum TermPacks {
    static let cProgramming = """
    pointer = 指针
    null pointer = 空指针
    array = 数组
    variable = 变量
    function = 函数
    parameter = 参数
    argument = 实参
    return value = 返回值
    integer = 整数
    floating point = 浮点数
    character = 字符
    string = 字符串
    struct = 结构体
    union = 联合体
    enum = 枚举
    header file = 头文件
    compiler = 编译器
    linker = 链接器
    library = 库
    macro = 宏
    preprocessor = 预处理器
    loop = 循环
    recursion = 递归
    stack = 栈
    heap = 堆
    memory = 内存
    memory leak = 内存泄漏
    segmentation fault = 段错误
    malloc = malloc
    calloc = calloc
    realloc = realloc
    sizeof = sizeof
    address = 地址
    dereference = 解引用
    ampersand = 取地址符
    operator = 运算符
    bitwise = 按位
    linked list = 链表
    binary tree = 二叉树
    algorithm = 算法
    debugger = 调试器
    syntax error = 语法错误
    runtime error = 运行时错误
    type casting = 类型转换
    scope = 作用域
    global variable = 全局变量
    local variable = 局部变量
    constant = 常量
    buffer overflow = 缓冲区溢出
    file pointer = 文件指针
    standard input = 标准输入
    standard output = 标准输出
    printf = printf
    scanf = scanf
    main function = 主函数
    data type = 数据类型
    byte = 字节
    index = 下标
    boolean = 布尔值
    source code = 源代码
    terminal = 终端
    compile = 编译
    execute = 执行
    statement = 语句
    expression = 表达式
    declaration = 声明
    definition = 定义
    increment = 自增
    decrement = 自减
    """
}
