-- CP_Toolkit Keys — gfx.getchar() key code mapping for REAPER
-- Generated from real key detection on Windows + AZERTY keyboard

local Keys = {}

-- ============================================================================
-- FUNCTION KEYS
-- ============================================================================
Keys.F1  = 26161
Keys.F2  = 26162
-- F3 = 26163 (intercepted by REAPER — may not be available)
Keys.F3  = 26163
Keys.F4  = 26164
Keys.F5  = 26165
Keys.F6  = 26166
Keys.F7  = 26167
Keys.F8  = 26168
Keys.F9  = 26169
Keys.F10 = 6697264
Keys.F11 = 6697265
Keys.F12 = 6697266

-- ============================================================================
-- ARROW KEYS
-- ============================================================================
Keys.UP    = 30064
Keys.DOWN  = 1685026670
Keys.LEFT  = 1818584692
Keys.RIGHT = 1919379572

-- ============================================================================
-- NAVIGATION
-- ============================================================================
Keys.HOME      = 1752132965
Keys.END       = 6647396
Keys.PAGE_UP   = 1885828464
Keys.PAGE_DOWN = 1885824110

-- ============================================================================
-- EDITING
-- ============================================================================
Keys.DELETE    = 6579564
Keys.INSERT    = 6909555
Keys.BACKSPACE = 8
Keys.TAB       = 9
Keys.ENTER     = 13
Keys.SPACE     = 32
Keys.ESCAPE    = 27

-- ============================================================================
-- LETTERS (lowercase — standard ASCII)
-- ============================================================================
Keys.A = 97   Keys.B = 98   Keys.C = 99   Keys.D = 100
Keys.E = 101  Keys.F = 102  Keys.G = 103  Keys.H = 104
Keys.I = 105  Keys.J = 106  Keys.K = 107  Keys.L = 108
Keys.M = 109  Keys.N = 110  Keys.O = 111  Keys.P = 112
Keys.Q = 113  Keys.R = 114  Keys.S = 115  Keys.T = 116
Keys.U = 117  Keys.V = 118  Keys.W = 119  Keys.X = 120
Keys.Y = 121  Keys.Z = 122

-- ============================================================================
-- NUMBERS (top row, no modifier)
-- ============================================================================
Keys.N0 = 48  Keys.N1 = 49  Keys.N2 = 50  Keys.N3 = 51
Keys.N4 = 52  Keys.N5 = 53  Keys.N6 = 54  Keys.N7 = 55
Keys.N8 = 56  Keys.N9 = 57

-- ============================================================================
-- PUNCTUATION & SYMBOLS
-- ============================================================================
Keys.MINUS      = 45   -- -
Keys.PLUS       = 43   -- +
Keys.EQUALS     = 61   -- =
Keys.UNDERSCORE = 95   -- _
Keys.PERIOD     = 46   -- .
Keys.COMMA      = 44   -- ,
Keys.SEMICOLON  = 59   -- ;
Keys.COLON      = 58   -- :
Keys.EXCLAIM    = 33   -- !
Keys.QUESTION   = 63   -- ?
Keys.SLASH      = 47   -- /
Keys.BACKSLASH  = 92   -- \
Keys.PIPE       = 124  -- |
Keys.AT         = 64   -- @
Keys.HASH       = 35   -- #
Keys.DOLLAR     = 36   -- $
Keys.PERCENT    = 37   -- %
Keys.CARET      = 94   -- ^
Keys.AMPERSAND  = 38   -- &
Keys.ASTERISK   = 42   -- *
Keys.LPAREN     = 40   -- (
Keys.RPAREN     = 41   -- )
Keys.LBRACKET   = 91   -- [
Keys.RBRACKET   = 93   -- ]
Keys.LBRACE     = 123  -- {
Keys.RBRACE     = 125  -- }
Keys.LESS       = 60   -- <
Keys.GREATER    = 62   -- >
Keys.TILDE      = 126  -- ~
Keys.QUOTE      = 39   -- '

-- ============================================================================
-- FRENCH ACCENTED (AZERTY specific codes)
-- ============================================================================
Keys.E_ACUTE    = 233  -- é
Keys.E_GRAVE    = 232  -- è
Keys.A_GRAVE    = 224  -- à
Keys.C_CEDILLA  = 231  -- ç
Keys.U_GRAVE    = 249  -- ù
Keys.SECTION    = 167  -- §
Keys.DEGREE     = 176  -- °
Keys.DIAERESIS  = 168  -- ¨
Keys.ACUTE_ACC  = 180  -- ´

-- ============================================================================
-- MODIFIER KEYS (from gfx.mouse_cap, NOT gfx.getchar)
-- ============================================================================
Keys.MOD_LEFT   = 1    -- left mouse button
Keys.MOD_RIGHT  = 2    -- right mouse button
Keys.MOD_CTRL   = 4    -- Ctrl
Keys.MOD_SHIFT  = 8    -- Shift
Keys.MOD_ALT    = 16   -- Alt
Keys.MOD_WIN    = 32   -- Win key
Keys.MOD_MIDDLE = 64   -- middle mouse button

-- ============================================================================
-- REVERSE LOOKUP (code → name)
-- ============================================================================
Keys._names = {}
for name, code in pairs(Keys) do
    if type(code) == "number" and name ~= "_names" and not name:match("^MOD_") then
        Keys._names[code] = name
    end
end

function Keys.GetName(code)
    return Keys._names[code] or string.format("UNKNOWN_%d", code)
end

return Keys
