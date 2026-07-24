module Every
  # A pinch of ANSI, applied honestly. Color is a hint, never load-bearing:
  # every colored string is still readable with the codes stripped, and we
  # strip them whenever the destination isn't an interactive terminal (a pipe,
  # a file, CI), when NO_COLOR is set (https://no-color.org), or when TERM
  # says the terminal is dumb. That keeps `every list | grep ok` and CI logs
  # clean while still feeling alive at a real prompt.
  module Color
    module_function

    CODES = { green: 32, red: 31, yellow: 33, dim: 2, bold: 1 }.freeze

    # Paint +text+ with +name+ (a key of CODES), but only if +io+ is a TTY we're
    # allowed to color. Defaults to $stdout since that's where most output goes;
    # pass io: $stderr for error lines.
    def paint(name, text, io: $stdout)
      return text.to_s unless enabled?(io)
      "\e[#{CODES.fetch(name)}m#{text}\e[0m"
    end

    # Classic `def`s (not endless `def x = ...`): macOS ships system Ruby 2.6,
    # the floor this gem supports, and endless methods are a 3.0+ syntax.
    def green(text, **kw)  ; paint(:green, text, **kw)  ; end
    def red(text, **kw)    ; paint(:red, text, **kw)    ; end
    def yellow(text, **kw) ; paint(:yellow, text, **kw) ; end
    def dim(text, **kw)    ; paint(:dim, text, **kw)    ; end
    def bold(text, **kw)   ; paint(:bold, text, **kw)   ; end

    def enabled?(io = $stdout)
      io.respond_to?(:tty?) && io.tty? &&
        !ENV.key?("NO_COLOR") &&
        ENV["TERM"] != "dumb"
    end
  end
end
