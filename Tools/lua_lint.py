#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Verification structurelle des scripts Lua de la suite, hors REAPER.

POURQUOI CET OUTIL EXISTE. Le coeur natif a un harnais qui PROUVE ses
invariants (CP_Native/build_test.cmd) ; le Lua n'avait rien, et il n'y a pas
d'interpreteur Lua sur la machine. Les trois erreurs que cet outil attrape
sont celles qui ne se voient pas a la relecture et que REAPER ne signale
qu'au moment ou le geste echoue, souvent apres avoir deja abime un projet :

  1. un bloc jamais ferme (un `end` de trop ou de moins) ;
  2. une LOCALE UTILISEE AVANT SA DECLARATION — en Lua c'est `nil`, donc une
     erreur a l'appel, et rien ne le dit avant. Kit.Poll a appele une
     fonction declaree neuf cents lignes plus bas ;
  3. un APPEL A QUI IL MANQUE UN ARGUMENT que la fonction appelee concatene
     sans garde. `Tracks.Mark(tr)` au lieu de `Tracks.Mark(tr, app, role)` a
     coute une creation de kit a moitie faite, et le montage qu'on venait de
     remplacer est reparti tout seul.

Un argument de fin manquant n'est PAS signale quand la fonction appelee le
tolere : Lua les remplit a nil et la moitie de la suite s'en sert. Seul le
cas qui leve vraiment est rapporte.

    python Tools/lua_lint.py                 # tout CP_Engine + les fenetres
    python Tools/lua_lint.py CP_Engine/Kit.lua
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Les vocabulaires de gestes vivent dans un SOUS-dossier de CP_Engine, et le
# balayage n'est pas recursif : sans cette ligne ils ne seraient verifies par
# personne, ce qui est exactement le sort d'un fichier de donnees — on n'y
# pense qu'apres l'erreur.
DEFAULT = ["CP_Engine", "CP_Engine/Keymaps", "CP_Sampler", "CP_Session",
           "CP_Editor", "CP_Tools"]


def strip(src):
    """Neutralise commentaires et chaines en gardant longueurs et lignes.

    Les chaines deviennent des `_` et non des espaces : un compteur
    d'arguments doit continuer a voir qu'il y a quelque chose entre les
    parentheses, sinon Kit.SetMode("drum") passe pour un appel sans argument.
    """
    out, i, n = [], 0, len(src)
    while i < n:
        m = re.match(r"--\[(=*)\[", src[i:])
        if m:
            close = "]" + m.group(1) + "]"
            j = src.find(close, i)
            j = n if j < 0 else j + len(close)
            out.append(re.sub(r"[^\n]", " ", src[i:j]))
            i = j
            continue
        if src.startswith("--", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
            continue
        m = re.match(r"\[(=*)\[", src[i:])
        if m:
            close = "]" + m.group(1) + "]"
            j = src.find(close, i)
            j = n if j < 0 else j + len(close)
            out.append(re.sub(r"[^\n]", "_", src[i:j]))
            i = j
            continue
        if src[i] in "\"'":
            q, j = src[i], i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == q:
                    j += 1
                    break
                if src[j] == "\n":
                    break
                j += 1
            out.append(re.sub(r"[^\n]", "_", src[i:j]))
            i = j
            continue
        out.append(src[i])
        i += 1
    return "".join(out)


def line_of(code, pos):
    return code.count("\n", 0, pos) + 1


# --- 1. blocs et parentheses -----------------------------------------------
def check_blocks(code):
    errs = []
    events = []
    for m in re.finditer(r"\b(function|if|do|repeat)\b", code):
        events.append((m.start(), 1, m.group(1)))
    for m in re.finditer(r"\b(end|until)\b", code):
        events.append((m.start(), -1, m.group(1)))
    events.sort()
    stack = []
    for pos, d, word in events:
        if d > 0:
            stack.append((word, line_of(code, pos)))
        elif stack:
            stack.pop()
        else:
            errs.append("l.%d : '%s' sans bloc ouvert" % (line_of(code, pos), word))
    for word, ln in stack:
        errs.append("l.%d : '%s' jamais ferme" % (ln, word))

    pairs = {")": "(", "]": "[", "}": "{"}
    st = []
    for i, ch in enumerate(code):
        if ch in "([{":
            st.append((ch, line_of(code, i)))
        elif ch in ")]}":
            if not st or st[-1][0] != pairs[ch]:
                errs.append("l.%d : '%s' mal apparie" % (line_of(code, i), ch))
                if st:
                    st.pop()
            else:
                st.pop()
    for ch, ln in st:
        errs.append("l.%d : '%s' jamais ferme" % (ln, ch))
    return errs


# --- 2. locale utilisee avant sa declaration -------------------------------
def check_locals(code):
    lines = code.split("\n")
    decl = {}
    for i, l in enumerate(lines, 1):
        m = re.match(r"\s*local\s+function\s+(\w+)", l)
        if m:
            decl.setdefault(m.group(1), i)
            continue
        m = re.match(r"\s*local\s+([\w\s,]+?)\s*(=|$)", l)
        if m:
            for nm in m.group(1).split(","):
                nm = nm.strip()
                if nm and nm.isidentifier():
                    decl.setdefault(nm, i)
    # Les parametres de la fonction englobante portent parfois le meme nom
    # qu'une locale declaree plus bas, et ils la masquent legitimement. On
    # remonte donc a l'en-tete de fonction la plus proche avant de crier.
    def shadowed_by_param(idx, name):
        for k in range(idx - 1, max(idx - 400, 0) - 1, -1):
            m = re.match(r"\s*(local\s+)?function[\w\s.:]*\(([^)]*)\)", lines[k])
            if m:
                params = [a.strip() for a in m.group(2).split(",")]
                return name in params
        return False

    errs = []
    for name, dl in decl.items():
        if len(name) < 4:
            continue
        for i, l in enumerate(lines, 1):
            if i >= dl:
                break
            # ON NE SAUTE QUE LA DECLARATION DE CE NOM-LA. Sauter toute ligne
            # commencant par `local` rendait l'outil aveugle a
            # `local n = maFonction()`, qui est la facon la plus courante
            # d'appeler une fonction en Lua — et c'est exactement l'appel qui
            # est passe a travers, deux fois de suite.
            if re.match(r"\s*local\s+(function\s+)?" + re.escape(name)
                        + r"\b", l):
                continue
            # un appel ou une indexation : une simple mention peut etre autre
            # chose que l'usage de la locale qu'on croit
            if re.search(r"(?<![\w.:])" + re.escape(name) + r"\s*[\(\[]", l):
                if shadowed_by_param(i - 1, name):
                    break
                errs.append("l.%d : '%s' est utilise avant sa declaration (l.%d)"
                            % (i, name, dl))
                break
    return errs


# --- 3. argument manquant que la fonction appelee concatene ----------------
# ---------------------------------------------------------------------------
# LE PLAFOND DE 200 LOCALES, qui est une falaise et non une pente
# ---------------------------------------------------------------------------
# Lua refuse plus de 200 variables locales par fonction, et le chunk d'un
# fichier EST une fonction. Au 201e, le fichier ne se compile plus : REAPER
# affiche « too many local variables » et la fenetre ne s'ouvre pas du tout.
#
# Ce n'est pas un defaut de style, c'est un mur qu'on ne voit pas venir — et
# deux fichiers de cette suite en etaient a cinq et treize variables (2026-08-02,
# mesure en ajoutant une seule ligne a CP_Editor). Un fichier qu'on enrichit
# depuis des mois s'en approche sans que rien ne le dise.
#
# On previent a 180 et on refuse a 200 : la marge existe pour qu'on ait le temps
# de regrouper des constantes dans une table plutot que de le decouvrir au
# moment ou on a besoin d'ajouter quelque chose.
LOCAL_HARD = 200
LOCAL_WARN = 180

LOCAL_DECL = re.compile(r"^local\s+(function\s+)?([A-Za-z_][\w,\s]*)")


def count_chunk_locals(code):
    n = 0
    for line in code.splitlines():
        m = LOCAL_DECL.match(line)
        if not m:
            continue
        if m.group(1):
            n += 1                     # `local function nom`
        else:
            n += len([x for x in m.group(2).split(",") if x.strip()])
    return n


def check_local_budget(code):
    """Rend (erreurs, avertissements). Un avertissement N'EST PAS un echec :
    un linteur qui crie sur un fichier qui marche apprend a se faire ignorer,
    et c'est la seule chose qu'on ne peut pas lui pardonner."""
    n = count_chunk_locals(code)
    if n > LOCAL_HARD:
        return (["%d locales de chunk : au-dela de %d, Lua REFUSE de compiler "
                 "le fichier (« too many local variables »)" % (n, LOCAL_HARD)],
                [])
    if n >= LOCAL_WARN:
        return ([], ["%d locales de chunk sur %d : il reste %d. Regrouper des "
                     "constantes dans une table AVANT d'en ajouter."
                     % (n, LOCAL_HARD, LOCAL_HARD - n)])
    return ([], [])


def collect_signatures(files):
    sig = {}
    for f in files:
        code = strip(io.open(f, encoding="utf-8").read())
        for m in re.finditer(r"^function\s+(\w+)\.(\w+)\s*\(([^)]*)\)", code, re.M):
            obj, name, args = m.groups()
            ps = [a.strip() for a in args.split(",") if a.strip()]
            sig[(obj, name)] = (ps, code[m.end():m.end() + 2000])
    return sig


def _argcount(txt):
    if not txt.strip():
        return 0
    d, n = 0, 0
    for ch in txt:
        if ch in "([{":
            d += 1
        elif ch in ")]}":
            d -= 1
        elif ch == "," and d == 0:
            n += 1
    return n + 1


def check_arity(code, sig):
    errs = []
    for m in re.finditer(r"(?<![\w.])(\w+)\.(\w+)\s*\(", code):
        key = (m.group(1), m.group(2))
        if key not in sig:
            continue
        i, d, j = m.end(), 1, m.end()
        while j < len(code) and d > 0:
            if code[j] in "([{":
                d += 1
            elif code[j] in ")]}":
                d -= 1
            j += 1
        got = _argcount(code[i:j - 1])
        ps, body = sig[key]
        for miss in ps[got:]:
            e = re.escape(miss)
            concat = (re.search(r"(?<![\w.])" + e + r"\s*\.\.", body)
                      or re.search(r"\.\.\s*" + e + r"(?![\w.])", body))
            if concat and not re.search(e + r"\s+or\s", body):
                errs.append("l.%d : %s.%s() sans '%s', que la fonction "
                            "concatene sans garde"
                            % (line_of(code, m.start()), key[0], key[1], miss))
    return errs


def main(argv):
    targets = argv[1:] or DEFAULT
    files = []
    for t in targets:
        p = os.path.join(ROOT, t)
        if os.path.isdir(p):
            for name in sorted(os.listdir(p)):
                if name.endswith(".lua"):
                    files.append(os.path.join(p, name))
        elif os.path.isfile(p):
            files.append(p)
    if not files:
        print("rien a verifier")
        return 1

    sig = collect_signatures(files)
    bad = 0
    for f in files:
        code = strip(io.open(f, encoding="utf-8").read())
        budget_errs, warns = check_local_budget(code)
        errs = (check_blocks(code) + check_locals(code)
                + check_arity(code, sig) + budget_errs)
        rel = os.path.relpath(f, ROOT).replace("\\", "/")
        if errs:
            bad += 1
            print("%s" % rel)
            for e in errs[:12]:
                print("    " + e)
            if len(errs) > 12:
                print("    ... et %d autres" % (len(errs) - 12))
        else:
            print("%-34s OK%s" % (rel, "   (avertissement)" if warns else ""))
        for w in warns:
            print("    ! " + w)
    print("\n%d fichier(s), %d en echec" % (len(files), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.exit(main(sys.argv))
