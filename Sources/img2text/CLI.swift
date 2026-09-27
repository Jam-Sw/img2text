import Foundation

let usage = """
usage: img2text IMAGE [-m MODE] [-w N] [-d DITHER] [-s 0..1] [-t N] [-c CHARS] [-r DEG] [--invert] [--no-color] [--all]
       img2text [--gui] [IMAGE]    (no image: opens the app)

Render image as text.



  -m, --mode MODE     ascii|half|quad|sextant|braille|pixel (default braille)
  -w, --width N       output width in characters (default 128)
  -d, --dither D      none|floyd|atkinson|bayer (default floyd)
  -s, --strength X    dither strength 0..1 (default 1)
  -t, --threshold N   ink cutoff 0..255 (default 128)
  -c, --chars S       ascii ramp, lightest to darkest (default " .:-=+*#%@")
  -r, --rotate DEG    rotate clockwise: 0, 90, 180, 270
      --invert        swap ink/paper (for light-on-dark images)
      --no-color      plain text; colour is on by default when stdout is a terminal
      --no-dither     same as -d none
      --all           render every mode for comparison
      --gui           open the macOS window instead of printing

GIFs play in terminal (Ctrl-C to stop);
the first frame is used.
"""

struct Args {
    var image: String?
    var options = Options()
    var all = false
    var gui = false
    var colorSet = false

    init(_ argv: [String]) throws {
        var it = argv.makeIterator()
        func value(_ flag: String) throws -> String {
            guard let v = it.next() else { throw ArgError("\(flag) needs a value") }
            return v
        }
        func int(_ flag: String) throws -> Int {
            let v = try value(flag)
            guard let n = Int(v) else { throw ArgError("\(flag): not a number: \(v)") }
            return n
        }
        while let a = it.next() {
            switch a {
            case "-m", "--mode":
                let v = try value(a)
                guard let m = Mode(rawValue: v) else { throw ArgError("unknown mode: \(v)") }
                options.mode = m
            case "-w", "--width":
                let n = try int(a)
                guard (1...maxWidth).contains(n) else { throw ArgError("--width must be 1..\(maxWidth)") }
                options.width = n
            case "-t", "--threshold":
                let n = try int(a)
                guard (0...255).contains(n) else { throw ArgError("--threshold must be 0..255") }
                options.threshold = n
            case "-d", "--dither":
                let v = try value(a)
                guard let d = Dither(rawValue: v) else { throw ArgError("unknown dither: \(v)") }
                options.dither = d
            case "-s", "--strength":
                let v = try value(a)
                guard let x = Double(v), (0...1).contains(x) else { throw ArgError("--strength must be 0..1") }
                options.strength = x
            case "-c", "--chars": options.chars = try value(a)
            case "-r", "--rotate":
                let n = try int(a)
                guard [0, 90, 180, 270].contains(n) else { throw ArgError("--rotate must be 0, 90, 180 or 270") }
                options.rotate = n
            case "--invert": options.invert = true
            case "--no-color": options.color = false; colorSet = true
            case "--color": options.color = true; colorSet = true
            case "--no-dither": options.dither = .none
            case "--all": all = true
            case "--gui": gui = true
            case "-h", "--help": print(usage); exit(0)
            default:
                if a.hasPrefix("-psn_") { continue }
                if a.hasPrefix("-") { throw ArgError("unknown flag: \(a)") }
                guard image == nil else { throw ArgError("only one image allowed") }
                image = a
            }
        }
        if image == nil { gui = true }
    }
}

struct ArgError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func runCLI(_ a: Args) throws {
    var args = a
    if !a.colorSet && isatty(STDOUT_FILENO) == 0 { args.options.color = false }
    let emit: (Rendering) -> String = args.options.color ? { $0.ansi } : { $0.plain }
    let source = try Source(args.image!)
    func frame(_ i: Int, _ o: Options) throws -> String {
        guard let r = source.render(i, o) else { throw RenderError.cannotLoad(args.image!) }
        return emit(r)
    }
    if source.count > 1 && !args.all {
        signal(SIGINT) { _ in
            let reset = "\u{1B}[0m\u{1B}[?25h\n"
            write(STDOUT_FILENO, reset, reset.utf8.count)
            _exit(130)
        }
        print("\u{1B}[2J\u{1B}[?25l", terminator: "")
        while true {
            for i in 0..<source.count {
                let start = Date()
                print("\u{1B}[H" + (try frame(i, args.options)))
                fflush(stdout)
                Thread.sleep(forTimeInterval: max(0, source.delays[i] - Date().timeIntervalSince(start)))
            }
        }
    }
    if args.all {
        for m in Mode.allCases {
            var o = args.options
            o.mode = m
            print("\n== \(m.rawValue) (\(m.cell.w)x\(m.cell.h) px/char) ==\n")
            print(try frame(0, o))
        }
    } else {
        print(try frame(0, args.options))
    }
}
