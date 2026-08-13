## Theme -- color theme for uirelays.
##
## Since everything is text (SynEdit), there is one theme type.

import ../uirelays/screen

type
  TokenClass* {.pure.} = enum
    None, Whitespace, DecNumber, BinNumber, HexNumber,
    OctNumber, FloatNumber, Identifier, Keyword,
    StringLit, LongStringLit, CharLit, Backticks,
    EscapeSequence,
    Operator, Punctuation, Comment, LongComment, RegularExpression,
    TagStart, TagStandalone, TagEnd, Key, Value, RawData, Assembler,
    Preprocessor, Directive, Command, Rule, Link, Label,
    Reference, Text, Other, Green, Yellow, Red,
    MarkdownFence

  Theme* = object
    fg*: array[TokenClass, Color]   ## per-token foreground colors
    style*: array[TokenClass, FontStyles]
      ## per-token bold and italics, `{}` for the upright regular face. A
      ## color says what a token *is*, a style how much it wants to be read:
      ## comments in italics step back, a keyword in bold steps forward. Both
      ## are wishes -- a font without the face draws upright, so nothing here
      ## can make text disappear, and none of it changes the layout: the faces
      ## of a monospaced family share its advance width.
    bg*: Color                      ## editor background
    selBg*: Color                   ## selection background
    bracketBg*: Color               ## bracket match background
    cursorColor*: Color             ## cursor bar color
    lineNumColor*: Color            ## line number foreground
    markerBg*: Color                ## default marker highlight background
    scrollBarColor*: Color          ## scrollbar grip
    scrollBarActiveColor*: Color    ## scrollbar grip while dragging
    scrollTrackColor*: Color        ## scrollbar track background
    activeLineBg*: Color            ## background of the current/active line
    actionColor*: Color             ## frame around a line that acts on click
    closeColor*: Color              ## the (x) button of such a line

# ---------------------------------------------------------------------------
# Readability. A theme is only worth having if its text can be seen, so the
# contrast between what is drawn and what it is drawn on can be measured.
# ---------------------------------------------------------------------------

const MinContrast* = 300
  ## The lowest contrast ratio -- times 100, so 3.0:1 -- that still counts as
  ## readable. WCAG asks 4.5:1 for body text, but `goldenDusk` draws its
  ## comments at 4.4:1 and `catppuccinMocha` at 3.8:1, so both would fail their
  ## own test; dim comments are a deliberate and widespread choice, not a
  ## mistake. 3.0 is WCAG's bar for large text and interface parts, and it
  ## still catches everything that genuinely cannot be read.

proc luminance(c: Color): int =
  ## Relative luminance, 0 .. 10000. Squaring the channels stands in for the
  ## sRGB transfer function: it needs no floating point and lands close enough
  ## -- black on white comes out at 21.00:1, which is the textbook value.
  ## Alpha is ignored; theme colors are opaque.
  let r = int(c.r)
  let g = int(c.g)
  let b = int(c.b)
  result = (2126 * r * r + 7152 * g * g + 722 * b * b) div 65025

proc contrast*(a, b: Color): int =
  ## The contrast ratio between two colors, times 100: 450 means 4.5:1.
  ## The order does not matter. 100 is the lowest possible value, 2100 the
  ## highest.
  let la = luminance(a)
  let lb = luminance(b)
  let hi = max(la, lb)
  let lo = min(la, lb)
  result = ((hi + 500) * 100) div (lo + 500)

proc ratioText*(contrast100: int): string =
  ## A contrast ratio as "3.8:1".
  result = $(contrast100 div 100) & "." & $((contrast100 mod 100) div 10) & ":1"

proc contrastProblem*(t: Theme): string =
  ## "" when everything this theme draws *on* its background can be told apart
  ## from it; otherwise the first color that cannot, phrased for a message.
  ##
  ## Only foregrounds are checked. `selBg`, `activeLineBg`, `markerBg` and
  ## `bracketBg` sit *behind* text and are meant to stay close to `bg`, and
  ## the scrollbar and `actionColor` are hints rather than text -- the default
  ## theme draws its action frame at 1.9:1 on purpose.
  for tc in low(TokenClass)..high(TokenClass):
    let c = contrast(t.fg[tc], t.bg)
    if c < MinContrast:
      return $tc & " text is " & ratioText(c) & " against the background"
  let named = [("the cursor", t.cursorColor),
               ("the line numbers", t.lineNumColor),
               ("the (x) button", t.closeColor)]
  for i in 0 ..< named.len:
    let c = contrast(named[i][1], t.bg)
    if c < MinContrast:
      return named[i][0] & " is " & ratioText(c) & " against the background"
  result = ""

proc catppuccinMocha*(): Theme =
  result = default(Theme)
  let fg = color(205, 214, 244)
  for tc in low(TokenClass)..high(TokenClass):
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
  result.fg[TokenClass.MarkdownFence] = color(128, 128, 128)
  result.fg[TokenClass.Link] = color(137, 180, 250)       # blue
  result.bg = color(30, 30, 46)
  result.selBg = color(88, 91, 112)
  result.bracketBg = color(69, 71, 90)
  result.cursorColor = color(205, 214, 244)
  result.lineNumColor = color(108, 112, 134)
  result.markerBg = color(62, 68, 43)            # muted olive for search hits
  result.scrollBarColor = color(69, 71, 90)
  result.scrollBarActiveColor = color(108, 112, 134)
  result.scrollTrackColor = color(36, 36, 54)
  result.activeLineBg = color(69, 71, 90)        # surface1
  result.actionColor = color(88, 91, 112)        # surface2
  result.closeColor = color(147, 153, 178)       # subtext0

proc goldenDusk*(): Theme =
  ## Dark, in gold, orange and turquoise. Written in hex, the way a config file
  ## spells a color, so values can be copied straight between the two.
  let
    text        = color(0xE6, 0xDF, 0xD1)  # warm off-white
    gold        = color(0xE5, 0xB9, 0x4E)
    deepGold    = color(0xC9, 0xA2, 0x27)
    orange      = color(0xE8, 0x83, 0x3A)
    lightOrange = color(0xF2, 0xA6, 0x5A)
    turquoise   = color(0x2E, 0xC4, 0xB6)
    deepTurq    = color(0x1F, 0xA3, 0x98)
    brightTurq  = color(0x4F, 0xD1, 0xC5)
    muted       = color(0x8C, 0x85, 0x78)  # warm grey, for punctuation
    dim         = color(0x7A, 0x73, 0x65)  # dimmer still, for comments

  result = default(Theme)
  for tc in low(TokenClass)..high(TokenClass):
    result.fg[tc] = text

  result.fg[TokenClass.Keyword] = gold
  result.fg[TokenClass.Identifier] = text
  result.fg[TokenClass.Operator] = deepGold
  result.fg[TokenClass.Punctuation] = muted
  result.fg[TokenClass.Comment] = dim
  result.fg[TokenClass.LongComment] = dim
  result.fg[TokenClass.MarkdownFence] = dim
  # Strings and everything string-shaped: turquoise.
  result.fg[TokenClass.StringLit] = turquoise
  result.fg[TokenClass.LongStringLit] = turquoise
  result.fg[TokenClass.CharLit] = turquoise
  result.fg[TokenClass.RawData] = turquoise
  result.fg[TokenClass.Backticks] = turquoise
  result.fg[TokenClass.Key] = turquoise
  result.fg[TokenClass.Link] = brightTurq
  result.fg[TokenClass.Rule] = deepTurq
  result.fg[TokenClass.Preprocessor] = deepTurq
  result.fg[TokenClass.Directive] = deepTurq
  # Numbers and everything that stands out on its own: orange.
  result.fg[TokenClass.DecNumber] = orange
  result.fg[TokenClass.BinNumber] = orange
  result.fg[TokenClass.HexNumber] = orange
  result.fg[TokenClass.OctNumber] = orange
  result.fg[TokenClass.FloatNumber] = orange
  result.fg[TokenClass.RegularExpression] = orange
  result.fg[TokenClass.Value] = orange
  result.fg[TokenClass.Label] = orange
  result.fg[TokenClass.Reference] = orange
  result.fg[TokenClass.EscapeSequence] = lightOrange
  # Markup and assembler read as keywords.
  result.fg[TokenClass.TagStart] = gold
  result.fg[TokenClass.TagStandalone] = gold
  result.fg[TokenClass.TagEnd] = gold
  result.fg[TokenClass.Assembler] = gold
  result.fg[TokenClass.Command] = gold
  # The three named colors keep their meaning; only the shade is ours.
  result.fg[TokenClass.Green] = color(0x4F, 0xBF, 0x9F)
  result.fg[TokenClass.Yellow] = gold
  result.fg[TokenClass.Red] = color(0xE4, 0x63, 0x4A)

  result.bg = color(0x15, 0x17, 0x1B)
  result.selBg = color(0x35, 0x47, 0x4B)         # turquoise-tinted slate
  result.bracketBg = color(0x3E, 0x3A, 0x2C)     # gold-tinted, to match
  result.cursorColor = gold
  result.lineNumColor = color(0x6E, 0x67, 0x58)
  result.markerBg = color(0x4A, 0x3B, 0x14)      # dark gold for search hits
  result.scrollBarColor = color(0x33, 0x38, 0x3C)
  result.scrollBarActiveColor = color(0x4A, 0x52, 0x57)
  result.scrollTrackColor = color(0x1B, 0x1E, 0x22)
  result.activeLineBg = color(0x24, 0x27, 0x2C)  # a step below the selection
  result.actionColor = color(0x3A, 0x41, 0x45)
  result.closeColor = color(0xC0, 0x8A, 0x4A)    # gold, dimmed

proc defaultTheme*(): Theme =
  ## The theme a widget gets when nobody says otherwise, and the one a config
  ## file starts from. One place to change taste.
  result = goldenDusk()
