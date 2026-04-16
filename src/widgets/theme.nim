## Theme -- color theme for uirelays.
##
## Since everything is text (SynEdit), there is one theme type.

import ../uirelays/screen

type
  TokenClass* {.pure.} = enum
    None, Whitespace, DecNumber, BinNumber, HexNumber,
    OctNumber, FloatNumber, Identifier, Keyword, StringLit,
    LongStringLit, CharLit, Backticks,
    EscapeSequence,
    Operator, Punctuation, Comment, LongComment, RegularExpression,
    TagStart, TagStandalone, TagEnd, Key, Value, RawData, Assembler,
    Preprocessor, Directive, Command, Rule, Link, Label,
    Reference, Text, Other, Green, Yellow, Red

  Theme* = object
    fg*: array[TokenClass, Color]   ## per-token foreground colors
    bg*: Color                      ## editor background
    selBg*: Color                   ## selection background
    bracketBg*: Color               ## bracket match background
    cursorColor*: Color             ## cursor bar color
    lineNumColor*: Color            ## line number foreground
    markerBg*: Color                ## default marker highlight background
    scrollBarColor*: Color          ## scrollbar grip
    scrollBarActiveColor*: Color    ## scrollbar grip while dragging
    scrollTrackColor*: Color        ## scrollbar track background

proc catppuccinMocha*(): Theme =
  let fg = color(205, 214, 244)
  for tc in TokenClass:
    result.fg[tc] = fg
  result.fg[TokenClass.Keyword] = color(203, 166, 247)     # mauve
  result.fg[TokenClass.StringLit] = color(166, 227, 161)   # green
  result.fg[TokenClass.LongStringLit] = color(166, 227, 161)
  result.fg[TokenClass.CharLit] = color(166, 227, 161)
  result.fg[TokenClass.RawData] = color(166, 227, 161)
  result.fg[TokenClass.Comment] = color(108, 112, 134)     # overlay0
  result.fg[TokenClass.LongComment] = color(108, 112, 134)
  result.fg[TokenClass.DecNumber] = color(250, 179, 135)   # peach
  result.fg[TokenClass.BinNumber] = color(250, 179, 135)
  result.fg[TokenClass.HexNumber] = color(250, 179, 135)
  result.fg[TokenClass.OctNumber] = color(250, 179, 135)
  result.fg[TokenClass.FloatNumber] = color(250, 179, 135)
  result.fg[TokenClass.Operator] = color(137, 180, 250)    # blue
  result.fg[TokenClass.Punctuation] = color(147, 153, 178) # subtext0
  result.fg[TokenClass.EscapeSequence] = color(245, 194, 231) # pink
  result.fg[TokenClass.Preprocessor] = color(203, 166, 247)
  result.fg[TokenClass.Identifier] = fg
  result.fg[TokenClass.Green] = color(166, 227, 161)
  result.fg[TokenClass.Yellow] = color(249, 226, 175)
  result.fg[TokenClass.Red] = color(243, 139, 168)
  result.bg = color(30, 30, 46)
  result.selBg = color(88, 91, 112)
  result.bracketBg = color(69, 71, 90)
  result.cursorColor = color(205, 214, 244)
  result.lineNumColor = color(108, 112, 134)
  result.markerBg = color(62, 68, 43)            # muted olive for search hits
  result.scrollBarColor = color(69, 71, 90)
  result.scrollBarActiveColor = color(108, 112, 134)
  result.scrollTrackColor = color(36, 36, 54)
