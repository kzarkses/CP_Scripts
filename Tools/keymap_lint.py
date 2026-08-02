#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Le vocabulaire de gestes et le code qui l'execute disent-ils la meme chose ?

POURQUOI CET OUTIL EXISTE. Depuis que les liaisons sont une donnee, un ecart
peut apparaitre dans les deux sens, et AUCUN des deux ne se voit :

  1. une action DECLAREE que personne n'execute — l'utilisateur la voit dans la
     fenetre de reglages, la relie a une touche, appuie, et il ne se passe rien.
     C'est la pire des deux : l'outil a promis quelque chose ;
  2. une action EXECUTEE que personne ne declare — elle marche, mais elle est
     invisible dans les reglages et donc non configurable, ce qui est
     exactement ce que ce chantier devait supprimer.

Le cas (2) s'est presente le jour meme ou le tableau a ete ecrit : `edit.legato`
et `sel.invert` etaient dans RollUI.Do et dans aucun vocabulaire.

LES DEFAUTS SONT UNE EXCEPTION ASSUMEE. Une action sans modificateur (« deplacer
une note », « poser le curseur ») est atteinte par le chemin de repli, qui ne la
nomme pas — c'est le comportement de REAPER, ou toute combinaison non assignee
retombe sur l'action par defaut. Elles sont donc listees ici plutot que
signalees.

    python Tools/keymap_lint.py
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# vocabulaire -> les fichiers qui l'executent
MAP = {
    "CP_Engine/Keymaps/editor.lua": ["CP_Editor/CP_Editor.lua",
                                     "CP_Engine/RollUI.lua"],
    "CP_Engine/Keymaps/sampler.lua": ["CP_Sampler/CP_Sampler.lua"],
    "CP_Engine/Keymaps/session.lua": ["CP_Session/CP_Session.lua"],
}

# Actions atteintes par le repli « aucune liaison ne correspond ». Les nommer
# ici est une DECISION, pas un oubli : elles n'apparaissent pas dans le code.
FALLBACK = {
    "note.select", "note.move", "edge.resize",
    "roll.insert", "roll.insert_drag", "ruler.cursor",
    "brace.edit",
}

PREFIX = (r'"((?:note|edge|roll|lane|ruler|vel|play|view|audio|edit|sel|walk'
          r'|brace|clip|pad|page|cell)\.[a-z_0-9]+)"')


def read(rel):
    return io.open(os.path.join(ROOT, rel), encoding="utf-8").read()


def main():
    bad = 0
    all_declared = set()
    for voc, hosts in MAP.items():
        src = read(voc)
        declared = re.findall(r'\{\s*act\s*=\s*"([^"]+)"', src)
        dset = set(declared)
        if len(declared) != len(dset):
            seen, dup = set(), set()
            for a in declared:
                if a in seen:
                    dup.add(a)
                seen.add(a)
            print("%s : action declaree DEUX fois : %s"
                  % (voc, ", ".join(sorted(dup))))
            bad += 1

        code = "".join(read(h) for h in hosts)
        used = set(re.findall(PREFIX, code))

        orphan = sorted(a for a in dset if a not in used and a not in FALLBACK)
        ghost = sorted(a for a in used if a not in dset)

        print("%s" % voc)
        print("    %d actions, %d executees, %d par defaut"
              % (len(dset), len(dset & used), len(dset & FALLBACK)))
        if orphan:
            bad += 1
            print("    DECLAREES ET JAMAIS EXECUTEES :")
            for a in orphan:
                print("        " + a)
        if ghost:
            bad += 1
            print("    EXECUTEES ET JAMAIS DECLAREES :")
            for a in ghost:
                print("        " + a)
        all_declared |= dset

    # Un defaut qui n'est plus declare NULLE PART n'est plus un defaut : c'est
    # une exception qui ne protege plus rien.
    #
    # La question se pose sur l'UNION des vocabulaires, pas sur chacun : le jeu
    # de replis est global, et le verifier par fichier accusait le vocabulaire
    # du Sampler de ne pas declarer les actions de l'editeur. Un linteur qui
    # crie a chaque ajout de module apprend a se faire ignorer.
    stale = sorted(a for a in FALLBACK if a not in all_declared)
    if stale:
        bad += 1
        print("\nEXCEPTIONS DE REPLI PERIMEES (declarees nulle part) :")
        for a in stale:
            print("    " + a)

    print("\n%s" % ("ecarts trouves" if bad else
                    "OK — le tableau et le code disent la meme chose"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.exit(main())
