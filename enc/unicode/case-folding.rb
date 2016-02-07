#!/usr/bin/ruby

# Usage:
#   $ wget http://www.unicode.org/Public/UNIDATA/CaseFolding.txt
#   $ ruby case-folding.rb CaseFolding.txt -o casefold.h
#  or:
#   $ wget http://www.unicode.org/Public/UNIDATA/CaseFolding.txt
#   $ ruby case-folding.rb -m . -o casefold.h

class CaseFolding
  module Util
    module_function

    def hex_seq(v)
      v.map {|i| "0x%04x" % i}.join(", ")
    end

    def print_table_1(dest, data)
      for k, v in data = data.sort
        sk = (Array === k and k.length > 1) ? "{#{hex_seq(k)}}" : ("0x%04x" % k)
        dest.print("  {#{sk}, {#{v.length}, {#{hex_seq(v)}}}},\n")
      end
      data
    end

    def print_table(dest, type, data)
      dest.print("static const #{type}_Type #{type}_Table[] = {\n")
      i = 0
      ret = data.inject([]) do |a, (n, d)|
        dest.print("#define #{n} (*(#{type}_Type (*)[#{d.size}])(#{type}_Table+#{i}))\n")
        i += d.size
        a.concat(print_table_1(dest, d))
      end
      dest.print("};\n\n")
      ret
    end
  end

  include Util

  attr_reader :fold, :fold_locale, :unfold, :unfold_locale

  def load(filename)
    pattern = /([0-9A-F]{4,6}); ([CFT]); ([0-9A-F]{4,6})(?: ([0-9A-F]{4,6}))?(?: ([0-9A-F]{4,6}))?;/

    @fold = fold = {}
    @unfold = unfold = [{}, {}, {}]
    turkic = []

    IO.foreach(filename) do |line|
      next unless res = pattern.match(line)
      ch_from = res[1].to_i(16)

      if res[2] == 'T'
        # Turkic case folding
        turkic << ch_from
        next
      end

      # store folding data
      ch_to = res[3..6].inject([]) do |a, i|
        break a unless i
        a << i.to_i(16)
      end
      fold[ch_from] = ch_to

      # store unfolding data
      i = ch_to.length - 1
      (unfold[i][ch_to] ||= []) << ch_from
    end

    # move locale dependent data to (un)fold_locale
    @fold_locale = fold_locale = {}
    @unfold_locale = unfold_locale = [{}, {}]
    for ch_from in turkic
      key = fold[ch_from]
      i = key.length - 1
      unfold_locale[i][i == 0 ? key[0] : key] = unfold[i].delete(key)
      fold_locale[ch_from] = fold.delete(ch_from)
    end
    self
  end

  def range_check(code)
    "#{code} <= MAX_CODE_VALUE && #{code} >= MIN_CODE_VALUE"
  end

  def lookup_hash(key, type, data)
    hash = "onigenc_unicode_#{key}_hash"
    lookup = "onigenc_unicode_#{key}_lookup"
    arity = Array(data[0][0]).size
    gperf = %W"gperf -7 -k#{[*1..(arity*3)].join(",")} -F,-1 -c -j1 -i1 -t -T -E -C -H #{hash} -N #{lookup} -n"
    argname = arity > 1 ? "codes" : "code"
    argdecl = "const OnigCodePoint #{arity > 1 ? "*": ""}#{argname}"
    n = 7
    m = (1 << n) - 1
    min, max = data.map {|c, *|c}.flatten.minmax
    src = IO.popen(gperf, "r+") {|f|
      f << "short\n%%\n"
      data.each_with_index {|(k, _), i|
        k = Array(k)
        ks = k.map {|j| [(j >> n*2) & m, (j >> n) & m, (j) & m]}.flatten.map {|c| "\\x%.2x" % c}.join("")
        f.printf "\"%s\", ::::/*%s*/ %d\n", ks, k.map {|c| "0x%.4x" % c}.join(","), i
      }
      f << "%%\n"
      f.close_write
      f.read
    }
    src.sub!(/^(#{hash})\s*\(.*?\).*?\n\{\n(.*)^\}/m) {
      name = $1
      body = $2
      body.gsub!(/\(unsigned char\)str\[(\d+)\]/, "bits_#{arity > 1 ? 'at' : 'of'}(#{argname}, \\1)")
      "#{name}(#{argdecl})\n{\n#{body}}"
    }
    src.sub!(/const short *\*\n^(#{lookup})\s*\(.*?\).*?\n\{\n(.*)^\}/m) {
      name = $1
      body = $2
      body.sub!(/\benum\s+\{(\n[ \t]+)/, "\\&MIN_CODE_VALUE = 0x#{min.to_s(16)},\\1""MAX_CODE_VALUE = 0x#{max.to_s(16)},\\1")
      body.gsub!(/(#{hash})\s*\(.*?\)/, "\\1(#{argname})")
      body.gsub!(/\{"",-1}/, "-1")
      body.gsub!(/\{"(?:[^"]|\\")+", *::::(.*)\}/, '\1')
      body.sub!(/(\s+if\s)\(len\b.*\)/) do
        "#$1(" <<
          (arity > 1 ? (0...arity).map {|i| range_check("#{argname}[#{i}]")}.join(" &&\n      ") : range_check(argname)) <<
          ")"
      end
      v = nil
      body.sub!(/(if\s*\(.*MAX_HASH_VALUE.*\)\n([ \t]*))\{(.*?)\n\2\}/m) {
        pre = $1
        indent = $2
        s = $3
        s.sub!(/const char *\* *(\w+)( *= *wordlist\[\w+\]).\w+/, 'short \1 = wordlist[key]')
        v = $1
        s.sub!(/\bif *\(.*\)/, "if (#{v} >= 0 && code#{arity}_equal(#{argname}, #{key}_Table[#{v}].from))")
        "#{pre}{#{s}\n#{indent}}"
      }
      body.sub!(/\b(return\s+&)([^;]+);/, '\1'"#{key}_Table[#{v}].to;")
      "static const #{type} *\n#{name}(#{argdecl})\n{\n#{body}}"
    }
    src
  end

  def display(dest)
    # print the header
    dest.print("/* DO NOT EDIT THIS FILE. */\n")
    dest.print("/* Generated by enc/unicode/case-folding.rb */\n\n")

    # print folding data

    # CaseFold + CaseFold_Locale
    name = "CaseFold_11"
    data = print_table(dest, name, "CaseFold"=>fold, "CaseFold_Locale"=>fold_locale)
    dest.print lookup_hash(name, "CodePointList3", data)

    # print unfolding data

    # CaseUnfold_11 + CaseUnfold_11_Locale
    name = "CaseUnfold_11"
    data = print_table(dest, name, name=>unfold[0], "#{name}_Locale"=>unfold_locale[0])
    dest.print lookup_hash(name, "CodePointList3", data)

    # CaseUnfold_12 + CaseUnfold_12_Locale
    name = "CaseUnfold_12"
    data = print_table(dest, name, name=>unfold[1], "#{name}_Locale"=>unfold_locale[1])
    dest.print lookup_hash(name, "CodePointList2", data)

    # CaseUnfold_13
    name = "CaseUnfold_13"
    data = print_table(dest, name, name=>unfold[2])
    dest.print lookup_hash(name, "CodePointList2", data)
  end

  def self.load(*args)
    new.load(*args)
  end
end

if $0 == __FILE__
  require 'optparse'
  dest = nil
  mapping_directory = nil
  mapping_data = nil
  fold_1 = false
  ARGV.options do |opt|
    opt.banner << " [INPUT]"
    opt.on("--output-file=FILE", "-o", "output to the FILE instead of STDOUT") {|output|
      dest = (output unless output == '-')
    }
    opt.on('--mapping-data-directory', '-m', 'data directory of mapping files') { |directory|
      mapping_directory = directory
    }
    opt.parse!
    abort(opt.to_s) if ARGV.size > 1
  end
  if mapping_directory
    if ARGV[0]
      warn "Either specify directory or individual file, but not both."
      exit
    end
    filename = File.expand_path("CaseFolding.txt", mapping_directory)
  end
  filename ||= ARGV[0] || 'CaseFolding.txt'

  data = CaseFolding.load(filename)
  if dest
    open(dest, "wb") do |f|
      data.display(f)
    end
  else
    data.display(STDOUT)
  end
end
