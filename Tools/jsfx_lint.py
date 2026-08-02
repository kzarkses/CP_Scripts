"""Verification structurelle d'un JSFX, hors REAPER.

Ne remplace pas le compilateur d'EEL2 : il attrape ce qu'une relecture
humaine rate — parentheses desequilibrees, fonction appelee et jamais
definie, section inconnue, variable de champ utilisee sans etre declaree.
"""
import io, re, sys
sys.stdout.reconfigure(encoding="utf-8")

P = ("c:/Users/Cedric/AppData/Roaming/REAPER/Scripts/CP_Scripts/"
     "CP_JSFX/CP_KitSampler.jsfx")
src = io.open(P, encoding="utf-8").read()
lines = src.split("\n")

errs, warns = [], []

# --- 1. parentheses, en ignorant commentaires et chaines -------------------
depth, in_str = 0, False
for ln, line in enumerate(lines, 1):
    code = line.split("//")[0]
    for ch in code:
        if ch == '"':
            in_str = not in_str
        elif not in_str:
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth < 0:
                    errs.append("l.%d : une parenthese fermante de trop" % ln)
                    depth = 0
if depth != 0:
    errs.append("fin de fichier : %d parenthese(s) jamais fermee(s)" % depth)

# --- 2. sections ------------------------------------------------------------
KNOWN = {"@init", "@slider", "@block", "@sample", "@serialize", "@gfx"}
secs = []
for ln, line in enumerate(lines, 1):
    m = re.match(r"^(@\w+)", line)
    if m:
        secs.append((m.group(1), ln))
        if m.group(1) not in KNOWN:
            errs.append("l.%d : section inconnue %s" % (ln, m.group(1)))
order = [s for s, _ in secs]
print("sections :", " ".join(order))
if "@init" not in order:
    errs.append("pas de @init")

# --- 3. fonctions : definies contre appelees --------------------------------
defined = set(re.findall(r"^function\s+(\w+)\s*\(", src, re.M))
BUILTIN = {
    "min", "max", "abs", "floor", "ceil", "sqrt", "pow", "exp", "log", "sin",
    "cos", "tan", "rand", "sign", "invsqrt", "loop", "while", "memset",
    "memcpy", "midirecv", "midisend", "midisend_buf", "file_open", "file_close",
    "file_riff", "file_avail", "file_mem", "file_var", "file_string",
    "str_setchar", "strcpy", "strcat", "strcpy_substr", "strlen", "sprintf",
    "slider", "sliderchange", "local", "global", "instance", "function",
    "freembuf", "atan2", "int", "sqr", "floor", "ceil",
    # les primitives graphiques : @gfx n'est ni le fil audio ni le disque
    "gfx_set", "gfx_rect", "gfx_line", "gfx_circle", "gfx_triangle",
    "gfx_setfont", "gfx_drawstr", "gfx_drawnumber", "gfx_drawchar",
    "gfx_measurestr", "gfx_getdropfile", "gfx_blit", "gfx_lineto",
    "gfx_rectto", "gfx_roundrect", "gfx_gradrect", "gfx_setpixel",
    "gfx_getchar", "gfx_showmenu", "gfx_printf",
}
# Le code SEUL : les commentaires sont en francais et « une boucle (…) » y
# ressemble a un appel de fonction. L'en-tete de sliders n'est pas du code non
# plus.
code_only = "\n".join(
    l.split("//")[0] for l in lines
    if not l.startswith("slider") and not l.startswith("desc:")
    and not l.startswith("options:") and not l.startswith("in_pin")
    and not l.startswith("out_pin")
    and "ECHEC" not in l)

called = set()
for m in re.finditer(r"(?<![\w.])(\w+)\s*\(", code_only):
    called.add(m.group(1))
# les definitions elles-memes ne sont pas des appels
called -= {"function"}
missing = sorted(c for c in called
                 if c not in defined and c not in BUILTIN
                 and not c.startswith("@") and not c.isdigit())
if missing:
    errs.append("appelees mais jamais definies : " + ", ".join(missing))

unused = sorted(d for d in defined if len(re.findall(r"(?<![\w.])%s\s*\(" % d, code_only)) < 2)
if unused:
    warns.append("definies et jamais appelees : " + ", ".join(unused))

# --- 4. champs P_* / V_* : declares contre utilises -------------------------
decl = set(re.findall(r"^\s*(?:[PVE]_\w+\s*=\s*\d+\s*;\s*)*?([PVE]_\w+)\s*=\s*\d+",
                      src, re.M))
for m in re.finditer(r"\b([PVE]_\w+)\s*=\s*\d+", src):
    decl.add(m.group(1))
used = set(re.findall(r"\[\s*([PVE]_\w+)\s*\]", src))
used |= set(re.findall(r"\b(E_\w+)\b", src))
undeclared = sorted(u for u in used if u not in decl)
if undeclared:
    errs.append("champs utilises et jamais declares : " + ", ".join(undeclared))
never_used = sorted(d for d in decl
                    if d not in used and not d.startswith("P_SAVE"))
if never_used:
    warns.append("champs declares et jamais lus : " + ", ".join(never_used))

# --- 4bis. l'arite des fonctions de fichier ---------------------------------
# Le compilateur d'EEL2 ne parle qu'a l'ouverture du plugin, et un JSFX qui ne
# compile pas est SILENCIEUX : l'effet est la, la piste existe, rien ne sort.
# file_var(handle, variable) sans son handle a coute une soiree.
FILE_ARITY = {
    "file_open": 1, "file_close": 1, "file_avail": 1, "file_rewind": 1,
    "file_var": 2, "file_mem": 3, "file_riff": 3, "file_text": 2,
    "file_string": 2,
}
for fn, want in FILE_ARITY.items():
    for m in re.finditer(r"(?<![\w.])" + fn + r"\s*\(", code_only):
        i, d, j = m.end(), 1, m.end()
        while j < len(code_only) and d > 0:
            if code_only[j] == "(":
                d += 1
            elif code_only[j] == ")":
                d -= 1
            j += 1
        inner = code_only[i:j - 1]
        depth, got = 0, (0 if not inner.strip() else 1)
        for ch in inner:
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            elif ch == "," and depth == 0:
                got += 1
        if got != want:
            ln = code_only.count("\n", 0, m.start()) + 1
            errs.append("l.%d : %s recoit %d parametre(s), il en faut %d"
                        % (ln, fn, got, want))

# --- 4ter. gmem ne s'indexe QUE par gmem[...] --------------------------------
# En EEL2 il n'existe pas de pointeur dans gmem : c'est un tableau a part.
# Ecrire gm[X] (ou gm tient un decalage) compile sans un mot et vise la
# memoire LOCALE — ici, en plein dans la table des pads. La boite aux lettres
# n'etait jamais lue ET elle ecrasait ce qu'elle devait remplir.
for m in re.finditer(r"(?<![A-Za-z_0-9])(gm|mb|box)\s*\[", code_only):
    ln = code_only.count(chr(10), 0, m.start()) + 1
    errs.append("l.%d : '%s[' indexe la memoire LOCALE ; gmem s'ecrit "
                "gmem[%s + X]" % (ln, m.group(1), m.group(1)))

# --- 5. le fil audio ne doit toucher ni disque ni allocation ---------------
def section_body(name):
    idx = [i for i, (s, _) in enumerate(secs) if s == name]
    if not idx:
        return ""
    a = secs[idx[0]][1]
    b = secs[idx[0] + 1][1] - 1 if idx[0] + 1 < len(secs) else len(lines)
    return "\n".join(lines[a:b])

audio = section_body("@sample")
for bad in ("file_open", "file_mem", "file_close", "file_riff", "memset",
            "sprintf", "strcpy"):
    if bad in audio:
        errs.append("@sample appelle %s — interdit dans le fil audio" % bad)

# @block A LE DROIT DE TOUCHER AU DISQUE, et c'est un choix ecrit : gfx_idle
# ne fait pas tourner @gfx de facon fiable fenetre fermee, donc y deleguer le
# chargement rendait l'instrument muet. Un clic une fois vaut mieux que le
# silence. Ce qui reste interdit, c'est le disque dans @sample.

# --- 6. LES DEUX FILS N'ECRIVENT PAS DANS LES MEMES VARIABLES --------------
#
# Toute variable d'un JSFX est GLOBALE, et les sections ne tournent pas sur le
# meme fil : @block et @sample sur le fil AUDIO, @gfx / @serialize / @slider sur
# celui de l'INTERFACE. Un compteur de boucle nomme `i` des deux cotes est LE
# MEME, et les deux fils l'ecrivent en meme temps.
#
# Ce que ca a coute, le 2026-08-02 : le drain de l'anneau de reglages fait
# `k = gmem[...]; pad(pi)[k] = valeur` — `k` est L'INDEX DU CHAMP. @gfx s'en
# servait comme compteur de lignes. Un reglage arrive pendant que la fenetre
# dessine, et il atterrit dans P_LOADED ou P_DATA : le pad se tait, et rien ne
# l'explique. Trouve par une anomalie d'AFFICHAGE — des lignes de pad 65 a 77
# alors qu'il n'y en a que 64 — qui etait la moitie visible du meme partage.
#
# La regle est donc mecanique : une variable ecrite par une section d'interface
# ne doit pas l'etre par une section audio. Les fonctions declarent leurs
# locales et ne sont pas concernees.
ASSIGN = re.compile(r"(?<![\w.])([a-z_][a-z_0-9]*)\s*=(?!=)")
STRLIT = re.compile(r'("(?:[^"\\]|\\.)*")')

def assigned_in(name):
    """Les variables SCALAIRES qu'une section affecte, hors chaines et
    commentaires. `x[i] = v` n'en est pas une : c'est une ecriture memoire."""
    out = set()
    for raw in section_body(name).split("\n"):
        code = raw.split("//")[0]
        parts = STRLIT.split(code)
        for j in range(0, len(parts), 2):
            for m in ASSIGN.finditer(parts[j]):
                # `nom[` est une ecriture memoire, pas une variable.
                if parts[j][m.start(1):m.end(1) + 1].endswith("["):
                    continue
                out.add(m.group(1))
    return out

audio_vars = assigned_in("@block") | assigned_in("@sample")
# `gfx_*` appartient au moteur graphique ; `gmem` et les champs declares ne
# sont pas des variables de travail.
IGNORE = {"gmem"}
for ui in ("@gfx", "@serialize", "@slider"):
    shared = (assigned_in(ui) & audio_vars) - IGNORE
    shared = {v for v in shared if not v.startswith("gfx_")}
    # `reload_next` est un SIGNAL delibere entre sections, pas un compteur de
    # travail : @serialize le pose, @block le consomme. Il est nomme, unique, et
    # sa nature est ecrite au-dessus de lui.
    shared -= {"reload_next"}
    for v in sorted(shared):
        errs.append("%s et le fil audio ecrivent tous deux `%s` — "
                    "prefixer celle de %s (gx_, sz_)" % (ui, v, ui))

# --- verdict ----------------------------------------------------------------
print("fonctions definies : %d" % len(defined))
print("champs declares    : %d" % len(decl))
for w in warns:
    print("  avertissement :", w)
if errs:
    print("\nECHEC :")
    for e in errs:
        print("  -", e)
    sys.exit(1)
print("\nOK — structure coherente, fil audio propre.")
