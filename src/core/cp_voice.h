// Une voix : un clip, une position, un rendez-vous.
//
// La voix est la SEULE chose que le moteur connait. Pas de scene, pas de
// colonne, pas de cellule — c'est le principe de propriete du dossier §2.1.
// Une politique de session se decrit entierement avec « joue au frame N »,
// « arrete au frame M » et « enchaine sur la voix H ».
#pragma once

#include "cp_types.h"

namespace cp {

class Pool;

struct Voice {
  // --- identite -------------------------------------------------------------
  int      state;        // VoiceState
  uint16_t gen;          // generation du handle
  int      port;         // -1 si non assignee

  // --- matiere --------------------------------------------------------------
  int      clip;         // slot du vivier, -1 si aucun
  double   pos;          // position de lecture en frames source (fractionnaire)

  // --- rendez-vous ----------------------------------------------------------
  frame_t  start_at;     // frame absolu du premier echantillon audible
  frame_t  stop_at;      // frame absolu de la coupure, ou INT64_MAX
  int      mode;         // PlayMode

  // --- transformation -------------------------------------------------------
  double   rate;         // 1.0 = vitesse d'origine
  float    gain;         // lineaire, applique avec rampe
  float    gain_target;
  float    pan;          // -1..+1
  frame_t  loop_start;   // en frames source
  frame_t  loop_end;     // 0 = fin du clip

  // --- fondus ---------------------------------------------------------------
  int      fade_in_len;    // en frames
  int      fade_in_pos;
  int      fade_out_len;
  int      fade_out_pos;

  // --- enchainement ---------------------------------------------------------
  // Correction §11.12 : legato, fondu croise et fin exacte ont une fenetre d'UN
  // bloc. Lua ne peut structurellement pas la tenir (16 a 74 ms par frame). Le
  // moteur possede donc UN emplacement « suivant » par voix. Un champ, pas un
  // modele de session.
  int      next_voice;   // index, -1 si aucun
  int      xfade_len;    // frames de fondu croise a l'enchainement
  frame_t  ended_at;     // frame ABSOLU ou la voix s'est eteinte, -1 sinon.
                         // C'est ce qui rend l'enchainement exact a
                         // l'echantillon plutot qu'exact au bloc.

  void reset();
  bool active() const { return state != kVoiceIdle; }

  // Rend et ADDITIONNE dans out (entrelace, nch canaux, frames images).
  // block_start est le frame absolu du premier echantillon du tampon.
  // Aucune allocation, aucun verrou, aucun appel systeme.
  void render(const Pool& pool, sample_t* out, int frames, int nch,
              frame_t block_start, double engine_srate);
};

} // namespace cp
