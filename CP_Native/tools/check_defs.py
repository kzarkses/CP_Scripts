# Verifie chaque defstring CP_* COMME LE COMPILATEUR LA VERRA.
#
# POURQUOI CE FICHIER EXISTE. Une defstring ReaScript est UNE chaine ou les
# champs sont separes par des NUL :
#
#     "rettype\0argtypes\0argnames\0aide"
#
# Deux facons de la casser, et aucune des deux ne se voit en relisant la source :
#
#   1. UN VRAI OCTET NUL a la place de la sequence source \0. Le fichier
#      compile, et REAPER refuse au chargement avec « 0 names but 1 types » —
#      un message qui ne dit ni ou ni pourquoi. Un octet de controle n'a rien a
#      faire dans un .cpp : on les refuse tous.
#
#   2. \0 SUIVI D'UN CHIFFRE OCTAL. "\01 rec" ne vaut pas NUL puis « 1 rec » :
#      c'est l'escape octal \01, soit le caractere 001. Le separateur
#      disparait, l'aide mange le nom d'argument, et la fonction se retrouve
#      declaree sans parametres — « expected 0 arguments maximum » a l'appel.
#      Une aide qui commence par un chiffre est donc interdite ici.
#
# Les deux sont arrivees le meme jour (session 20). Elles ne reviendront pas
# sans que la construction le dise.
import io
import re
import sys
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "src", "host", "cp_main.cpp")

raw = open(SRC, "rb").read()
ctrl = sorted({b for b in raw if b < 9 or (13 < b < 32)})
if ctrl:
    print("check_defs: OCTETS DE CONTROLE dans la source : %s"
          % [hex(b) for b in ctrl])
    print("            (un \\0 ecrit en octet plutot qu'en source)")
    sys.exit(1)

s = io.open(SRC, encoding="utf-8", errors="replace").read()

OCTAL = "01234567"


def unescape(lit):
    """Developpe les escapes C d'un litteral, y compris les octaux."""
    out, i = [], 0
    while i < len(lit):
        if lit[i] == "\\" and i + 1 < len(lit):
            j = i + 1
            if lit[j] in OCTAL:
                k = j
                while k < len(lit) and k - j < 3 and lit[k] in OCTAL:
                    k += 1
                out.append(chr(int(lit[j:k], 8)))
                i = k
                continue
            out.append({"n": "\n", "t": "\t"}.get(lit[j], lit[j]))
            i = j + 1
        else:
            out.append(lit[i])
            i += 1
    return "".join(out)


REG = re.compile(r'REG\((CP_\w+),\s*"((?:[^"\\]|\\.)*)"\)')

bad = 0
n = 0
for m in REG.finditer(s):
    name, lit = m.group(1), m.group(2)
    n += 1
    parts = unescape(lit).split("\0")
    if len(parts) < 3:
        print("check_defs: MALFORME  %-22s %d champ(s), il en faut 4"
              % (name, len(parts)))
        bad += 1
        continue
    types = [t for t in parts[1].split(",") if t.strip()]
    names = [x for x in parts[2].split(",") if x.strip()]
    if len(types) != len(names):
        print("check_defs: DESACCORD %-22s %d types vs %d noms"
              % (name, len(types), len(names)))
        bad += 1
    help_txt = parts[3] if len(parts) > 3 else ""
    # `help_txt[:1] in OCTAL` serait vrai pour une aide VIDE — en Python la
    # chaine vide est sous-chaine de tout. Une aide absente est legitime.
    if help_txt and help_txt[0] in OCTAL:
        print("check_defs: AIDE OCTALE %-20s l'aide commence par « %s » : le "
              "separateur qui la precede sera avale" % (name, help_txt[:1]))
        bad += 1

if bad:
    print("check_defs: %d defstrings, %d probleme(s)" % (n, bad))
    sys.exit(1)
print("check_defs: %d defstrings, aucune anomalie" % n)
sys.exit(0)
