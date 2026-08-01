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
    "slider", "sliderchange", "local", "global", "instance", "function", "gfx_getdropfile", "freembuf", "atan2", "int",
}
# Le code SEUL : les commentaires sont en francais et « une boucle (…) » y
# ressemble a un appel de fonction. L'en-tete de sliders n'est pas du code non
# plus.
code_only = "\n".join(
    l.split("//")[0] for l in lines
    if not l.startswith("slider") and not l.startswith("desc:")
    and not l.startswith("options:") and not l.startswith("in_pin")
    and not l.startswith("out_pin"))

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

blk = section_body("@block")
for bad in ("file_open", "file_mem", "file_riff"):
    if bad in blk:
        errs.append("@block appelle %s — le disque appartient a @gfx" % bad)

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
